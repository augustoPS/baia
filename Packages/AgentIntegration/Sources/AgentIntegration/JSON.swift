import Foundation

/// A JSON document that remembers the order its object keys were written in.
///
/// **Order is the reason this type exists**, and it is not tidiness.
/// `JSONSerialization` hands back an `NSDictionary`, and `BaiaSettings.JSONValue`
/// models an object as `[String: JSONValue]`; both lose key order, and
/// `SettingsWriter` already says what that costs: "Sorted output would scramble a
/// document grouped by subject, and the file is where the owner learns the
/// spellings." It says that about baia's own config.
///
/// This type edits `~/.claude/settings.json`, which baia does not own at all.
/// Measured on this machine 2026-07-30: 8,841 bytes, 295 lines, twenty-two
/// top-level keys in a deliberate non-alphabetical order. Round-tripping it
/// through any unordered model would rewrite every line of a file the owner hand
/// edits, on an install that was supposed to add two hooks.
public indirect enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object(JSONObject)
}

/// An object whose keys keep the order they were parsed in.
///
/// Insertion appends; assigning to a key that exists replaces in place and does
/// not move it. That is what makes a second install idempotent in the file as
/// well as in the model.
public struct JSONObject: Equatable, Sendable {
    public private(set) var keys: [String] = []
    private var values: [String: JSON] = [:]

    public init() {}

    public init(_ pairs: [(String, JSON)]) {
        for (key, value) in pairs { self[key] = value }
    }

    public subscript(key: String) -> JSON? {
        get { values[key] }
        set {
            guard let newValue else {
                keys.removeAll { $0 == key }
                values[key] = nil
                return
            }
            if values[key] == nil { keys.append(key) }
            values[key] = newValue
        }
    }

    public var isEmpty: Bool { keys.isEmpty }

    /// Equal when the same keys hold the same values **in the same order**, so a
    /// round-trip test can assert that a document came back as it went in rather
    /// than merely carrying the same facts.
    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        guard lhs.keys == rhs.keys else { return false }
        return lhs.keys.allSatisfy { lhs.values[$0] == rhs.values[$0] }
    }
}

// MARK: - Parsing

extension JSON {
    /// Parses one complete document, or nil when the text is not one.
    ///
    /// **Nil rather than a repair, and nil rather than a partial parse.** The
    /// caller's contract is that a malformed `settings.json` is refused and left
    /// alone: the owner's hand edit is worth more than the install, and half a
    /// document written back over a whole one is the failure this whole package
    /// exists to avoid.
    public static func parse(_ text: String) -> JSON? {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        guard let value = parser.value() else { return nil }
        parser.skipWhitespace()
        // Trailing content means the file is not the single document it claims to
        // be. Stopping at the first value would silently drop whatever followed.
        guard parser.isAtEnd else { return nil }
        return value
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        var isAtEnd: Bool { index >= scalars.count }

        mutating func skipWhitespace() {
            while index < scalars.count, scalars[index] == " " || scalars[index] == "\n"
                || scalars[index] == "\t" || scalars[index] == "\r" {
                index += 1
            }
        }

        mutating func value() -> JSON? {
            skipWhitespace()
            guard index < scalars.count else { return nil }
            switch scalars[index] {
            case "{": return object()
            case "[": return array()
            case "\"": return string().map(JSON.string)
            case "t": return literal("true") ? .bool(true) : nil
            case "f": return literal("false") ? .bool(false) : nil
            case "n": return literal("null") ? JSON.null : nil
            default: return number()
            }
        }

        mutating func literal(_ word: String) -> Bool {
            let expected = Array(word.unicodeScalars)
            guard index + expected.count <= scalars.count else { return false }
            for (offset, scalar) in expected.enumerated() where scalars[index + offset] != scalar {
                return false
            }
            index += expected.count
            return true
        }

        mutating func object() -> JSON? {
            index += 1  // {
            var result = JSONObject()
            skipWhitespace()
            if index < scalars.count, scalars[index] == "}" {
                index += 1
                return .object(result)
            }
            while true {
                skipWhitespace()
                guard index < scalars.count, scalars[index] == "\"", let key = string() else { return nil }
                skipWhitespace()
                guard index < scalars.count, scalars[index] == ":" else { return nil }
                index += 1
                guard let element = value() else { return nil }
                result[key] = element
                skipWhitespace()
                guard index < scalars.count else { return nil }
                if scalars[index] == "," { index += 1; continue }
                if scalars[index] == "}" { index += 1; return .object(result) }
                return nil
            }
        }

        mutating func array() -> JSON? {
            index += 1  // [
            var result: [JSON] = []
            skipWhitespace()
            if index < scalars.count, scalars[index] == "]" {
                index += 1
                return .array(result)
            }
            while true {
                guard let element = value() else { return nil }
                result.append(element)
                skipWhitespace()
                guard index < scalars.count else { return nil }
                if scalars[index] == "," { index += 1; continue }
                if scalars[index] == "]" { index += 1; return .array(result) }
                return nil
            }
        }

        mutating func string() -> String? {
            index += 1  // opening quote
            var result = String.UnicodeScalarView()
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar == "\"" {
                    index += 1
                    return String(result)
                }
                if scalar == "\\" {
                    index += 1
                    guard index < scalars.count else { return nil }
                    switch scalars[index] {
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "/": result.append("/")
                    case "b": result.append(Unicode.Scalar(8))
                    case "f": result.append(Unicode.Scalar(12))
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "t": result.append("\t")
                    case "u":
                        guard let escaped = unicodeEscape() else { return nil }
                        result.append(escaped)
                        continue
                    default: return nil
                    }
                    index += 1
                    continue
                }
                result.append(scalar)
                index += 1
            }
            return nil
        }

