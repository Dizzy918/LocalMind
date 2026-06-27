//
//  VoiceManager.swift
//  LocalMind
//

import Foundation
import Speech
import AVFoundation

@MainActor
@Observable
final class VoiceManager: NSObject, SFSpeechRecognizerDelegate, AVSpeechSynthesizerDelegate {

    // MARK: - Speech Synthesis (Output)
    private let synthesizer = AVSpeechSynthesizer()
    var isSpeaking = false

    // MARK: - Speech Recognition (Input)
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    var isRecording = false
    var audioLevel: Float = 0
    var transcribedText = ""
    var isTranscriptionFinal = false
    var errorMessage: String?

    private var hasRequestedPermissions = false

    override init() {
        super.init()
        synthesizer.delegate = self
        speechRecognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        speechRecognizer?.delegate = self
    }

    // MARK: - Permissions

    func ensurePermissions() async -> Bool {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .notDetermined {
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            if status != .authorized {
                errorMessage = "Speech recognition permission denied. Enable it in System Settings → Privacy & Security → Speech Recognition."
                return false
            }
        } else if speechStatus != .authorized {
            errorMessage = "Speech recognition not authorized. Enable it in System Settings → Privacy & Security → Speech Recognition."
            return false
        }

        #if os(macOS)
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                errorMessage = "Microphone permission denied. Enable it in System Settings → Privacy & Security → Microphone."
                return false
            }
        } else if micStatus != .authorized {
            errorMessage = "Microphone not authorized. Enable it in System Settings → Privacy & Security → Microphone."
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

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.isSpeaking = false }
    }

    // MARK: - Speech to Text

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            Task { await startRecordingWithPermissions() }
        }
    }

    private func startRecordingWithPermissions() async {
        errorMessage = nil
        if !hasRequestedPermissions {
            let granted = await ensurePermissions()
            if !granted { return }
        }
        startRecording()
    }

    private func startRecording() {
        cleanupAudioEngine()

        guard let speechRecognizer = speechRecognizer else {
            errorMessage = "Speech recognizer could not be created for your locale."
            return
        }

        guard speechRecognizer.isAvailable else {
            errorMessage = "Speech recognition is not available right now. Check your internet connection or try later."
            return
        }

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

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        guard recordingFormat.sampleRate > 0 else {
            errorMessage = "No microphone found. Please connect a microphone and try again."
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frames { sum += channelData[i] * channelData[i] }
            let rms = sqrtf(sum / Float(max(frames, 1)))
            let level = max(0, min(1, rms * 4))
            Task { @MainActor [weak self] in
                self?.recognitionRequest?.append(buffer)
                self?.audioLevel = level
            }
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result = result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.transcribedText = text
                    if isFinal {
                        self.isTranscriptionFinal = true
                        self.cleanupAudioEngine()
                    }
                }
            }

            if let error = error {
                let nsError = error as NSError
                if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                    return
                }
                let description = error.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if self.transcribedText.isEmpty {
                        self.errorMessage = "Voice recognition error: \(description)"
                    }
                    self.isTranscriptionFinal = true
                    self.cleanupAudioEngine()
                }
            }
        }

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
        recognitionRequest?.endAudio()
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

    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if !available && self.isRecording {
                self.errorMessage = "Speech recognition became unavailable."
                self.stopRecording()
            }
        }
    }
}
