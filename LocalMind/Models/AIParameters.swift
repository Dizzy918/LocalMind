//
//  AIParameters.swift
//  LocalMind
//

import Foundation

/// Configuration parameters for AI generation.
public struct AIParameters: Codable, Equatable, Sendable {
    /// Controls the randomness of the output. Higher values (e.g. 0.8) make the output more random, while lower values (e.g. 0.2) make it more focused and deterministic.
    public var temperature: Double
    
    /// An alternative to sampling with temperature, called nucleus sampling, where the model considers the results of the tokens with top_p probability mass.
    public var topP: Double?
    
    /// The maximum number of tokens to generate. If nil, the model uses its default.
    public var maxTokens: Int?
    
    /// The maximum context window size in tokens.
    public var contextLength: Int?
    
    /// Default parameters.
    public static let `default` = AIParameters(
        temperature: 0.7,
        topP: nil,
        maxTokens: nil,
        contextLength: 4096
    )
    
    public init(temperature: Double = 0.7, topP: Double? = nil, maxTokens: Int? = nil, contextLength: Int? = 4096) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.contextLength = contextLength
    }
}
