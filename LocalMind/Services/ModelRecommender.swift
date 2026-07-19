//
//  ModelRecommender.swift
//  LocalMind
//
//  Picks a sensible first Ollama model for this Mac's hardware, so new
//  users don't have to research quantization and parameter counts before
//  their first conversation.
//

import Foundation

nonisolated enum ModelRecommender {

    struct Recommendation: Sendable, Equatable {
        /// The Ollama model tag to pull, e.g. "qwen3:8b".
        let modelID: String
        /// Approximate download size, shown before pulling.
        let downloadSize: String
        /// One-line justification shown next to the suggestion.
        let reason: String
    }

    /// The installed physical memory, in whole gigabytes.
    static var installedMemoryGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }

    /// Maps installed RAM to a first model that runs comfortably — roughly
    /// half of memory left free for the system and other apps. Conservative
    /// on purpose: a fast good-enough first answer beats a slow great one.
    static func recommendation(forMemoryGB memoryGB: Int) -> Recommendation {
        switch memoryGB {
        case ..<12:
            return Recommendation(
                modelID: "qwen3:4b",
                downloadSize: "2.6 GB",
                reason: "Small and quick — the right fit for \(memoryGB) GB of memory."
            )
        case ..<24:
            return Recommendation(
                modelID: "qwen3:8b",
                downloadSize: "5.2 GB",
                reason: "The sweet spot for \(memoryGB) GB of memory — capable and fast."
            )
        case ..<48:
            return Recommendation(
                modelID: "qwen3:14b",
                downloadSize: "9.3 GB",
                reason: "Your \(memoryGB) GB of memory runs this larger model comfortably."
            )
        default:
            return Recommendation(
                modelID: "qwen3:32b",
                downloadSize: "20 GB",
                reason: "With \(memoryGB) GB of memory this Mac handles a heavyweight model."
            )
        }
    }

    /// Convenience for the current machine.
    static func recommendationForThisMac() -> Recommendation {
        recommendation(forMemoryGB: installedMemoryGB)
    }
}