        /// `\uXXXX`, including the surrogate pair a scalar above the BMP arrives
        /// as. A lone high surrogate is refused rather than substituted, because a
        /// replacement character written back would be a silent edit to somebody's
        /// hook command.
        mutating func unicodeEscape() -> Unicode.Scalar? {
            guard let high = hex4() else { return nil }
            if high >= 0xD800, high <= 0xDBFF {
                guard index + 1 < scalars.count, scalars[index] == "\\", scalars[index + 1] == "u" else {
                    return nil
                }
                index += 2
                guard let low = hex4(), low >= 0xDC00, low <= 0xDFFF else { return nil }
                let combined = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
                return Unicode.Scalar(combined)
            }
            return Unicode.Scalar(high)
        }

        mutating func hex4() -> UInt32? {
            index += 1  // u
            guard index + 4 <= scalars.count else { return nil }
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let digit = scalars[index].hexDigitValue else { return nil }
                value = value * 16 + digit
                index += 1
            }
            return value
        }

        mutating func number() -> JSON? {
            let start = index
            while index < scalars.count, "0123456789+-.eE".unicodeScalars.contains(scalars[index]) {
                index += 1
            }
            guard start < index, let parsed = Double(String(String.UnicodeScalarView(scalars[start..<index])))
            else { return nil }
            return .number(parsed)
        }
    }
}

private extension Unicode.Scalar {
    var hexDigitValue: UInt32? {
        switch self {
        case "0"..."9": value - 48
        case "a"..."f": value - 87
        case "A"..."F": value - 55
        default: nil
        }
    }
}

// MARK: - Serializing

extension JSON {
    /// Renders the document with two-space indentation, which is what the file
    /// this edits already uses.
    public func serialized(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case .null: return "null"
        case let .bool(value): return value ? "true" : "false"
        case let .number(value):
            // Whole numbers render without the `.0` Double would otherwise give,
            // so a `1` in the owner's file does not come back as `1.0`.
            if value == value.rounded(), abs(value) < 1e15 {
                return String(Int64(value))
            }
            return String(value)
        case let .string(value): return Self.quoted(value)
        case let .array(elements):
            guard elements.isEmpty == false else { return "[]" }
            let body = elements.map { inner + $0.serialized(indent: indent + 1) }
            return "[\n" + body.joined(separator: ",\n") + "\n" + pad + "]"
        case let .object(object):
            guard object.isEmpty == false else { return "{}" }
            let body = object.keys.compactMap { key -> String? in
                guard let value = object[key] else { return nil }
                return inner + Self.quoted(key) + ": " + value.serialized(indent: indent + 1)
            }
            return "{\n" + body.joined(separator: ",\n") + "\n" + pad + "}"
        }
    }

    /// Escapes exactly what JSON requires and nothing else, so a path or a
    /// command in somebody's hook comes back looking the way they typed it.
    static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}
