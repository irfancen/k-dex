import Foundation

/// A dynamic JSON tree used to represent arbitrary Kubernetes objects without
/// needing a typed model for every resource kind.
nonisolated enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

nonisolated extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

nonisolated extension JSONValue {
    subscript(key: String) -> JSONValue {
        if case .object(let dict) = self, let value = dict[key] { return value }
        return .null
    }

    subscript(index: Int) -> JSONValue {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return .null
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// String content, or empty string when absent.
    var stringValue: String { string ?? "" }

    var double: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    var int: Int? {
        switch self {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var array: [JSONValue] {
        if case .array(let items) = self { return items }
        return []
    }

    var object: [String: JSONValue] {
        if case .object(let dict) = self { return dict }
        return [:]
    }

    /// Human-readable rendering of a scalar value ("80", "true", "nginx").
    var displayString: String {
        switch self {
        case .null: return ""
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
            return String(value)
        case .string(let value): return value
        case .array(let items): return items.map(\.displayString).joined(separator: ", ")
        case .object: return "{…}"
        }
    }

    /// Flattens an object of scalar values into `[key: value]` strings (labels, annotations).
    var stringDictionary: [String: String] {
        object.mapValues { $0.displayString }
    }

    func prettyJSONString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
