import Foundation

// Wire types are deliberately independent of SwiftUI, draft storage and BLE.
struct RuntimeVersion: Codable, Equatable {
    var major: Int
    var minor: Int
}

struct RuntimeHello: Codable {
    var `protocol`: RuntimeVersion
    var instanceId: String
    var runtimeVersion: String
    var methods: [String]
}

struct RuntimeDevice: Codable, Equatable, Identifiable {
    var deviceId: String
    var name: String
    var connectionState: String
    var batteryPercent: Int?
    var workMode: Int?
    var lever: String?
    var id: String { deviceId }
    var isReady: Bool { connectionState == "ready" }
}

struct RuntimeOperation: Codable, Equatable, Identifiable {
    var operationId: String
    var deviceId: String
    var status: String
    var progress: Double?
    var errorCode: String?
    var effect: String?
    var id: String { operationId }
    var isTerminal: Bool { ["completed", "failed", "cancelled"].contains(status) }
}

struct RuntimeSnapshot: Codable {
    var instanceId: String
    var sequence: String
    var devices: [RuntimeDevice]
    var operations: [RuntimeOperation]
}

struct RuntimeSubscription: Codable {
    var subscriptionId: String
    var snapshot: RuntimeSnapshot
}

struct RuntimeEvent: Codable {
    var subscriptionId: String
    var instanceId: String
    var sequence: String
    var type: String
    var data: RPCValue
}

struct RuntimeSession {
    var hello: RuntimeHello
    var subscription: RuntimeSubscription
}

struct ConfigurationDocument: Codable {
    var deviceId: String
    var baseToken: String
    // nil means the backend cannot establish a baseline, never factory defaults.
    var configuration: DeviceConfiguration?
}

struct DeviceConfiguration: Codable, Equatable {
    var device: DeviceFields
    var modes: [ModeConfiguration]
}

struct DeviceFields: Codable, Equatable {
    var brightnessPercent: Int
}

struct ModeConfiguration: Codable, Equatable {
    var mode: Int
    var keys: [KeyConfiguration]
    var lights: [LightMapping]
}

struct KeyConfiguration: Codable, Equatable {
    var role: String
    var action: KeyAction
    var description: String
}

enum KeyAction: Codable, Equatable {
    case disabled
    case shortcut(modifiers: [String], keyCode: Int)
    case macro(steps: [RuntimeMacroStep])

    private enum CodingKeys: String, CodingKey { case type, modifiers, keyCode, steps }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "disabled": self = .disabled
        case "shortcut": self = .shortcut(
            modifiers: try c.decode([String].self, forKey: .modifiers),
            keyCode: try c.decode(Int.self, forKey: .keyCode))
        case "macro": self = .macro(steps: try c.decode([RuntimeMacroStep].self, forKey: .steps))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown key action")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .disabled: try c.encode("disabled", forKey: .type)
        case let .shortcut(modifiers, keyCode):
            try c.encode("shortcut", forKey: .type)
            try c.encode(modifiers, forKey: .modifiers)
            try c.encode(keyCode, forKey: .keyCode)
        case let .macro(steps):
            try c.encode("macro", forKey: .type)
            try c.encode(steps, forKey: .steps)
        }
    }
}

struct RuntimeMacroStep: Codable, Equatable {
    var type: String
    var keyCode: Int?
    var delayMs: Int?
}

struct LightMapping: Codable, Equatable {
    var state: String
    var effect: String
}

struct ApplyConfiguration: Codable, Equatable {
    struct Scope: Codable, Equatable {
        var deviceFields: [String]
        var modes: [Int]
    }
    var operationId: String
    var deviceId: String
    var baseToken: String
    var scope: Scope
    var changes: DeviceConfiguration
}

struct OperationAccepted: Codable { var operationId: String; var status: String }

enum RuntimeFailure: Error, LocalizedError, Equatable {
    case unavailable, disconnected, timeout, invalidEndpoint, incompatibleProtocol, invalidMessage
    case unsupported(String)
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Runtime unavailable"
        case .disconnected: return "Runtime disconnected"
        case .timeout: return "Runtime request timed out; an accepted operation may still be running"
        case .invalidEndpoint: return "Invalid or non-private Runtime discovery file"
        case .incompatibleProtocol: return "Incompatible Runtime protocol"
        case .invalidMessage: return "Invalid Runtime message"
        case .unsupported(let method): return "Unsupported: \(method)"
        case .remote(let code): return code
        }
    }
}

enum RPCValue: Codable, Equatable {
    case object([String: RPCValue]), array([RPCValue]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: RPCValue].self) { self = .object(v) }
        else { self = .array(try c.decode([RPCValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    static func encoded<T: Encodable>(_ value: T) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }
    func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
    subscript(_ key: String) -> RPCValue? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }
    var string: String? { if case .string(let v) = self { return v }; return nil }
}
