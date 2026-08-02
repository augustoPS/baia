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
            .cwd: "cwd",
            .whoami: "whoami",
            .list: "list",
            .publish: "publish",
            .connect: "connect",
            .peers: "peers",
            .send: "send",
            .recv: "recv",
            .revoke: "revoke",
            .subscribe: "subscribe",
            .report: "report",
            .read: "read",
            // Hyphenated because a verb is one string on the wire and two tokens
            // at the prompt. The CLI rewrites `baia layout export` into this, so a
            // change here is a change to what a Makefile written against an older
            // baia sends.
            .layoutExport: "layout-export",
            .layoutApply: "layout-apply",
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
            .cwd: .selfOnly,
            .whoami: .selfOnly,
            .publish: .selfOnly,
            .connect: .selfOnly,
            .peers: .selfOnly,
            .recv: .selfOnly,
            .subscribe: .selfOnly,
            .report: .selfOnly,
            // Creates a window and reaches no pane that already exists, which is
            // what keeps it out of the cross-pane mutation v1 defers.
            .layoutApply: .selfOnly,
            .list: .scopedRead,
            // Scoped exactly like `list` because half its answer is `list`'s: a
            // working directory goes out only for a pane `list` would name.
            .layoutExport: .scopedRead,
            .send: .peerEdge,
            .revoke: .peerEdge,
            .run: .descendant,
            .read: .descendant,
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

    /// **Two verbs carry a key of their own, and the rest carry none.**
    ///
    /// `split` hands a pane a shell it could already have spawned; `run` hands it
    /// execution in another pane's context. `read` hands it another pane's screen,
    /// which every other verb's answer is not: ids, self-chosen messages, and
    /// labels the app derived, against whatever the owner happened to type.
    ///
    /// Asserted as a table rather than as "everything but run", which is what this
    /// was before `read` existed, so the next verb with a key of its own has to be
    /// named here rather than inheriting the permissive answer.
    @Test func onlyTheTwoWideVerbsCarryAKeyOfTheirOwn() {
        let gates: [ControlVerb: ControlSettingGate] = [.run: .allowRun, .read: .allowRead]
        for verb in ControlVerb.allCases {
            #expect(verb.settingGate == (gates[verb] ?? .channel), "\(verb) has the wrong gate")
        }
    }

    /// **`layout apply` never reaches a pane it did not make, and this is where
    /// that is asserted rather than described.**
    ///
    /// `.selfOnly` is the mechanism: `PaneGraph.authorize` refuses a named target
    /// for that scope outright, so a later wiring mistake that passed one cannot
    /// pass silently. A verb that reshaped the caller's window would need a wider
    /// scope to name the panes it moved, and would fail this line first.
    @Test func applyCreatesAndCannotNameAnExistingPane() {
        #expect(ControlVerb.layoutApply.scope == .selfOnly)
        #expect(ControlVerb.layoutApply.settingGate == .channel)
    }

    /// Export carries no pane's content, which is what separates it from `read`.
    ///
    /// The shape is structure and the directories are `list`'s, so the channel key
    /// is the only key it needs. Stated here because the tempting change is to
    /// give it `allowRead` "since it is a read", which would put the layout verb
    /// behind a key named for something else and leave a reader guessing which
    /// switch turned their Makefile off.
    @Test func exportIsGatedOnTheChannelAloneBecauseItCarriesNoScreen() {
        #expect(ControlVerb.layoutExport.settingGate == .channel)
        #expect(ControlVerb.read.settingGate == .allowRead)
    }

    @Test func subscribeIsSelfOnlyAndSpelledForTheWire() {
        #expect(ControlVerb.subscribe.rawValue == "subscribe")
        #expect(ControlVerb.subscribe.scope == .selfOnly)
        #expect(ControlVerb.subscribe.settingGate == .channel)
    }

    /// A pane describing itself is the least privileged thing on the wire: it
    /// names no target and reaches nothing, so it needs no key of its own.
    @Test func reportIsSelfOnlyAndGatedOnTheChannelAlone() {
        #expect(ControlVerb.report.scope == .selfOnly)
        #expect(ControlVerb.report.settingGate == .channel)
        #expect(ControlVerb.report.rawValue == "report")
    }

    /// Every combination of the two switches, for every verb, checked against the
    /// verb's own ``ControlVerb/settingGate`` rather than against a second list of
    /// verbs. A verb added without a gate decision fails in `settingGate`'s own
    /// switch, and one added with the wrong decision fails here.
    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)])
    func theGateAnswersFromTheVerbsOwnKeyForEverySettingCombination(
        switches: (read: Bool, run: Bool)
    ) {
        for verb in ControlVerb.allCases {
            let answer = verb.gate(isReadAllowed: switches.read, isRunAllowed: switches.run)

            switch verb.settingGate {
            case .channel:
                // The channel key is answered before the token is read, so a verb
                // that needs nothing else has nothing left to say here.
                #expect(answer == nil, "\(verb.rawValue) with \(switches)")
            case .allowRead:
                #expect(answer?.code == (switches.read ? nil : .disabled), "\(verb.rawValue)")
            case .allowRun:
                // Never nil, either way. `run` ships as a switch with nothing
                // behind it: on means `refused`, off means `disabled`.
                #expect(answer?.code == (switches.run ? .refused : .disabled), "\(verb.rawValue)")
            }
        }
    }

    /// The two `run` refusals are different words for a reason a caller acts on:
    /// `disabled` says turn the key on, `refused` says the key is on and the verb
    /// is not built. Collapsing them would send someone to edit a config file that
    /// already says what they want.
    @Test func runSeparatesTheKeyBeingOffFromTheVerbNotExisting() {
        let off = ControlVerb.run.gate(isReadAllowed: true, isRunAllowed: false)
        let on = ControlVerb.run.gate(isReadAllowed: true, isRunAllowed: true)

        #expect(off?.code == .disabled)
        #expect(off?.message.contains("controlAllowRun") == true)
        #expect(on?.code == .refused)
        #expect(on?.message.contains("v2") == true)
    }

    /// `read` is the only verb whose gate can answer nil on one setting and an
    /// error on the other, and the error names its own key rather than the
    /// channel's: a caller told "disabled" has to know which of the two to flip.
    @Test func readIsTheOnlyVerbTheReadKeyAnswersFor() {
        #expect(ControlVerb.read.gate(isReadAllowed: true, isRunAllowed: false) == nil)

        let refusal = ControlVerb.read.gate(isReadAllowed: false, isRunAllowed: true)
        #expect(refusal?.code == .disabled)
        #expect(refusal?.message.contains("controlAllowRead") == true)

        let gatedOnRead = ControlVerb.allCases.filter { $0.settingGate == .allowRead }
        #expect(gatedOnRead == [.read])
    }
}
