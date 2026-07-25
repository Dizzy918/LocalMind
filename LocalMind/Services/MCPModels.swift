//
//  MCPModels.swift
//  LocalMind
//

import Foundation

// MARK: - JSON-RPC 2.0

struct JSONRPCRequest: Codable, Sendable {
    let jsonrpc: String
    let id: JSONRPCID
    let method: String
    let params: [String: AnyCodable]?

    init(id: JSONRPCID, method: String, params: [String: AnyCodable]?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

struct JSONRPCResponse: Codable, Sendable {
    let jsonrpc: String
    let id: JSONRPCID
    let result: AnyCodable?
    let error: JSONRPCError?
}

struct JSONRPCNotification: Codable, Sendable {
    let jsonrpc: String
    let method: String
    let params: [String: AnyCodable]?
}

struct JSONRPCError: Codable, Sendable, Error {
    let code: Int
    let message: String
    let data: AnyCodable?
}

enum JSONRPCID: Codable, Sendable, Hashable {
    case string(String)
    case number(Int)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let num = try? container.decode(Int.self) {
            self = .number(num)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .null: try container.encodeNil()
        }
    }
}

/// Type-erased Codable wrapper for arbitrary JSON values.
struct AnyCodable: @unchecked Sendable, Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode AnyCodable")
        }
    }

    /// The wrapped value as plain Foundation types, safe to hand to
    /// `JSONSerialization`.
    ///
    /// `AnyCodable` is a Swift struct, so passing one into
    /// `JSONSerialization.data(withJSONObject:)` — directly or nested inside a
    /// dictionary — raises `NSInvalidArgumentException`. That's an
    /// Objective-C exception, which `try` does **not** catch: it terminates the
    /// process. Anything built for JSONSerialization must go through this.
    var jsonValue: Any { Self.unwrapped(value) }

    static func unwrapped(_ value: Any) -> Any {
        if let wrapped = value as? AnyCodable { return unwrapped(wrapped.value) }
        if let array = value as? [Any] { return array.map(unwrapped) }
        if let dictionary = value as? [String: Any] { return dictionary.mapValues(unwrapped) }
        return value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull: try container.encodeNil()
        case let v as Bool: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as String: try container.encode(v)
        case let v as [Any]: try container.encode(v.map(AnyCodable.init))
        case let v as [String: Any]: try container.encode(v.mapValues(AnyCodable.init))
        case let v as AnyCodable: try v.encode(to: encoder)
        default:
            let context = EncodingError.Context(codingPath: container.codingPath, debugDescription: "Cannot encode value of type \(type(of: value))")
            throw EncodingError.invalidValue(value, context)
        }
    }
}

// MARK: - MCP Protocol

struct MCPInitializeRequest: Codable, Sendable {
    let protocolVersion: String
    let capabilities: MCPClientCapabilities
    let clientInfo: MCPImplementation
}

struct MCPClientCapabilities: Codable, Sendable {
    let roots: MCPRootsCapability?
    let sampling: MCPSamplingCapability?
}

struct MCPRootsCapability: Codable, Sendable {
    let listChanged: Bool?
}

struct MCPSamplingCapability: Codable, Sendable {}

struct MCPImplementation: Codable, Sendable {
    let name: String
    let version: String
}

struct MCPInitializeResponse: Codable, Sendable {
    let protocolVersion: String
    let capabilities: MCPServerCapabilities
    let serverInfo: MCPImplementation
}

struct MCPServerCapabilities: Codable, Sendable {
    let tools: MCPToolsCapability?
    let resources: MCPResourcesCapability?
    let prompts: MCPPromptsCapability?
    let logging: MCPLoggingCapability?
}

struct MCPToolsCapability: Codable, Sendable {
    let listChanged: Bool?
}

struct MCPResourcesCapability: Codable, Sendable {
    let subscribe: Bool?
    let listChanged: Bool?
}

struct MCPPromptsCapability: Codable, Sendable {
    let listChanged: Bool?
}

struct MCPLoggingCapability: Codable, Sendable {}

struct MCPTool: Codable, Sendable, Identifiable, Hashable {
    let name: String
    let description: String?
    let inputSchema: AnyCodable

    var id: String { name }

    static func == (lhs: MCPTool, rhs: MCPTool) -> Bool { lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

struct MCPListToolsResponse: Codable, Sendable {
    let tools: [MCPTool]
    let nextCursor: String?
}

struct MCPCallToolResponse: Codable, Sendable {
    let content: [MCPToolContent]
    let isError: Bool?
}

struct MCPToolContent: Codable, Sendable {
    let type: String
    let text: String?
    let data: String?
    let mimeType: String?
}

// MARK: - Server Configuration

struct MCPServerConfig: Codable, Sendable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var transport: MCPTransport
    var enabled: Bool
}

enum MCPTransport: Codable, Sendable, Hashable {
    case stdio(command: String, args: [String], env: [String: String]?)
    case http(url: String, headers: [String: String]?)

    enum CodingKeys: String, CodingKey {
        case type, command, args, env, url, headers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "stdio":
            let command = try container.decode(String.self, forKey: .command)
            let args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
            let env = try container.decodeIfPresent([String: String].self, forKey: .env)
            self = .stdio(command: command, args: args, env: env)
        case "http":
            let url = try container.decode(String.self, forKey: .url)
            let headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
            self = .http(url: url, headers: headers)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown transport type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stdio(let command, let args, let env):
            try container.encode("stdio", forKey: .type)
            try container.encode(command, forKey: .command)
            try container.encode(args, forKey: .args)
            try container.encodeIfPresent(env, forKey: .env)
        case .http(let url, let headers):
            try container.encode("http", forKey: .type)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(headers, forKey: .headers)
        }
    }
}

// MARK: - Log Line

struct MCPLogLine: Sendable, Hashable, Identifiable {
    enum Source: String, Sendable { case stderr, transport }

    let id = UUID()
    let timestamp: Date
    let source: Source
    let text: String
}

// MARK: - Connection State

enum MCPConnectionState: Sendable {
    case disconnected
    case connecting
    case connected(serverInfo: MCPImplementation, capabilities: MCPServerCapabilities)
    case failed(String)
}
