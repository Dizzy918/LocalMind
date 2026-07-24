//
//  LocalMindIntents.swift
//  LocalMind
//
//  Shortcuts / App Intents support.
//
//  The localmind:// URL scheme could already start an ask, but it's
//  fire-and-forget: a Shortcut can hand LocalMind a prompt and gets nothing
//  back, so the answer can't feed the rest of the workflow. These intents
//  return their result, which is what makes the app composable with the rest
//  of macOS — summarise the selected text and paste it, ask a question and
//  save the answer to a note, search your documents from Spotlight.
//
//  Asks run through the normal generation pipeline, so an automated ask gets
//  the same agent persona, project context, knowledge base, memory, and tools
//  as one typed into the app.
//

import AppIntents
import Foundation

// MARK: - Ask

struct AskLocalMindIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask LocalMind"
    static var description = IntentDescription(
        "Ask your local AI a question and get the answer back, entirely on this Mac.",
        categoryName: "Chat"
    )

    /// The app has to be running to answer: generation goes through the live
    /// backend connection and the user's stores.
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Prompt", requestValueDialog: "What should I ask?")
    var prompt: String

    @Parameter(
        title: "Agent",
        description: "Name of an agent to answer as. Leave empty for the default assistant."
    )
    var agentName: String?

    @Parameter(
        title: "Save to History",
        description: "Keep the exchange in LocalMind's conversation list.",
        default: true
    )
    var keepInHistory: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Ask LocalMind \(\.$prompt)") {
            \.$agentName
            \.$keepInHistory
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AutomationIntentError.emptyPrompt
        }
        guard AppServices.isReadyForAutomation, let generation = AppServices.generationService else {
            throw AutomationIntentError.notReady
        }

        let answer = try await generation.generateForAutomation(
            prompt: trimmed,
            agentName: agentName,
            keepInHistory: keepInHistory
        )
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

// MARK: - Search the knowledge base

struct SearchKnowledgeBaseIntent: AppIntent {
    static var title: LocalizedStringResource = "Search LocalMind Documents"
    static var description = IntentDescription(
        "Search your indexed documents and get the passages that match, without generating an answer.",
        categoryName: "Knowledge"
    )

    static var openAppWhenRun: Bool = true

    @Parameter(title: "Query", requestValueDialog: "What should I look for?")
    var query: String

    @Parameter(title: "Number of Passages", default: 4, inclusiveRange: (1, 10))
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Search LocalMind documents for \(\.$query)") {
            \.$limit
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AutomationIntentError.emptyPrompt }

        let hits = await KnowledgeBaseStore.shared.retrieve(trimmed, topK: limit)
        // Each passage names its document so the result is usable on its own
        // once it's out of the app and in a note or a message.
        let passages = hits.map { "\($0.documentName): \($0.text)" }
        return .result(value: passages)
    }
}

// MARK: - Start a new conversation

struct NewConversationIntent: AppIntent {
    static var title: LocalizedStringResource = "New LocalMind Chat"
    static var description = IntentDescription(
        "Open LocalMind with a fresh, empty conversation.",
        categoryName: "Chat"
    )

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard AppServices.isReadyForAutomation else { throw AutomationIntentError.notReady }
        NotificationCenter.default.post(name: .newConversation, object: nil)
        return .result()
    }
}

// MARK: - Errors

enum AutomationIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case emptyPrompt

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady:
            return "LocalMind isn't ready yet — open it and sign in, then try again."
        case .emptyPrompt:
            return "The prompt was empty."
        }
    }
}

// MARK: - Shortcuts gallery

/// Surfaces the intents in the Shortcuts app and Spotlight with spoken
/// phrases. `applicationName` resolves to the app's name, so the phrases read
/// naturally without hard-coding it.
struct LocalMindShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskLocalMindIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
                "Question for \(.applicationName)"
            ],
            shortTitle: "Ask LocalMind",
            systemImageName: "brain.head.profile"
        )
        AppShortcut(
            intent: SearchKnowledgeBaseIntent(),
            phrases: [
                "Search \(.applicationName) documents",
                "Search my documents in \(.applicationName)"
            ],
            shortTitle: "Search Documents",
            systemImageName: "doc.text.magnifyingglass"
        )
        AppShortcut(
            intent: NewConversationIntent(),
            phrases: [
                "New chat in \(.applicationName)",
                "Start a new \(.applicationName) chat"
            ],
            shortTitle: "New Chat",
            systemImageName: "square.and.pencil"
        )
    }
}
