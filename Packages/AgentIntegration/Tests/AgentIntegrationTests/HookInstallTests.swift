import Foundation
import Testing

@testable import AgentIntegration

/// Installing baia's hooks into somebody else's `settings.json`.
///
/// **The foreign-hook cases come first on purpose.** The happy path is easy and
/// the risk is entirely in what else lives in that file: measured on this machine
/// 2026-07-30, seven hook events with two `PreToolUse` entries, one matching
/// `Bash`, and hook objects carrying `async` and `statusMessage` keys baia knows
/// nothing about.
@Suite struct HookInstallTests {
    static let script = "/Users/x/.claude/hooks/baia-agent-state.sh"

    static var wanted: [HookEntry] {
        [
            HookEntry(event: "PreToolUse", matcher: nil, command: script),
            HookEntry(event: "Stop", matcher: nil, command: script),
        ]
    }

    private func parse(_ text: String) -> JSON {
        guard let value = JSON.parse(text) else {
            Issue.record("fixture did not parse")
            return .null
        }
        return value
    }

    private func install(into text: String, _ entries: [HookEntry]? = nil) -> JSON? {
        HookDocument.install(entries ?? Self.wanted, ownedBy: Self.script, into: parse(text))
    }

    /// Everything not baia's, spelled the way the owner's file spells it.
    static let foreign = """
    {
      "permissions": {
        "allow": [
          "Bash(git:*)"
        ]
      },
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              {
                "type": "command",
                "command": "~/.claude/hooks/scan-secrets.sh"
              }
            ]
          }
        ],
        "PostToolUse": [
          {
            "matcher": "Edit|Write",
            "hooks": [
              {
                "type": "command",
                "command": "prettier",
                "async": true
              }
            ]
          }
        ]
      },
      "theme": "dark"
    }
    """

    // MARK: What must survive

    /// Nothing outside `hooks` is touched, and the order of the whole document
    /// holds. This is the assertion that a rebuild-from-model would fail.
    @Test func everythingOutsideHooksIsUntouchedAndInOrder() {
        guard case let .object(before)? = JSON.parse(Self.foreign),
              case let .object(after)? = install(into: Self.foreign)
        else {
            Issue.record("did not install")
            return
        }
        #expect(after.keys == before.keys)
        #expect(after["permissions"] == before["permissions"])
        #expect(after["theme"] == before["theme"])
    }

    /// A foreign hook in an event baia also wants keeps its place and its keys,
    /// including the ones baia has never heard of.
    @Test func aForeignHookInASharedEventSurvivesWithItsUnknownKeys() {
        guard let result = install(into: Self.foreign) else {
            Issue.record("did not install")
            return
        }
        let entries = Self.entries(of: "PreToolUse", in: result)
        guard let first = entries.first, case let .object(entry) = first else {
            Issue.record("PreToolUse lost its first entry")
            return
        }
        #expect(entry["matcher"] == .string("Bash"))
        guard case let .array(hooks)? = entry["hooks"], case let .object(hook) = hooks[0] else {
            Issue.record("the Bash entry lost its hook")
            return
        }
        #expect(hook["command"] == .string("~/.claude/hooks/scan-secrets.sh"))
        #expect(hooks.count == 1, "baia joined an entry it does not own")
    }

    /// An event baia never touches is left exactly as it was, keys and all.
    @Test func anEventBaiaDoesNotWantIsUntouched() {
        guard case let .object(before)? = JSON.parse(Self.foreign),
              case let .object(beforeHooks)? = before["hooks"],
              let result = install(into: Self.foreign),
              case let .object(after) = result,
              case let .object(afterHooks)? = after["hooks"]
        else {
            Issue.record("did not install")
            return
        }
        #expect(afterHooks["PostToolUse"] == beforeHooks["PostToolUse"])
    }

    /// The event key order inside `hooks` holds, and baia's new event is appended
    /// rather than inserted, so the owner's file reads as it did with an addition
    /// at the end.
    @Test func newEventsAreAppendedAndExistingOrderHolds() {
        guard let result = install(into: Self.foreign), case let .object(after) = result,
              case let .object(hooks)? = after["hooks"]
        else {
            Issue.record("did not install")
            return
        }
        #expect(hooks.keys == ["PreToolUse", "PostToolUse", "Stop"])
    }

    // MARK: What is added

    @Test func baiaIsAddedToAnEventThatAlreadyExists() {
        guard let result = install(into: Self.foreign) else {
            Issue.record("did not install")
            return
        }
        #expect(Self.baiaHookCount(in: result, event: "PreToolUse", script: Self.script) == 1)
    }

    @Test func baiaCreatesAnEventThatDoesNotExist() {
        guard let result = install(into: Self.foreign) else {
            Issue.record("did not install")
            return
        }
        #expect(Self.baiaHookCount(in: result, event: "Stop", script: Self.script) == 1)
    }

    /// Baia's own hook object is a `command` hook and says so, which is the shape
    /// Claude Code requires and the shape ownership is read from.
    @Test func baiaWritesATypedCommandHook() {
        guard let result = install(into: Self.foreign) else {
            Issue.record("did not install")
            return
        }
        let entries = Self.entries(of: "Stop", in: result)
        guard case let .object(entry)? = entries.last, case let .array(hooks)? = entry["hooks"],
              case let .object(hook) = hooks[0]
        else {
            Issue.record("no hook written")
            return
        }
        #expect(hook["type"] == .string("command"))
        #expect(hook["command"] == .string(Self.script))
    }

