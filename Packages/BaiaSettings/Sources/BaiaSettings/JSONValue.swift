import Foundation

/// The JSON shapes a hand-edited config file can hold, parsed by hand.
///
/// `Codable` is rejected because a synthesized `Decodable` fails the whole object
/// on the first bad value, and per-field fallback is the entire point of this
/// file format: one typo must not discard sixteen good settings.
///
/// `JSONSerialization` is rejected for a different reason. Its only entry point
/// is `throws`, and production code in this project has no `try` in it: a
/// fallible read answers nil instead. Parsing by hand keeps the failure a single
/// nil at the top of ``SettingsDecoder/decode(_:)`` rather than an `NSError`
/// describing a byte offset that nothing would ever display.
enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {
    /// Parses `data` as one complete JSON document, or nil when it is not one.
    static func parse(_ data: Data) -> JSONValue? {
        // Invalid UTF-8 is refused up front rather than at the byte that breaks.
        // A config file is small and half of one is not useful, and it lets the
        // parser below treat its input as valid UTF-8 and assemble strings
        // without a second validity check per escape.
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var parser = Parser(bytes: Array(text.utf8))
        guard let value = parser.value(depth: 0) else { return nil }
        parser.skipWhitespace()

        // Two documents back to back, or a stray brace after the object, mean the
        // file is not the single object it claims to be. Stopping at the first
        // value instead would apply half a config and report nothing at all.
        guard parser.isAtEnd else { return nil }
        return value
    }

    /// The four bytes JSON counts as whitespace. Shared with ``SettingsDecoder``,
    /// which decides whether a file is blank before it decides whether it is
    /// broken.
    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// The value as JSON text, round-tripping through ``parse(_:)``.
    ///
    /// Object keys come out sorted, which is stable but not what the config file
    /// wants. ``SettingsWriter`` serializes the top-level document itself so it
    /// can impose the reading order the owner learned the file by; this is the
    /// fallback for nested values, where sorted is the only stable choice on
    /// offer, since `object` is a dictionary and carries no order of its own.
    func serialized(indent: Int = 0) -> String {
        switch self {
        case .null:
            return "null"
        case let .bool(value):
            return value ? "true" : "false"
        case let .number(value):
            return Self.numberText(value)
        case let .string(value):
            return Self.quoted(value)
        case let .array(values):
            // Inline. The one array in this document is `projectRoots`, a short
            // list of paths, and a block form would spend four lines on it.
            return "[" + values.map { $0.serialized(indent: indent) }.joined(separator: ", ") + "]"
        case let .object(members):
            guard !members.isEmpty else { return "{}" }
            let inner = String(repeating: "  ", count: indent + 1)
            let body = members.keys.sorted().map { key in
                inner + Self.quoted(key) + ": " + members[key]!.serialized(indent: indent + 1)
            }
            return "{\n" + body.joined(separator: ",\n")
                + "\n" + String(repeating: "  ", count: indent) + "}"
        }
    }

    /// A `Double` as the shortest text that reparses to the same value, with whole
    /// numbers written without a fractional part.
    ///
    /// `"\(value)"` is already the shortest round-tripping form Swift prints, so
    /// the only work is the integral case, which that spelling renders as `8.0`.
    /// The default file says `8`, and the file is where the owner learns the
    /// spellings, so writing `8.0` back would be a silent edit to a document
    /// nobody asked to change.
    ///
    /// The magnitude guard keeps `Int64(value)` from trapping on a value no
    /// setting can hold but a hand-edited file could. A non-finite value cannot
    /// be written as JSON at all, and `0` is the one value every numeric setting
    /// either accepts or clamps, so it degrades rather than emitting `nan` for
    /// the decoder to reject.
    static func numberText(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return "\(value)"
    }

    /// A string as a quoted JSON scalar.
    ///
    /// Escapes the five sequences the parser understands plus the C0 range, which
    /// JSON forbids raw. Anything above that is emitted as itself: the file is
    /// UTF-8, and escaping non-ASCII would turn a theme name into `\u` noise in
    /// the document the owner edits by hand.
    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// A cursor over the document's UTF-8 bytes.
    ///
    /// Bytes rather than `Character`s: every structural token in JSON is ASCII, so
    /// a byte comparison cannot be confused by a multi byte scalar inside a
    /// string, and the index arithmetic stays a plain integer step.
    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        /// Nesting deeper than this is refused. The value parser recurses, so a
        /// file holding ten thousand open brackets would exhaust the stack, and a
        /// crash on launch is a far worse answer than a config that fell back to
        /// its defaults. Real configs nest one level, inside `projectRoots`.
        private static let maxDepth = 32

        var isAtEnd: Bool { index == bytes.count }

        mutating func skipWhitespace() {
            while index < bytes.count, JSONValue.isWhitespace(bytes[index]) {
                index += 1
            }
        }

        mutating func value(depth: Int) -> JSONValue? {
            guard depth <= Self.maxDepth else { return nil }
            skipWhitespace()
            guard let byte = peek() else { return nil }
            switch byte {
            case UInt8(ascii: "{"): return object(depth: depth)
            case UInt8(ascii: "["): return array(depth: depth)
            case UInt8(ascii: "\""): return string().map(JSONValue.string)
            case UInt8(ascii: "t"): return literal("true") ? .bool(true) : nil
            case UInt8(ascii: "f"): return literal("false") ? .bool(false) : nil
            case UInt8(ascii: "n"): return literal("null") ? .null : nil
            default: return number().map(JSONValue.number)
            }
        }

        private mutating func object(depth: Int) -> JSONValue? {
            index += 1
            var fields: [String: JSONValue] = [:]
            skipWhitespace()
            if match("}") { return .object(fields) }
            while true {
                skipWhitespace()
                guard let key = string() else { return nil }
                skipWhitespace()
                guard match(":"), let value = value(depth: depth + 1) else { return nil }

                // A repeated key takes its last value, which is what every JSON
                // reader the owner's editor might use does. Refusing the document
                // over a duplicate would discard every other setting for a paste
                // that is both easy to make and easy to see once pointed at.
                fields[key] = value

                skipWhitespace()
                if match(",") { continue }
                guard match("}") else { return nil }
                return .object(fields)
            }
        }

        private mutating func array(depth: Int) -> JSONValue? {
            index += 1
            var items: [JSONValue] = []
            skipWhitespace()
            if match("]") { return .array(items) }
            while true {
                guard let value = value(depth: depth + 1) else { return nil }
                items.append(value)
                skipWhitespace()
                if match(",") { continue }
                guard match("]") else { return nil }
                return .array(items)
            }
        }

        private mutating func string() -> String? {
            guard match("\"") else { return nil }
            var out: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == UInt8(ascii: "\"") {
                    return String(decoding: out, as: UTF8.self)
                }
                guard byte == UInt8(ascii: "\\") else {
                    // A raw control byte inside a string is invalid JSON and is
                    // taken anyway. A literal tab pasted into a theme name would
                    // otherwise discard the whole file, which is the outcome the
                    // per-field fallback exists to prevent.
                    out.append(byte)
                    continue
                }
                guard let escaped = escape() else { return nil }
                out.append(contentsOf: escaped)
            }

            // The closing quote never arrived, so the rest of the file is inside
            // a string. Returning the bytes collected so far would turn a truncated
            // write into a plausible looking value.
            return nil
        }

        /// The bytes an escape sequence stands for, or nil for a sequence JSON
        /// does not define. An unknown escape is refused rather than passed
        /// through: `\x` in a path is a typo, and dropping the backslash would
        /// invent a path that could exist.
        private mutating func escape() -> [UInt8]? {
            guard let byte = peek() else { return nil }
            index += 1
            switch byte {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): return [byte]
            case UInt8(ascii: "b"): return [0x08]
            case UInt8(ascii: "f"): return [0x0C]
            case UInt8(ascii: "n"): return [0x0A]
            case UInt8(ascii: "r"): return [0x0D]
            case UInt8(ascii: "t"): return [0x09]
            case UInt8(ascii: "u"): return unicodeEscape()
            default: return nil
            }
        }

        /// Decodes `\uXXXX`, pairing a high surrogate with the `\uXXXX` after it.
        ///
        /// A lone surrogate is refused rather than replaced. `Unicode.Scalar` has
        /// no value for one, and substituting U+FFFD would put a replacement
        /// character inside a font name or a project path, which is a value that
        /// looks almost right and matches nothing on disk.
        private mutating func unicodeEscape() -> [UInt8]? {
            guard let first = hexQuad() else { return nil }
            if let scalar = Unicode.Scalar(first) {
                return Array(String(scalar).utf8)
            }
            guard (0xD800 ... 0xDBFF).contains(first),
                  match("\\"), match("u"),
                  let second = hexQuad(),
                  (0xDC00 ... 0xDFFF).contains(second)
            else { return nil }
            let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            guard let scalar = Unicode.Scalar(combined) else { return nil }
            return Array(String(scalar).utf8)
        }

        private mutating func hexQuad() -> UInt32? {
            var value: UInt32 = 0
            for _ in 0 ..< 4 {
                guard let byte = peek(), let digit = Self.hexDigit(byte) else { return nil }
                value = value << 4 | digit
                index += 1
            }
            return value
        }

        /// Numbers are handed to `Double(String)` rather than accumulated digit by
        /// digit, so the sign, the fraction, and the exponent all behave the way
        /// the rest of Swift does. An exponent too large for a `Double` arrives as
        /// infinity rather than as a parse failure, which is why
        /// ``SettingsDecoder`` rejects a non finite number per field.
        private mutating func number() -> Double? {
            let start = index
            while let byte = peek(), Self.isNumberByte(byte) { index += 1 }
            guard start < index else { return nil }
            return Double(String(decoding: bytes[start ..< index], as: UTF8.self))
        }

        private mutating func literal(_ text: String) -> Bool {
            let expected = Array(text.utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index ..< index + expected.count]) == expected
            else { return false }
            index += expected.count
            return true
        }

        private func peek() -> UInt8? {
            index < bytes.count ? bytes[index] : nil
        }

        private mutating func match(_ character: Unicode.Scalar) -> Bool {
            guard peek() == UInt8(ascii: character) else { return false }
            index += 1
            return true
        }

        private static func isNumberByte(_ byte: UInt8) -> Bool {
            if (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) { return true }
            return byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: "+")
                || byte == UInt8(ascii: ".")
                || byte == UInt8(ascii: "e")
                || byte == UInt8(ascii: "E")
        }

        private static func hexDigit(_ byte: UInt8) -> UInt32? {
            switch byte {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                return UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a") ... UInt8(ascii: "f"):
                return UInt32(byte - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A") ... UInt8(ascii: "F"):
                return UInt32(byte - UInt8(ascii: "A")) + 10
            default:
                return nil
            }
        }
    }
}
