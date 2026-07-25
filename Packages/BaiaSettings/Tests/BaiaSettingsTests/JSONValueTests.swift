import Foundation
import Testing

@testable import BaiaSettings

@Suite struct JSONValueTests {
    private func parse(_ text: String) -> JSONValue? {
        JSONValue.parse(Data(text.utf8))
    }

    @Test func parsesEveryScalarShapeInOneObject() {
        let parsed = parse(#"{"a": "x", "b": -1.5e2, "c": true, "d": false, "e": null}"#)
        #expect(parsed == .object([
            "a": .string("x"),
            "b": .number(-150),
            "c": .bool(true),
            "d": .bool(false),
            "e": .null,
        ]))
    }

    @Test func parsesNestedArraysAndObjects() {
        let parsed = parse(#"{"roots": ["~/a", "/b"], "nested": {"k": [1]}}"#)
        #expect(parsed == .object([
            "roots": .array([.string("~/a"), .string("/b")]),
            "nested": .object(["k": .array([.number(1)])]),
        ]))
    }

    @Test func parsesTheEmptyObjectAndTheEmptyArray() {
        #expect(parse("{}") == .object([:]))
        #expect(parse("[]") == .array([]))
    }

    @Test func skipsWhitespaceAroundEveryToken() {
        // A hand-edited file is indented and ends with a newline, so a parser that
        // only tolerated whitespace between values would reject every real config.
        #expect(parse("\n\t{ \"a\" : [ 1 , 2 ] }\n ") == .object(["a": .array([.number(1), .number(2)])]))
    }

    @Test func rejectsTrailingContentAfterTheDocument() {
        // The document is complete at the closing brace, so a parser that stopped
        // there would accept both of these and apply the first half of a file the
        // owner is midway through editing.
        #expect(parse("{} {}") == nil)
        #expect(parse(#"{"a": 1}}"#) == nil)
    }

    @Test func rejectsATrailingComma() {
        #expect(parse(#"{"a": 1,}"#) == nil)
        #expect(parse("[1,]") == nil)
    }

    @Test func rejectsAnUnterminatedString() {
        // A truncated write ends mid string. Returning the bytes collected so far
        // would turn it into a plausible looking value for a real key.
        #expect(parse(#"{"a": "unfinished"#) == nil)
    }

    @Test func rejectsAMissingColonAndAMissingValue() {
        #expect(parse(#"{"a" 1}"#) == nil)
        #expect(parse(#"{"a": }"#) == nil)
    }

    @Test func rejectsABareKeyWithoutQuotes() {
        // The shape a ghostty config has. Someone editing the wrong file must not
        // get a half applied result out of it.
        #expect(parse("{a: 1}") == nil)
    }

    @Test func rejectsInvalidUTF8() {
        // 0xFF cannot begin a UTF-8 sequence. `String(data:encoding:)` is what
        // catches it, before any byte is looked at as a token.
        #expect(JSONValue.parse(Data([0x7B, 0xFF, 0x7D])) == nil)
    }

    @Test func takesTheLastValueOfADuplicateKey() {
        // The alternative is refusing the document, which would discard every
        // other setting over a paste that is easy to make.
        #expect(parse(#"{"a": 1, "a": 2}"#) == .object(["a": .number(2)]))
    }

    @Test func decodesTheEscapeSequencesJSONDefines() {
        let parsed = parse(#"{"a": "q\"b\\s\/n\bf\f\nl\r\tt"}"#)
        #expect(parsed == .object(["a": .string("q\"b\\s/n\u{08}f\u{0C}\nl\r\tt")]))
    }

    @Test func decodesAFourDigitEscapeAndASurrogatePair() {
        // A path with an accented component arrives as é from an editor that
        // escapes non-ASCII, and an emoji arrives as a surrogate pair. Handling only
        // the first would truncate a real project path.
        let accented = #"{"a": "caf\u00e9"}"#
        let pair = #"{"a": "\ud83d\ude80"}"#
        #expect(parse(accented) == .object(["a": .string("café")]))
        #expect(parse(pair) == .object(["a": .string("🚀")]))
    }

    @Test func rejectsALoneSurrogateAndAnUnknownEscape() {
        // Substituting U+FFFD for the surrogate would put a replacement character
        // inside a font name or a path, a value that looks almost right and matches
        // nothing on disk.
        #expect(parse(#"{"a": "\ud83d"}"#) == nil)
        #expect(parse(#"{"a": "\udc00\ud83d"}"#) == nil)
        #expect(parse(#"{"a": "\x41"}"#) == nil)
        #expect(parse(#"{"a": "\u00g1"}"#) == nil)
    }

    @Test func keepsARawControlByteInsideAString() {
        // Invalid JSON, taken anyway. A literal tab pasted into a theme name would
        // otherwise discard sixteen good settings along with it.
        #expect(parse("{\"a\": \"x\ty\"}") == .object(["a": .string("x\ty")]))
    }

    @Test func rejectsAMalformedNumber() {
        #expect(parse(#"{"a": --1}"#) == nil)
        #expect(parse(#"{"a": 1.2.3}"#) == nil)
        #expect(parse(#"{"a": .}"#) == nil)
    }

    @Test func anExponentTooLargeForADoubleParsesAsInfinity() {
        // This is why the decoder checks `isFinite` per field rather than trusting
        // that a number which parsed is a number it can use: infinity satisfies
        // every range check written with `min` and `max`.
        #expect(parse(#"{"a": 1e999}"#) == .object(["a": .number(.infinity)]))
    }

    @Test func rejectsTheBareNaNAndInfinityTokensJSONDoesNotDefine() {
        #expect(parse(#"{"a": NaN}"#) == nil)
        #expect(parse(#"{"a": Infinity}"#) == nil)
    }

    @Test func rejectsATruncatedLiteral() {
        #expect(parse(#"{"a": tru}"#) == nil)
        #expect(parse(#"{"a": nul}"#) == nil)
    }

    @Test func acceptsTheNestingARealConfigUses() {
        // The pair with the test below is what pins the depth limit: this one fails
        // if the limit is ever set low enough to reach a real file, and that one
        // fails if the limit goes away.
        #expect(parse(#"{"projectRoots": ["~/Projects"]}"#) != nil)
    }

    @Test func refusesAFileNestedDeeplyEnoughToExhaustTheStack() {
        // The value parser recurses, so without the limit this is a crash on launch
        // rather than a config that fell back to its defaults. The exact boundary is
        // not the contract; failing instead of dying is.
        let deep = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        #expect(parse(deep) == nil)
    }
}
