import Foundation

/// A type-safe representation of any JSON value.
///
/// Used for `PriestConfig.providerOptions`, `PriestRequest.metadata`, and
/// `PriestResponse.metadata` — fields that are `dict[str, Any]` in Python.
///
/// `[String: Any]` is not `Codable` or `Sendable` in Swift, so `JSONValue`
/// provides a zero-dependency alternative.
public indirect enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown JSON value type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:           try container.encodeNil()
        case .bool(let v):   try container.encode(v)
        case .int(let v):    try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v):  try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }
}

// MARK: - Equatable

extension JSONValue: Equatable {}

// MARK: - ExpressibleBy literals (convenience)

extension JSONValue: ExpressibleByNilLiteral    { public init(nilLiteral: ())          { self = .null } }
extension JSONValue: ExpressibleByBooleanLiteral { public init(booleanLiteral v: Bool) { self = .bool(v) } }
extension JSONValue: ExpressibleByIntegerLiteral { public init(integerLiteral v: Int)  { self = .int(v) } }
extension JSONValue: ExpressibleByFloatLiteral   { public init(floatLiteral v: Double) { self = .double(v) } }
extension JSONValue: ExpressibleByStringLiteral  { public init(stringLiteral v: String){ self = .string(v) } }
extension JSONValue: ExpressibleByArrayLiteral   {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

// MARK: - Serialization helper

extension JSONValue {
    /// Converts to a Foundation-compatible object for use with JSONSerialization.
    func toFoundation() -> Any {
        switch self {
        case .null:           return NSNull()
        case .bool(let v):   return v
        case .int(let v):    return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let v):  return v.map { $0.toFoundation() }
        case .object(let v): return v.mapValues { $0.toFoundation() }
        }
    }
}
