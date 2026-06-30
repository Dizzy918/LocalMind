//
//  AIServiceManager.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 20.06.26.
//

import Foundation
import SwiftUI

/// Manages AI service backends and provides the currently active service.
///
/// On initialization (or when the user changes preferences) this manager
/// auto-detects available backends and selects the best one:
///   1. If the user has a preferred backend **and** it's available, use it.
///   2. Otherwise try Apple Intelligence first, then Ollama, then OpenAI-compatible servers.
///   3. Fall back to `.none` if nothing is reachable.
///
/// Uses `@Observable` for SwiftUI integration — any view that reads
/// `currentBackend`, `statusMessage`, etc. will automatically update.
@Observable
@MainActor
final class AIServiceManager {
    /// The currently active AI service (nil when no backend is available).
    private(set) var currentService: (any AIServiceProtocol)?

    /// The backend type of the current service.
    private(set) var currentBackend: AIBackend = .none

    /// Whether the manager is currently probing backends.
    private(set) var isCheckingAvailability = false

    /// Human-readable status message suitable for display in the UI.
    private(set) var statusMessage = "Checking AI availability..."

    /// Models available on the connected Ollama instance.
    private(set) var availableModels: [OllamaModel] = []
    
    /// Models available on the connected OpenAI-compatible server.
    private(set) var availableOpenAIModels: [OpenAIModel] = []

