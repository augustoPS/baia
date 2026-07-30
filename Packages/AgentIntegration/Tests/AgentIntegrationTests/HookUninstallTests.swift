import Foundation
import Testing

@testable import AgentIntegration

/// Taking baia's hooks back out, which is where an installer that is merely
/// careless becomes an installer that is destructive.
///
/// **The rule under all of this: unwind only as far as you created.** Baia's hook
/// objects go, and a container goes only when baia's departure is what emptied it.
/// A container the owner left empty stays empty, because an empty array somebody
/// wrote is a statement about what they want to happen.
@Suite struct HookUninstallTests {
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

    // MARK: The round trip

    /// **The test this suite exists for.** Install into a document shaped like the
    /// owner's real one and take it out again; what comes back must equal what
    /// went in, key order and all.
    @Test func installThenUninstallReturnsTheDocumentUnchanged() {
        let before = parse(HookInstallTests.foreign)
        guard let installed = HookDocument.install(Self.wanted, ownedBy: Self.script, into: before),
              let after = HookDocument.uninstall(ownedBy: Self.script, from: installed)
        else {
            Issue.record("did not round trip")
            return
        }
        #expect(installed != before, "the install did nothing, so the round trip proves nothing")
        #expect(after == before)
    }

    /// The same round trip through text, so a difference in serialization shows up
    /// as well as a difference in the model.
    @Test func theRoundTripHoldsAsText() {
        let original = HookInstallTests.foreign
        guard let installed = HookDocument.install(Self.wanted, ownedBy: Self.script, into: parse(original)),
              let after = HookDocument.uninstall(ownedBy: Self.script, from: installed)
        else {
            Issue.record("did not round trip")
            return
        }
        #expect(after.serialized() == original)
    }

    // MARK: What must survive

    /// An entry baia shared with a foreign hook keeps the entry and the foreign
    /// hook. Removing the entry because baia left it would delete somebody's
    /// secret scanner.
    @Test func aSharedEntryKeepsItsForeignHook() {
        let shared = """
        {
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [
                  {
                    "type": "command",
                    "command": "~/.claude/hooks/scan-secrets.sh"
                  },
                  {
                    "type": "command",
                    "command": "\(Self.script)"
                  }
                ]
              }
            ]
          }
        }
        """
        guard let after = HookDocument.uninstall(ownedBy: Self.script, from: parse(shared)) else {
            Issue.record("did not uninstall")
            return
        }
        #expect(HookInstallTests.baiaHookCount(in: after, event: "PreToolUse", script: Self.script) == 0)
        let entries = HookInstallTests.entries(of: "PreToolUse", in: after)
        guard case let .object(entry)? = entries.first, case let .array(hooks)? = entry["hooks"] else {
            Issue.record("the shared entry was removed")
            return
        }
        #expect(entry["matcher"] == .string("Bash"))
        #expect(hooks.count == 1)
    }

    /// **An empty array the owner wrote is left alone.** They may be about to fill
    /// it, or they may be disabling an event on purpose; either way it is not
    /// baia's to tidy.
    @Test func anEmptyContainerTheOwnerWroteIsNotRemoved() {
        let text = """
        {
          "hooks": {
            "PreToolUse": [],
            "Stop": []
          }
        }
        """
        guard let after = HookDocument.uninstall(ownedBy: Self.script, from: parse(text)) else {
            Issue.record("did not uninstall")
            return
        }
        #expect(after == parse(text))
    }

    /// And a `hooks` object the owner left empty stays, for the same reason.
    @Test func anEmptyHooksObjectTheOwnerWroteIsNotRemoved() {
        let text = "{\n  \"hooks\": {}\n}"
        #expect(HookDocument.uninstall(ownedBy: Self.script, from: parse(text)) == parse(text))
    }

    /// Everything outside `hooks` is untouched, in order.
    @Test func therestOfTheDocumentIsUntouched() {
        let before = parse(HookInstallTests.foreign)
        guard let installed = HookDocument.install(Self.wanted, ownedBy: Self.script, into: before),
              case let .object(after)? = HookDocument.uninstall(ownedBy: Self.script, from: installed),
              case let .object(original) = before
        else {
            Issue.record("did not round trip")
            return
        }
        #expect(after.keys == original.keys)
        #expect(after["permissions"] == original["permissions"])
        #expect(after["theme"] == original["theme"])
    }

    // MARK: What must go

    /// An entry baia created alone disappears entirely rather than being left as
    /// an entry with an empty hooks array.
    @Test func anEntryBaiaCreatedAloneDisappears() {
        guard let installed = HookDocument.install(Self.wanted, ownedBy: Self.script, into: parse("{}")),
              let after = HookDocument.uninstall(ownedBy: Self.script, from: installed),
              case let .object(root) = after
        else {
            Issue.record("did not round trip")
            return
        }
        // Baia created the whole `hooks` key here, so it goes with the hooks.
        #expect(root["hooks"] == nil)
    }

    /// An event array baia created inside a `hooks` object the owner already had
    /// goes, while the owner's own events stay.
    @Test func anEventBaiaCreatedGoesAndTheOwnersStay() {
        guard let installed = HookDocument.install(
            Self.wanted, ownedBy: Self.script, into: parse(HookInstallTests.foreign)
        ),
            case let .object(afterRoot)? = HookDocument.uninstall(ownedBy: Self.script, from: installed),
            case let .object(hooks)? = afterRoot["hooks"]
        else {
            Issue.record("did not round trip")
            return
        }
        #expect(hooks.keys == ["PreToolUse", "PostToolUse"])
    }

    // MARK: Nothing to do

    /// Uninstalling from a document with no baia hooks changes nothing and
    /// succeeds. A second `--uninstall` must not be an error.
    @Test func uninstallingTwiceIsUninstallingOnce() {
        let before = parse(HookInstallTests.foreign)
        guard let once = HookDocument.uninstall(ownedBy: Self.script, from: before),
              let twice = HookDocument.uninstall(ownedBy: Self.script, from: once)
        else {
            Issue.record("did not uninstall")
            return
        }
        #expect(once == before)
        #expect(twice == before)
    }

    @Test func aDocumentWithNoHooksKeyIsReturnedAsItIs() {
        let text = "{\n  \"theme\": \"dark\"\n}"
        #expect(HookDocument.uninstall(ownedBy: Self.script, from: parse(text)) == parse(text))
    }

    /// The same refusal install gives. A document too strange to install into is
    /// too strange to edit at all.
    @Test func aDocumentBaiaDoesNotUnderstandIsRefused() {
        #expect(HookDocument.uninstall(ownedBy: Self.script, from: .array([])) == nil)
        #expect(HookDocument.uninstall(ownedBy: Self.script, from: parse("{\n  \"hooks\": \"surprise\"\n}")) == nil)
        #expect(
            HookDocument.uninstall(
                ownedBy: Self.script,
                from: parse("{\n  \"hooks\": {\n    \"Stop\": \"surprise\"\n  }\n}")
            ) == nil
        )
    }

    /// A hook whose command merely mentions something similar is not baia's. The
    /// path is the whole test, so a neighbour named for baia stays put.
    @Test func aForeignHookThatMerelyMentionsBaiaIsNotOwned() {
        let text = """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "echo baia-agent-state is not installed"
                  }
                ]
              }
            ]
          }
        }
        """
        #expect(HookDocument.uninstall(ownedBy: Self.script, from: parse(text)) == parse(text))
    }
}
