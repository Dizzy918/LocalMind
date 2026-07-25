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

    /// Generations currently in flight. A backend serving a request is alive,
    /// so health probing pauses while this is non-zero.
    private var activeRequests = 0
    /// Consecutive failed health probes for the current backend.
    private var consecutiveHealthFailures = 0
    /// One missed probe is usually a busy machine, not a dead server.
    private static let healthFailuresBeforeRedetect = 2
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

    /// Test-only seam: pins a specific service as the current one and stops
    /// background polling so a live local server can't replace it mid-test.
    /// Production code must never call this — connections go through
    /// `detectAndConnect()`.
    func setServiceForTesting(_ service: any AIServiceProtocol) {
        pollingTask?.cancel()
        currentService = service
        currentBackend = service.backend
        statusMessage = "Connected to \(service.backendName)"
        isCheckingAvailability = false
    }

    /// Runs tool calls and returns their results paired with the originating
    /// call id, so they can be fed back to the model as `.tool` messages.
    func runToolCalls(_ calls: [AIToolCall]) async -> [AIToolResult] {
        guard let mcpService else {
            return calls.map { AIToolResult(toolCallId: $0.id, content: "No tool backend is connected.", isError: true) }
        }
        var results: [AIToolResult] = []
        for call in calls {
            let started = Date()
            do {
                let argsData = call.arguments.data(using: .utf8) ?? Data()
                let args = (try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]) ?? [:]
                let content = try await mcpService.callTool(name: call.name, arguments: args)
                let textParts = content.compactMap { $0.text }.joined(separator: "\n")
                results.append(AIToolResult(
                    toolCallId: call.id,
                    content: textParts.isEmpty ? "(empty result)" : textParts,
                    seconds: Date().timeIntervalSince(started)
                ))
            } catch {
                results.append(AIToolResult(
                    toolCallId: call.id,
                    content: "Error — \(error.localizedDescription)",
                    isError: true,
                    seconds: Date().timeIntervalSince(started)
                ))
            }
        }
        return results
    }

    /// Streams an assistant turn, transparently running any MCP tool calls the
    /// model makes and feeding the results back for a follow-up turn — looping
    /// until the model answers without calling tools (or `maxToolRounds` is
    /// reached). This is what makes tools actually *usable*: the previous code
    /// dumped raw tool output into the message and never let the model read it.
    ///
    /// Each tool call is gated (and audited) downstream in `MCPService.callTool`
    /// via the user's approval setting — a denial simply comes back as an error
    /// result the model can react to, so no approval logic lives here.
    ///
    /// The tool-call/result turns live only in a local working list. What comes
    /// back is the model's own text with tool markers excluded (so it persists
    /// as a clean answer), the marker-inclusive text the user actually watched,
    /// and a `ToolRun` per call for the message's durable transcript. A live
    /// `_🔧 name_` marker still goes out through `onDelta` so the wait reads as
    /// productive while a tool is running.
    func streamChatWithTools(
        service: any AIServiceProtocol,
        messages: [ChatMessage],
        systemPrompt: String,
        modelOverride: String?,
        parameters: AIParameters,
        tools: [AITool]?,
        maxToolRounds: Int = 5,
        shouldContinue: @escaping () -> Bool = { true },
        onDelta: (String) -> Void
    ) async throws -> ToolAugmentedAnswer {
        // Pauses health probing for the duration: a backend that's answering
        // is alive, and probing it under load is what used to knock it out.
        activeRequests += 1
        defer { activeRequests -= 1 }

        var working = messages
        /// One entry per round of model-generated text; joined at the end so
        /// an answer split across tool rounds reads as paragraphs.
        var answerSegments: [String] = []
        var displayText = ""
        var toolRuns: [ToolRun] = []
        var round = 0
        /// Usage accumulates across tool rounds — each round is a separate
        /// backend call, and the answer's cost is all of them together.
        var totalUsage: AIUsage?

        func absorb(_ usage: AIUsage) {
            var running = totalUsage ?? AIUsage()
            running.promptTokens = sum(running.promptTokens, usage.promptTokens)
            running.completionTokens = sum(running.completionTokens, usage.completionTokens)
            running.generationSeconds = sum(running.generationSeconds, usage.generationSeconds)
            totalUsage = running
        }

        func answer() -> ToolAugmentedAnswer {
            ToolAugmentedAnswer(
                text: answerSegments
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n"),
                displayText: displayText,
                toolRuns: toolRuns,
                usage: totalUsage
            )
        }

        while true {
            var turnText = ""
            var pending: [AIToolCall] = []

            for try await chunk in service.streamChat(
                messages: working,
                systemPrompt: systemPrompt,
                modelOverride: modelOverride,
                parameters: parameters,
                tools: tools
            ) {
                if !shouldContinue() {
                    answerSegments.append(turnText)
                    return answer()
                }
                switch chunk {
                case .text(let text):
                    turnText += text
                    displayText += text
                    onDelta(text)
                case .toolCall(let call):
                    pending.append(call)
                case .toolCalls(let calls):
                    pending.append(contentsOf: calls)
                case .usage(let usage):
                    absorb(usage)
                case .toolRuns(let runs):
                    // A backend that ran its own tool loop (Apple
                    // Intelligence) reports what it did; there's nothing for
                    // this loop to execute, only to record.
                    toolRuns.append(contentsOf: runs)
                case .done:
                    break
                }
            }

            answerSegments.append(turnText)

            // Drop malformed calls (empty names) defensively.
            pending = pending.filter { !$0.name.isEmpty }

            // No tools available, none requested, or we've hit the safety cap:
            // this turn is the final answer.
            guard tools != nil, !pending.isEmpty, round < maxToolRounds else {
                return answer()
            }
            round += 1
            if !shouldContinue() { return answer() }

            // Record the assistant's tool-call turn so the follow-up round has
            // coherent context, and show a compact live marker of what ran.
            var assistantTurn = ChatMessage(role: .assistant, content: turnText)
            assistantTurn.toolCalls = pending
            working.append(assistantTurn)

            let marker = "\n\n_🔧 \(pending.map(\.name).joined(separator: ", "))_\n\n"
            displayText += marker
            onDelta(marker)

            // Execute (each call is approval-gated inside MCPService.callTool)
            // and feed the results back as tool messages.
            let results = await runToolCalls(pending)
            for (call, result) in zip(pending, results) {
                toolRuns.append(ToolRun(
                    name: call.name,
                    arguments: call.arguments,
                    result: result.content,
                    isError: result.isError,
                    seconds: result.seconds
                ))
                var toolMessage = ChatMessage(role: .tool, content: result.content)
                toolMessage.toolCallID = call.id
                working.append(toolMessage)
            }

            if !shouldContinue() { return answer() }
            // Loop: stream the model's follow-up turn with the results in context.
        }
    }

    /// The tools an agent may use, honouring its own settings: tools can be
    /// switched off entirely or narrowed to a named subset. nil means "send no
    /// tools", which is what every caller wants when nothing is available.
    ///
    /// Shared so every surface that runs an agent applies the same rules —
    /// agents carry tool settings, and a surface that ignored them would let a
    /// user configure something that silently does nothing.
    func tools(for agent: Agent?) -> [AITool]? {
        guard agent?.allowTools ?? true else { return nil }
        var available = getAvailableTools()
        if let allowed = agent?.allowedToolIDs {
            available = available.filter { allowed.contains($0.name) }
        }
        return available.isEmpty ? nil : available
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

    // MARK: - Cross-backend Resolution

    /// Resolves a live service for a specific backend, regardless of which
    /// one is currently active. This is what lets an agent pinned to Ollama
    /// answer while the app is connected to Apple Intelligence (and lets a
    /// team run mix backends). Falls back to the current service when the
    /// requested backend is unreachable, so a dead pin degrades gracefully
    /// instead of erroring.
    func service(matching backend: AIBackend?) async -> (any AIServiceProtocol)? {
        guard let backend, backend != currentBackend else { return currentService }
        switch backend {
        case .appleFoundationModels:
            if let apple = appleService, await apple.checkAvailability() {
                return apple
            }
        case .ollama:
            if await ollamaService.checkAvailability() {
                // The service's default model is only set when Ollama becomes
                // the active backend — make sure a cross-backend call doesn't
                // run whatever model a previous session left behind.
                await ollamaService.setModel(selectedOllamaModel)
                return ollamaService
            }
        case .openAICompatible:
            if let existing = openAIService, await existing.checkAvailability() {
                return existing
            }
            if let created = createOpenAIService(), await created.checkAvailability() {
                openAIService = created
                return created
            }
        case .none:
            break
        }
        return currentService
    }

    /// Whether a specific backend is reachable right now. Used by the agent
    /// editor to hint at dead pins.
    func isBackendAvailable(_ backend: AIBackend) async -> Bool {
        switch backend {
        case .appleFoundationModels:
            guard let apple = appleService else { return false }
            return await apple.checkAvailability()
        case .ollama:
            return await ollamaService.checkAvailability()
        case .openAICompatible:
            if let existing = openAIService { return await existing.checkAvailability() }
            guard let created = createOpenAIService() else { return false }
            return await created.checkAvailability()
        case .none:
            return false
        }
    }

    /// Model IDs offered by a specific backend, fetched live when that
    /// backend isn't the active one. Drives the agent editor's model picker.
    func modelIDs(for backend: AIBackend) async -> [String] {
        switch backend {
        case .ollama:
            if backend == currentBackend, !availableModels.isEmpty {
                return availableModels.map(\.name)
            }
            return (try? await ollamaService.listModels())?.map(\.name) ?? []
        case .openAICompatible:
            if backend == currentBackend, !availableOpenAIModels.isEmpty {
                return availableOpenAIModels.map(\.id)
            }
            if let existing = openAIService {
                return (try? await existing.listModels())?.map(\.id) ?? []
            }
            if let created = createOpenAIService() {
                return (try? await created.listModels())?.map(\.id) ?? []
            }
            return []
        case .appleFoundationModels, .none:
            return []
        }
    }

    /// The model name a given agent will actually answer with right now,
    /// for display ("Ollama · qwen3:8b"). Purely cosmetic — the authoritative
    /// resolution happens at generation time.
    func resolvedModelDescription(for agent: Agent?) -> String {
        let backend = agent?.backend ?? currentBackend
        let model: String
        if let pinned = agent?.modelID {
            model = pinned
        } else {
            switch backend {
            case .ollama: model = selectedOllamaModel
            case .openAICompatible: model = selectedOpenAIModel
            case .appleFoundationModels: model = "on-device"
            case .none: model = "—"
            }
        }
        switch backend {
        case .appleFoundationModels: return "Apple Intelligence"
        case .none: return "No backend"
        default: return "\(backend.rawValue) · \(model)"
        }
    }

    // MARK: - Model Management

    /// Streams the download of an Ollama model (the in-app "pull").
    func pullOllamaModel(_ name: String) -> AsyncThrowingStream<OllamaPullProgress, Error> {
        ollamaService.pullModel(name)
    }

    /// Deletes a local Ollama model and refreshes the model list.
    func deleteOllamaModel(_ name: String) async throws {
        try await ollamaService.deleteModel(name)
        await loadOllamaModels()
    }

    /// Refreshes the active backend's model list (after pulls/deletes).
    func refreshModelList() async {
        switch currentBackend {
        case .ollama:
            await loadOllamaModels()
        case .openAICompatible:
            if let service = openAIService { await loadOpenAIModels(service) }
        case .appleFoundationModels, .none:
            break
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
                // Poll every 3 seconds. `try?` would swallow the cancellation
                // error the sleep throws, letting one more check run after the
                // task was cancelled — which is exactly when something else has
                // just taken ownership of the connection.
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }

                guard let self = self else { break }
                await self.performSilentCheck()
            }
        }
    }
    
    /// Silently checks if a better AI backend has come online, or if our current one dropped
    private func performSilentCheck() async {
        guard !isCheckingAvailability else { return }

        if MemoryPressureMonitor.shared.isUnderPressure { return }

        // A backend that's mid-generation is alive by definition. Probing it
        // anyway was actively harmful: local servers saturate the CPU while
        // generating, the health request gets starved, and a single missed
        // probe used to tear down the working connection — leaving
        // `currentService` nil and the next request failing with "No AI
        // backend available" while the model was still happily running. That
        // lands hardest on Shortcuts and scheduled runs, where nobody is
        // watching to retry.
        guard activeRequests == 0 else {
            consecutiveHealthFailures = 0
            return
        }

        if currentBackend == .none {
            // Nothing connected — try to find anything
            await detectAndConnect()
            return
        }

        let stillUp: Bool
        switch currentBackend {
        case .ollama:
            stillUp = await ollamaService.checkAvailability()
        case .openAICompatible:
            stillUp = await openAIService?.checkAvailability() ?? false
        case .appleFoundationModels, .none:
            // On-device: nothing to probe over the network.
            stillUp = true
        }

        if stillUp {
            consecutiveHealthFailures = 0
            return
        }

        // Only give up on a connection after it fails twice in a row. One
        // missed probe is far more often a busy machine than a dead server,
        // and re-detecting costs the user their selected backend and model.
        consecutiveHealthFailures += 1
        guard consecutiveHealthFailures >= Self.healthFailuresBeforeRedetect else { return }
        consecutiveHealthFailures = 0
        await detectAndConnect()
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