    /// The user's preferred backend, persisted in `UserDefaults`.
    ///
    /// Setting this triggers an immediate re-detection so the UI stays in sync.
    var preferredBackend: AIBackend? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "preferredBackend") else { return nil }
            return AIBackend(rawValue: raw)
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue, forKey: "preferredBackend")
            Task { await detectAndConnect() }
        }
    }

    /// The selected Ollama model name, persisted in `UserDefaults`.
    var selectedOllamaModel: String = UserDefaults.standard.string(forKey: "selectedOllamaModel") ?? "qwen3:8b" {
        didSet { UserDefaults.standard.set(selectedOllamaModel, forKey: "selectedOllamaModel") }
    }
    
    /// The custom OpenAI-compatible server URL, persisted in `UserDefaults`.
    var openAIServerURL: String = UserDefaults.standard.string(forKey: "openAIServerURL") ?? "http://localhost:1234" {
        didSet { UserDefaults.standard.set(openAIServerURL, forKey: "openAIServerURL") }
    }
    
    /// The selected OpenAI-compatible model name, persisted in `UserDefaults`.
    var selectedOpenAIModel: String = UserDefaults.standard.string(forKey: "selectedOpenAIModel") ?? "default" {
        didSet { UserDefaults.standard.set(selectedOpenAIModel, forKey: "selectedOpenAIModel") }
    }
    
    /// The selected server preset ID, persisted in `UserDefaults`.
    var selectedPresetID: String = UserDefaults.standard.string(forKey: "selectedPresetID") ?? "lmstudio" {
        didSet { UserDefaults.standard.set(selectedPresetID, forKey: "selectedPresetID") }
    }
    
    /// The display name of the currently connected OpenAI-compatible server.
    private(set) var openAIServerName: String = "LM Studio"

    /// The active parameters for generation, persisted in `UserDefaults`.
    var aiParameters: AIParameters {
        get {
            if let data = UserDefaults.standard.data(forKey: "aiParameters"),
               let decoded = try? JSONDecoder().decode(AIParameters.self, from: data) {
                return decoded
            }
            return .default
        }
        set {
            if let encoded = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(encoded, forKey: "aiParameters")
            }
        }
    }
    
    /// Unified list of available model IDs for the current backend
    var allAvailableModelIDs: [String] {
        switch currentBackend {
        case .ollama:
            return availableModels.map { $0.name }
        case .openAICompatible:
            return availableOpenAIModels.map { $0.id }
        case .appleFoundationModels, .none:
            return []
        }
    }

    // MARK: - Private Services

    private let ollamaService = OllamaService()
    private var openAIService: OpenAICompatibleService?
    private var appleService: (any AIServiceProtocol)?
    // nonisolated so deinit (which is itself nonisolated on a MainActor
    // class) can cancel the task without hopping back to the main actor.
    private nonisolated(unsafe) var pollingTask: Task<Void, Never>?
    
    /// Reference to MCP service for tool integration
    weak var mcpService: MCPService?

    // MARK: - Initialization

    init() {
        // Create Apple FM service if the framework is available at runtime.
        if #available(macOS 26.0, *) {
            appleService = AppleFoundationModelService()
        }
        
        startPolling()
    }
    
    deinit {
        pollingTask?.cancel()
    }

    /// Sets the MCP service reference for tool integration
    func setMCPService(_ mcpService: MCPService) {
        self.mcpService = mcpService
    }

    /// Executes a batch of tool calls via the MCP service and invokes
    /// `onResult` for each, with a human-readable summary for chat injection.
    func executeToolCalls(_ calls: [AIToolCall], onResult: (String, String) -> Void) async {
        guard let mcpService else { return }
        for call in calls {
            do {
                let argsData = call.arguments.data(using: .utf8) ?? Data()
                let args = (try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]) ?? [:]
                let content = try await mcpService.callTool(name: call.name, arguments: args)
                let textParts = content.compactMap { $0.text }.joined(separator: "\n")
                onResult(call.name, textParts.isEmpty ? "(empty result)" : textParts)
            } catch {
                onResult(call.name, "Error — \(error.localizedDescription)")
            }
        }
    }

    /// Gets available tools from MCP service for the current conversation
    func getAvailableTools() -> [AITool] {
        guard let mcpService = mcpService else { return [] }
        return mcpService.availableTools.map { mcpTool in
            AITool(
                id: mcpTool.id,
                name: mcpTool.name,
                description: mcpTool.description ?? "",
                inputSchema: mcpTool.inputSchema
            )
        }
    }

    // MARK: - Detection

    /// Probes each backend and connects to the best available one.
    ///
    /// Call this on app launch and whenever the user changes their preference.
    func detectAndConnect() async {
        isCheckingAvailability = true
        statusMessage = "Checking AI availability..."

        // 1. Honour the user's explicit preference if the backend is reachable.
        if let preferred = preferredBackend {
            switch preferred {
            case .appleFoundationModels:
                if let apple = appleService, await apple.checkAvailability() {
                    currentService = apple
                    currentBackend = .appleFoundationModels
                    statusMessage = "Connected to Apple Intelligence"
                    isCheckingAvailability = false
                    return
                }
            case .ollama:
                if await ollamaService.checkAvailability() {
                    await ollamaService.setModel(selectedOllamaModel)
                    currentService = ollamaService
                    currentBackend = .ollama
                    statusMessage = "Connected to Ollama (\(selectedOllamaModel))"
                    await loadOllamaModels()
                    isCheckingAvailability = false
                    return
                }
            case .openAICompatible:
                if let service = createOpenAIService(),
                   await service.checkAvailability() {
                    await service.setModel(selectedOpenAIModel)
                    openAIService = service
                    currentService = service
                    currentBackend = .openAICompatible
                    statusMessage = "Connected to \(openAIServerName)"
                    await loadOpenAIModels(service)
                    isCheckingAvailability = false
                    return
                }
            case .none:
                break
            }
        }

        // 2. Auto-detect: Apple Intelligence → Ollama → OpenAI-compatible → none.
        if let apple = appleService, await apple.checkAvailability() {
            currentService = apple
            currentBackend = .appleFoundationModels
            statusMessage = "Connected to Apple Intelligence"
        } else if await ollamaService.checkAvailability() {
            await ollamaService.setModel(selectedOllamaModel)
            currentService = ollamaService
            currentBackend = .ollama
            statusMessage = "Connected to Ollama (\(selectedOllamaModel))"
            await loadOllamaModels()
        } else if let detected = await autoDetectOpenAIServer() {
            openAIService = detected.service
            currentService = detected.service
            currentBackend = .openAICompatible
            openAIServerName = detected.name
            statusMessage = "Connected to \(detected.name)"
            await loadOpenAIModels(detected.service)
        } else {
            currentService = nil
            currentBackend = .none
            statusMessage = "No AI backend available"
            availableModels = []
            availableOpenAIModels = []
        }

        isCheckingAvailability = false
    }

    /// Re-probes all backends (convenience wrapper for pull-to-refresh, etc.).
    func refresh() async {
        await detectAndConnect()
    }

    // MARK: - Private Helpers
    
    /// Creates an OpenAI-compatible service from user preferences.
    private func createOpenAIService() -> OpenAICompatibleService? {
        guard let url = URL(string: openAIServerURL) else { return nil }
        let preset = LocalAIServerPreset.presets.first { $0.id == selectedPresetID }
        let name = preset?.name ?? "OpenAI Compatible"
        openAIServerName = name
        return OpenAICompatibleService(baseURL: url, model: selectedOpenAIModel, displayName: name)
    }
    
    /// Scans common local AI server ports to auto-detect running servers.
    private func autoDetectOpenAIServer() async -> (service: OpenAICompatibleService, name: String)? {
        // Only scan the most common, non-conflicting ports
        let scannablePresets = LocalAIServerPreset.presets.filter { $0.id != "custom" && $0.id != "localai" }
        
        for preset in scannablePresets {
            let service = OpenAICompatibleService(
                baseURL: preset.defaultURL,
                model: "default",
                displayName: preset.name
            )
            if await service.checkAvailability() {
                return (service, preset.name)
            }
        }
        return nil
    }
    
    /// Starts a background polling task that checks for backends silently
    private func startPolling() {
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                // Poll every 3 seconds
                try? await Task.sleep(for: .seconds(3))
                
                guard let self = self else { break }
                await self.performSilentCheck()
            }
        }
    }
    
    /// Silently checks if a better AI backend has come online, or if our current one dropped
    private func performSilentCheck() async {
        guard !isCheckingAvailability else { return }

        if MemoryPressureMonitor.shared.isUnderPressure { return }
        
        if currentBackend == .none {
            // Nothing connected — try to find anything
            await detectAndConnect()
        } else if currentBackend == .ollama {
            // We are using Ollama. Check if it suddenly crashed or quit.
            if await !ollamaService.checkAvailability() {
                await detectAndConnect()
            }
        } else if currentBackend == .openAICompatible {
            // We are using an OpenAI-compatible server. Check if it dropped.
            if let service = openAIService, await !service.checkAvailability() {
                await detectAndConnect()
            }
        }
    }

    /// Fetches the model list from Ollama and stores it in `availableModels`.
    private func loadOllamaModels() async {
        do {
            availableModels = try await ollamaService.listModels()
        } catch {
            availableModels = []
        }
    }
    
    /// Fetches the model list from an OpenAI-compatible server.
    private func loadOpenAIModels(_ service: OpenAICompatibleService) async {
        do {
            availableOpenAIModels = try await service.listModels()
            // Auto-select the first model if current selection is "default"
            if selectedOpenAIModel == "default", let first = availableOpenAIModels.first {
                selectedOpenAIModel = first.id
                await service.setModel(first.id)
            }
        } catch {
            availableOpenAIModels = []
        }
    }
}
