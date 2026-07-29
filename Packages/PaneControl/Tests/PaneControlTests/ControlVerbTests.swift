import Testing

@testable import PaneControl

@Suite struct ControlVerbTests {
    /// The raw values are the wire, not an implementation detail of the enum. A
    /// case rename that changed one would be a protocol break that compiled
    /// everywhere and failed only against a helper from another build, so the
    /// spellings are pinned against a literal table.
    ///
    /// The table is walked from `allCases`, so a verb added without a row fails
    /// here rather than shipping with whatever spelling the case name happened
    /// to produce.
    @Test func theWireSpellingOfEveryVerbIsPinned() {
        let spelling: [ControlVerb: String] = [
            .split: "split",
            .close: "close",
            .focus: "focus",
            .zoom: "zoom",
            .resize: "resize",
            .equalize: "equalize",
            .whoami: "whoami",
            .list: "list",
            .publish: "publish",
            .connect: "connect",
            .peers: "peers",
            .send: "send",
            .recv: "recv",
            .revoke: "revoke",
            .subscribe: "subscribe",
            .run: "run",
        ]
        for verb in ControlVerb.allCases {
            guard let expected = spelling[verb] else {
                Issue.record("no pinned wire spelling for \(verb)")
                continue
            }
            #expect(verb.rawValue == expected)
        }
        #expect(ControlVerb.allCases.isEmpty == false)
        #expect(spelling.count == ControlVerb.allCases.count)
    }

    /// `run` is declared in v1 even though it does nothing in v1, and the reason
    /// is the settings key: if the case were simply absent, both values of
    /// `controlAllowRun` would answer `unknownVerb` and a passing test would
    /// prove nothing about a consumer.
    @Test func runIsDeclaredSoItsSettingKeyHasSomethingToGate() {
        #expect(ControlVerb.allCases.contains(.run))
        #expect(ControlVerb(rawValue: "run") == .run)
    }

    /// Every verb's scope, pinned. This is the small version of the
    /// authorization matrix: a verb added without a decided scope fails to
    /// compile in ``ControlVerb/scope`` first, because that switch has no
    /// `default:`, and fails here second.
    @Test func everyVerbHasADecidedScope() {
        let scopes: [ControlVerb: ControlScope] = [
            .split: .selfOnly,
            .close: .selfOnly,
            .focus: .selfOnly,
            .zoom: .selfOnly,
            .resize: .selfOnly,
            .equalize: .selfOnly,
            .whoami: .selfOnly,
            .publish: .selfOnly,
            .connect: .selfOnly,
            .peers: .selfOnly,
            .recv: .selfOnly,
            .subscribe: .selfOnly,
            .list: .scopedRead,
            .send: .peerEdge,
            .revoke: .peerEdge,
            .run: .descendant,
        ]
        for verb in ControlVerb.allCases {
            guard let expected = scopes[verb] else {
                Issue.record("no decided scope for \(verb)")
                continue
            }
            #expect(verb.scope == expected)
        }
    }

    /// No v1 verb reaches another pane's layout. Stated as its own assertion
    /// rather than left implicit in the table above, because "every v1 layout
    /// verb acts on the calling pane and takes no target" is the sentence the
    /// whole v1 threat argument rests on.
    @Test func noLayoutVerbCanNameAnotherPane() {
        for verb in [ControlVerb.split, .close, .focus, .zoom, .resize, .equalize] {
            #expect(verb.scope == .selfOnly)
        }
    }

    /// `split` hands a pane a shell it could already have spawned. `run` hands
    /// it execution in another pane's context. They do not share a switch, and
    /// this is the assertion that says so.
    @Test func onlyRunIsGatedOnTheRunKey() {
        for verb in ControlVerb.allCases {
            #expect(verb.settingGate == (verb == .run ? .allowRun : .channel))
        }
    }

    @Test func subscribeIsSelfOnlyAndSpelledForTheWire() {
        #expect(ControlVerb.subscribe.rawValue == "subscribe")
        #expect(ControlVerb.subscribe.scope == .selfOnly)
        #expect(ControlVerb.subscribe.settingGate == .channel)
    }
}