    /// An entry baia creates carries no `matcher` when it wanted none, rather than
    /// an empty string, which Claude Code would read as a pattern.
    @Test func anEntryWithNoMatcherOmitsTheKey() {
        guard let result = install(into: Self.foreign) else {
            Issue.record("did not install")
            return
        }
        guard case let .object(entry)? = Self.entries(of: "Stop", in: result).last else {
            Issue.record("no entry")
            return
        }
        #expect(entry["matcher"] == nil)
        #expect(entry.keys == ["hooks"])
    }

    @Test func aMatcherIsWrittenWhenOneIsWanted() {
        let entries = [HookEntry(event: "PreToolUse", matcher: "^AskUserQuestion$", command: Self.script)]
        guard let result = install(into: Self.foreign, entries) else {
            Issue.record("did not install")
            return
        }
        let found = Self.entries(of: "PreToolUse", in: result).compactMap { value -> JSONObject? in
            guard case let .object(entry) = value else { return nil }
            return entry
        }
        #expect(found.contains { $0["matcher"] == .string("^AskUserQuestion$") })
    }

    // MARK: Idempotency

    /// **Installing twice leaves one hook per event, not two.** This is also how
    /// an upgrade works: the second write replaces baia's object rather than
    /// appending beside it.
    @Test func installingTwiceIsInstallingOnce() {
        guard let once = install(into: Self.foreign),
              let twice = HookDocument.install(Self.wanted, ownedBy: Self.script, into: once)
        else {
            Issue.record("did not install")
            return
        }
        #expect(once == twice)
        #expect(Self.baiaHookCount(in: twice, event: "PreToolUse", script: Self.script) == 1)
    }

    /// An upgrade replaces baia's object **in place**, so the owner's diff is one
    /// line rather than a hook that jumped to the end of the array.
    @Test func anUpgradeReplacesInPlaceRatherThanAppending() {
        let old = HookEntry(event: "PreToolUse", matcher: nil, command: Self.script + " --v1")
        guard let first = install(into: Self.foreign, [old]) else {
            Issue.record("did not install")
            return
        }
        // Something foreign lands after baia's entry, so a move to the end shows.
        guard let second = HookDocument.install(Self.wanted, ownedBy: Self.script, into: first),
              case let .object(after) = second, case let .object(hooks)? = after["hooks"],
              case let .array(events)? = hooks["PreToolUse"]
        else {
            Issue.record("did not reinstall")
            return
        }
        #expect(Self.baiaHookCount(in: second, event: "PreToolUse", script: Self.script) == 1)
        // The Bash entry the owner wrote is still first.
        guard case let .object(firstEntry) = events[0] else {
            Issue.record("lost the first entry")
            return
        }
        #expect(firstEntry["matcher"] == .string("Bash"))
    }

    // MARK: Documents that are barely there

    @Test func aDocumentWithNoHooksKeyGainsOne() {
        guard let result = install(into: "{\n  \"theme\": \"dark\"\n}"),
              case let .object(after) = result
        else {
            Issue.record("did not install")
            return
        }
        #expect(after.keys == ["theme", "hooks"])
        #expect(Self.baiaHookCount(in: result, event: "Stop", script: Self.script) == 1)
    }

    @Test func anEmptyDocumentGainsEverything() {
        guard let result = install(into: "{}") else {
            Issue.record("did not install")
            return
        }
        #expect(Self.baiaHookCount(in: result, event: "PreToolUse", script: Self.script) == 1)
        #expect(Self.baiaHookCount(in: result, event: "Stop", script: Self.script) == 1)
    }

    /// **Refused, not repaired.** A document that is not an object, or a `hooks`
    /// key that is not one, is somebody's file in a shape baia does not
    /// understand, and guessing at it is how an installer eats a config.
    @Test func aDocumentBaiaDoesNotUnderstandIsRefused() {
        #expect(HookDocument.install(Self.wanted, ownedBy: Self.script, into: .array([])) == nil)
        #expect(HookDocument.install(Self.wanted, ownedBy: Self.script, into: .string("no")) == nil)
        #expect(install(into: "{\n  \"hooks\": \"surprise\"\n}") == nil)
        #expect(install(into: "{\n  \"hooks\": {\n    \"Stop\": \"surprise\"\n  }\n}") == nil)
    }

    // MARK: Helpers

    static func entries(of event: String, in document: JSON) -> [JSON] {
        guard case let .object(root) = document, case let .object(hooks)? = root["hooks"],
              case let .array(entries)? = hooks[event]
        else { return [] }
        return entries
    }

    static func baiaHookCount(in document: JSON, event: String, script: String) -> Int {
        entries(of: event, in: document).reduce(0) { total, entry in
            guard case let .object(entry) = entry, case let .array(hooks)? = entry["hooks"] else {
                return total
            }
            return total + hooks.filter { hook in
                guard case let .object(hook) = hook, case let .string(command)? = hook["command"] else {
                    return false
                }
                return command.contains(script)
            }.count
        }
    }
}
