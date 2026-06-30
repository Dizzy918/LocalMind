//
//  EmbeddingProvider.swift
//  LocalMind
//
//  Pluggable embedding backends for the knowledge base. Apple's NaturalLanguage
//  is the always-available default; Ollama's `nomic-embed-text` gives markedly
//  better retrieval when the user is running Ollama and has pulled the model.
//
//  A store is locked to whichever provider built it — vectors from different
//  models have different dimensions and aren't comparable — so switching
//  providers requires re-indexing.
//

import Foundation

protocol EmbeddingProvider: Sendable {
    /// Stable identifier persisted with the store (e.g. "apple",
    /// "ollama:nomic-embed-text").
    var id: String { get }
    /// Embeds text, or nil if the provider can't produce a vector right now.
    func embed(_ text: String) async -> [Double]?
    /// Cheap check that the provider is usable at this moment.
    func probe() async -> Bool
}

extension EmbeddingProvider {
    /// Human-readable label for the UI.
    var label: String {
        if id.hasPrefix("ollama:") { return "Ollama (\(id.dropFirst("ollama:".count)))" }
        return "On-device (Apple)"
    }
}

/// Apple NaturalLanguage embeddings — offloaded so a big document doesn't
/// block the main actor.
struct AppleEmbeddingProvider: EmbeddingProvider {
    let id = "apple"
    func embed(_ text: String) async -> [Double]? {
        await Task.detached(priority: .userInitiated) { EmbeddingService.embed(text) }.value
    }
    func probe() async -> Bool { EmbeddingService.isAvailable }
}

/// Ollama embeddings via POST /api/embeddings.
struct OllamaEmbeddingProvider: EmbeddingProvider {
    let model: String
    let baseURL: URL

    init(model: String = "nomic-embed-text", baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.model = model
        self.baseURL = baseURL
    }

    var id: String { "ollama:\(model)" }

    func embed(_ text: String) async -> [Double]? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/embeddings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "prompt": text])

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vector = object["embedding"] as? [Double],
              !vector.isEmpty else {
            return nil
        }
        return vector
    }

    /// Embedding a tiny string both checks reachability and that the model is
    /// actually pulled (Ollama errors otherwise).
    func probe() async -> Bool { await embed("ping") != nil }
}
