import Foundation
import Testing

@testable import AgentIntegration

/// The parser and serializer, and the one property they exist for: a document
/// that goes in comes back out in the order it was written.
@Suite struct JSONTests {
    private func roundTrip(_ text: String) -> String? {
        JSON.parse(text)?.serialized()
    }

    // MARK: Order

    /// **The reason this type exists.** Every unordered model sorts or scrambles
    /// here, and the file this edits has twenty-two top-level keys in a deliberate
    /// non-alphabetical order.
    @Test func objectKeysKeepTheOrderTheyWereWrittenIn() {
        let text = """
        {
          "permissions": 1,
          "hooks": 2,
          "worktree": 3,
          "autoCompactEnabled": 4
        }
        """
        guard case let .object(object)? = JSON.parse(text) else {
            Issue.record("did not parse")
            return
        }
        #expect(object.keys == ["permissions", "hooks", "worktree", "autoCompactEnabled"])
        #expect(roundTrip(text) == text)
    }

    /// Assigning to an existing key replaces it where it stands. This is what
    /// makes a second install idempotent in the file and not only in the model.
    @Test func replacingAKeyDoesNotMoveIt() {
        var object = JSONObject([("a", .number(1)), ("b", .number(2)), ("c", .number(3))])
        object["b"] = .string("replaced")
        #expect(object.keys == ["a", "b", "c"])
    }

    @Test func removingAKeyDropsItFromTheOrder() {
        var object = JSONObject([("a", .number(1)), ("b", .number(2))])
        object["a"] = nil
        #expect(object.keys == ["b"])
        #expect(object["a"] == nil)
    }

    /// Two objects carrying the same pairs in different orders are not equal, so
    /// a round-trip assertion is about the document and not merely its facts.
    @Test func equalityIsOrderSensitive() {
        #expect(JSONObject([("a", .null), ("b", .null)]) != JSONObject([("b", .null), ("a", .null)]))
    }

    // MARK: Shapes

    @Test func everyScalarRoundTrips() {
        #expect(roundTrip("{\n  \"a\": null\n}") == "{\n  \"a\": null\n}")
        #expect(roundTrip("{\n  \"a\": true\n}") == "{\n  \"a\": true\n}")
        #expect(roundTrip("{\n  \"a\": false\n}") == "{\n  \"a\": false\n}")
    }

    /// A whole number comes back whole. `Double`'s description would turn the `1`
    /// somebody typed into `1.0` on every write.
    @Test func wholeNumbersDoNotGrowAFraction() {
        #expect(roundTrip("{\n  \"a\": 1\n}") == "{\n  \"a\": 1\n}")
        #expect(roundTrip("{\n  \"a\": -20\n}") == "{\n  \"a\": -20\n}")
        #expect(JSON.parse("{\"a\": 1.5}")?.serialized().contains("1.5") == true)
    }

    @Test func emptyContainersStayOnOneLine() {
        #expect(roundTrip("{\n  \"a\": [],\n  \"b\": {}\n}") == "{\n  \"a\": [],\n  \"b\": {}\n}")
    }

    @Test func nestingIndentsTwoSpacesPerLevel() {
        let text = """
        {
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Bash"
              }
            ]
          }
        }
        """
        #expect(roundTrip(text) == text)
    }

    // MARK: Strings

    /// A command in somebody's hook is full of quotes, backslashes and pipes, and
    /// every one has to come back the way they typed it.
    @Test func escapesSurviveARoundTrip() {
        let text = #"{"a": "say \"hi\" \\ then\tstop\nhere"}"#
        guard case let .object(object)? = JSON.parse(text), case let .string(value)? = object["a"] else {
            Issue.record("did not parse")
            return
        }
        #expect(value == "say \"hi\" \\ then\tstop\nhere")
        #expect(JSON.parse(JSON.string(value).serialized())  == .string(value))
    }

    @Test func aUnicodeEscapeDecodes() {
        #expect(JSON.parse(#"{"a": "é"}"#) == .object(JSONObject([("a", .string("é"))])))
    }

    /// A scalar above the BMP arrives as a surrogate pair and must be rejoined.
    @Test func aSurrogatePairDecodesToOneScalar() {
        #expect(JSON.parse(#"{"a": "😀"}"#) == .object(JSONObject([("a", .string("😀"))])))
    }

    /// A lone high surrogate is refused rather than substituted. A replacement
    /// character written back would be a silent edit to somebody's hook command.
    @Test func aLoneSurrogateIsRefused() {
        #expect(JSON.parse(#"{"a": "\ud83d"}"#) == nil)
    }

    /// A raw control byte is escaped on the way out, or the file it lands in is
    /// no longer JSON.
    @Test func controlBytesAreEscapedOnTheWayOut() {
        #expect(JSON.string("a\u{01}b").serialized() == "\"a\\u0001b\"")
    }

    // MARK: Refusing

    /// **Nil, never a repair and never a partial parse.** The caller's contract is
    /// that a malformed settings.json is left alone, and half a document written
    /// back over a whole one is the failure this package exists to avoid.
    @Test func malformedDocumentsAreRefused() {
        #expect(JSON.parse("") == nil)
        #expect(JSON.parse("{") == nil)
        #expect(JSON.parse("{\"a\": }") == nil)
        #expect(JSON.parse("{\"a\": 1,}") == nil)
        #expect(JSON.parse("{\"a\" 1}") == nil)
        #expect(JSON.parse("[1, 2") == nil)
        #expect(JSON.parse("nul") == nil)
    }

    /// Two documents back to back are not one document. Stopping at the first
    /// would silently drop whatever followed it.
    @Test func trailingContentIsRefused() {
        #expect(JSON.parse("{} {}") == nil)
        #expect(JSON.parse("{}x") == nil)
    }

    @Test func trailingWhitespaceIsFine() {
        #expect(JSON.parse("{}  \n\t ") == .object(JSONObject()))
    }

    // MARK: The real file

    /// **The test that decides whether this type is fit for its job.** Parses the
    /// owner's actual `~/.claude/settings.json` when it is there, and asserts that
    /// serializing it and parsing that again yields an identical document, keys in
    /// the same order at every level.
    ///
    /// Skipped rather than failed where the file is absent, because this suite has
    /// to pass on a machine that has never run Claude Code. Read only: nothing here
    /// writes anywhere near it.
    @Test func theOwnersRealSettingsFileSurvivesARoundTrip() throws {
        let path = ("~/.claude/settings.json" as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        guard let parsed = JSON.parse(text) else {
            Issue.record("could not parse the real settings.json, which the installer must never rewrite")
            return
        }
        guard let reparsed = JSON.parse(parsed.serialized()) else {
            Issue.record("serializing the real settings.json produced something unparseable")
            return
        }
        #expect(parsed == reparsed)

        // And the top-level order specifically, since that is the property the
        // whole type exists for and equality above would also pass on a document
        // with one key.
        if case let .object(before) = parsed, case let .object(after) = reparsed {
            #expect(before.keys == after.keys)
            #expect(before.keys.count > 1)
        }
    }
}
