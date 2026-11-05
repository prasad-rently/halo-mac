import Foundation

/// A Sendable JSON tree — what the Realtime Database speaks. Used instead of `Any` so values can cross
/// actor boundaries and be compared in tests.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d):
            // Whole numbers go out as integers ("1800000000000", not "1.8e12"): the Kotlin and Swift
            // desktop readers parse the field as a number either way, but a human reading the console
            // and any strict reader should see what the other writers write.
            if d == d.rounded(), abs(d) < 9_007_199_254_740_992 { try c.encode(Int64(d)) } else { try c.encode(d) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        if data.isEmpty { return .null }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func serialized() throws -> Data { try JSONEncoder().encode(self) }

    // Convenience accessors; nil on a type mismatch (callers treat a malformed node as skippable).
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var doubleValue: Double? { if case .number(let d) = self { return d } else { return nil } }
    public var intValue: Int? { doubleValue.flatMap { $0.isFinite && abs($0) < 9e15 ? Int($0) : nil } }
    /// Children keyed by name. The Realtime Database renders a node whose keys are small integers (SIM
    /// subscription ids "1","2") as a JSON *array* with `null` holes — `[null, {...}, {...}]` — so a reader that
    /// only accepts objects silently loses every line on a two-SIM phone. This view treats an array as its
    /// index-keyed object, skipping the holes.
    public var children: [String: JSONValue]? {
        switch self {
        case .object(let o): return o
        case .array(let a):
            var out: [String: JSONValue] = [:]
            for (i, v) in a.enumerated() where !v.isNull { out[String(i)] = v }
            return out
        default: return nil
        }
    }
    public var isNull: Bool { if case .null = self { return true } else { return false } }
    public subscript(key: String) -> JSONValue? { objectValue?[key] }
}
