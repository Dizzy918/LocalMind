//
//  VoiceManager.swift
//  LocalMind
//

import Foundation
import Speech
import AVFoundation

@Observable
final class VoiceManager: NSObject, SFSpeechRecognizerDelegate, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    
    // MARK: - Speech Synthesis (Output)
    nonisolated(unsafe) private let synthesizer = AVSpeechSynthesizer()
    var isSpeaking = false
    
    // MARK: - Speech Recognition (Input)
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    var isRecording = false
    var audioLevel: Float = 0
    /// The live, partial transcription while the user is speaking.
    var transcribedText = ""
    /// Becomes true once the user stops recording and the final text is committed.
    var isTranscriptionFinal = false
    /// Error message to display in the UI if something goes wrong.
    var errorMessage: String?
    
    private var hasRequestedPermissions = false
    
    override init() {
        super.init()
        synthesizer.delegate = self
        
        // Initialize speech recognizer with the user's locale, falling back to en-US
        speechRecognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        speechRecognizer?.delegate = self
    }
    
    // MARK: - Permissions
    
    /// Requests microphone + speech recognition permissions. Must be called before the first recording attempt.
    /// This is async and awaits until the user responds to the permission dialogs.
    func ensurePermissions() async -> Bool {
        // 1. Speech Recognition authorization
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .notDetermined {
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            if status != .authorized {
                await MainActor.run {
                    errorMessage = "Speech recognition permission denied. Enable it in System Settings → Privacy & Security → Speech Recognition."
                }
                return false
            }
        } else if speechStatus != .authorized {
            await MainActor.run {
                errorMessage = "Speech recognition not authorized. Enable it in System Settings → Privacy & Security → Speech Recognition."
            }
            return false
        }
        
        // 2. Microphone authorization
        #if os(macOS)
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                await MainActor.run {
                    errorMessage = "Microphone permission denied. Enable it in System Settings → Privacy & Security → Microphone."
                }
                return false
            }
        } else if micStatus != .authorized {
            await MainActor.run {
                errorMessage = "Microphone not authorized. Enable it in System Settings → Privacy & Security → Microphone."
            }
            return false
        }
        #endif
        
        hasRequestedPermissions = true
        return true
    }
    
    // MARK: - Text to Speech
    
    func speak(text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.5
        
        if let voice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }
        
        synthesizer.speak(utterance)
        isSpeaking = true
    }
    
    func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }
    
    // MARK: - AVSpeechSynthesizerDelegate
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in isSpeaking = false }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in isSpeaking = false }
    }
    
    // MARK: - Speech to Text
    
    /// Call this from the UI button tap. It handles both start and stop, including async permission requests.
    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            Task { @MainActor in
                await startRecordingWithPermissions()
            }
        }
    }
    
    private func startRecordingWithPermissions() async {
        // Clear any previous error
        errorMessage = nil
        
        // Ensure permissions first (awaits dialog if needed)
        if !hasRequestedPermissions {
            let granted = await ensurePermissions()
            if !granted { return }
        }
        
        startRecording()
    }
    
    private func startRecording() {
        // Cancel any previous task
        cleanupAudioEngine()
        
        guard let speechRecognizer = speechRecognizer else {
            errorMessage = "Speech recognizer could not be created for your locale."
            return
        }
        
        guard speechRecognizer.isAvailable else {
            errorMessage = "Speech recognition is not available right now. Check your internet connection or try later."
            return
        }
        
        // Reset state
        isTranscriptionFinal = false
        transcribedText = ""
        errorMessage = nil
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        if #available(macOS 13.0, iOS 16.0, *) {
            request.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition
        }
        
        recognitionRequest = request
        
        // Get the audio input node
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        // Sanity check — sample rate must be > 0
        guard recordingFormat.sampleRate > 0 else {
            errorMessage = "No microphone found. Please connect a microphone and try again."
            return
        }
        
        // Install tap on the input node to feed audio to the recognizer
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frames { sum += channelData[i] * channelData[i] }
            let rms = sqrtf(sum / Float(max(frames, 1)))
            let level = max(0, min(1, rms * 4))
            Task { @MainActor [weak self] in self?.audioLevel = level }
        }
        
        // Start the recognition task
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                Task { @MainActor in
                    self.transcribedText = result.bestTranscription.formattedString
                    
                    if result.isFinal {
                        self.isTranscriptionFinal = true
                        self.cleanupAudioEngine()
                    }
                }
            }
            
            if let error = error {
                // Ignore cancellation errors (they're expected when we stop)
                let nsError = error as NSError
                if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                    // "kAFAssistantErrorDomain 216" = request was cancelled. This is normal.
                    return
                }
                
                print("[VoiceManager] Recognition error: \(error.localizedDescription)")
                Task { @MainActor in
                    // Only show error if we didn't get any text at all
                    if self.transcribedText.isEmpty {
                        self.errorMessage = "Voice recognition error: \(error.localizedDescription)"
                    }
                    self.isTranscriptionFinal = true
                    self.cleanupAudioEngine()
                }
            }
        }
        
        // Prepare and start the audio engine
        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
        } catch {
            errorMessage = "Could not start audio recording: \(error.localizedDescription)"
            cleanupAudioEngine()
        }
    }
    
    func stopRecording() {
        guard isRecording else { return }
        
        // Signal end of audio — this triggers the final result from the recognizer
        recognitionRequest?.endAudio()
        
        // Stop the audio engine
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        isRecording = false
        isTranscriptionFinal = true
        audioLevel = 0
    }

    private func cleanupAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
    }
    
    // MARK: - SFSpeechRecognizerDelegate
    
    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        if !available && isRecording {
            Task { @MainActor in
                errorMessage = "Speech recognition became unavailable."
                stopRecording()
            }
        }
    }
}
