//
//  CustomTool.swift
//  LocalMind
//
//  Created by Radoslav Slavov on 23.06.26.
//

import Foundation

struct CustomTool: Identifiable, Codable, Sendable, Hashable {
    var id: String { name } // Using name as ID for simplicity, assuming unique names
    var name: String
    var icon: String
    var systemPrompt: String
    
    // Optional prompt template prefix (e.g. "Summarize the following:")
    var promptTemplate: String?
}
