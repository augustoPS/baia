import Testing

import PaneControl

@testable import PaneCLI

/// The parser, verb by verb.
///
/// Exhaustive over ``ControlVerb/allCases`` where it can be, because the parser's
/// own switch has no `default:` and this is the other half of that guarantee: the
/// compiler makes a new verb get a spelling, and these make it get a tested one.
@Suite struct ArgumentsTests {
    // MARK: Shape of the outcome

    /// The four ``ParseOutcome`` cases, each reached by the argv that produces it.
    ///
    /// One test rather than four, because the point is that the set is closed: a
    /// fifth case would have no row here and no argv that reaches it.
    @Test func everyParseOutcomeIsReachableFromArgv() {
        #expect(isHelp(Arguments.parse(["--help"])))
        #expect(isVersion(Arguments.parse(["--version"])))
        #expect(isUsage(Arguments.parse(["nonesuch"])))
        #expect(invocation(Arguments.parse(["whoami"])) != nil)
    }

    @Test func helpIsSpelledThreeWaysAndAfterAVerbToo() {
        #expect(isHelp(Arguments.parse(["--help"])))
        #expect(isHelp(Arguments.parse(["-h"])))
        #expect(isHelp(Arguments.parse(["help"])))
        #expect(isHelp(Arguments.parse(["split", "--help"])))
        #expect(isHelp(Arguments.parse(["send", "-h"])))
    }

    /// No argv at all is a usage failure and not an implicit anything. A CLI that
    /// picked a default verb here would act on a pane because a shell function
    /// expanded to nothing.
    @Test func anEmptyCommandLineNamesNoVerb() {
        #expect(isUsage(Arguments.parse([])))
    }

    @Test func aVerbThisBuildDoesNotHaveIsRefusedRatherThanSent() {
        let outcome = Arguments.parse(["teleport"])
        #expect(isUsage(outcome))
        #expect(usageMessage(outcome)?.contains("teleport") == true)
    }

    /// An unknown verb's spelling is echoed back, and echoing an unbounded string
    /// into a terminal is a denial of service with a friendly face. So it is
    /// clamped, and the clamp is asserted rather than trusted.
    @Test func anAbsurdlyLongVerbIsClampedBeforeItIsEchoed() {
        let long = String(repeating: "z", count: 4096)
        let message = usageMessage(Arguments.parse([long]))
        #expect(message != nil)
        #expect(message?.contains(String(repeating: "z", count: 41)) == false)
    }

    /// Every verb parses from its bare name, or says why it will not.
    ///
    /// Walked from `allCases`, so a verb added to the package without a spelling
    /// in the parser fails here as well as at the parser's own switch.
    @Test func everyVerbIsReachableByItsWireSpelling() {
        // The four that need an operand, and what they need. Bare, they must
        // answer usage rather than send an incomplete request. `subscribe` is one
        // of them because a cursor it invented would be a re-read of the ring on
        // every poll.
        let needsAnOperand: Set<ControlVerb> = [.resize, .send, .revoke, .subscribe, .cwd, .report, .read]
        for verb in ControlVerb.allCases {
            let outcome = Arguments.parse([verb.rawValue])
            if needsAnOperand.contains(verb) {
                #expect(isUsage(outcome), "\(verb.rawValue) bare should be a usage failure")
            } else {
                let call = invocation(outcome)
                #expect(call?.verb == verb, "\(verb.rawValue) should parse to itself")
            }
        }
    }

    /// Every verb rejects a flag it does not have, rather than ignoring it.
    ///
    /// An ignored flag is the failure that matters here: `baia zoom --of` would
    /// toggle instead of turning off, and the pane would see a plausible answer
    /// to a question nobody asked.
    @Test func noVerbSilentlyIgnoresAFlagItDoesNotHave() {
        let operand: [ControlVerb: [String]] = [
            .resize: ["left"],
            .send: ["pane-1", "hello"],
            .revoke: ["pane-1"],
            .cwd: ["/tmp"],
            .read: ["pane-1"],
            .report: ["--state", "working"],
        ]
        for verb in ControlVerb.allCases {
            let argv = [verb.rawValue] + (operand[verb] ?? []) + ["--nonesuch"]
            #expect(isUsage(Arguments.parse(argv)), "\(verb.rawValue) should refuse --nonesuch")
        }
    }

    // MARK: Layout

    @Test func splitTakesADirectionAndACwd() {
        #expect(invocation(Arguments.parse(["split", "--right"]))?.args.axis == .horizontal)
        #expect(invocation(Arguments.parse(["split", "--down"]))?.args.axis == .vertical)
        let call = invocation(Arguments.parse(["split", "--down", "--cwd", "/tmp/x"]))
        #expect(call?.args.axis == .vertical)
        #expect(call?.args.cwd == "/tmp/x")
    }

    /// A bare `split` is a horizontal one, matching ⌘D. Spelled in the CLI rather
    /// than left nil, so the app is not asked to hold a second opinion about what
    /// a bare split means.
    @Test func aBareSplitCarriesTheSameAxisAsTheKeyboardShortcut() {
        #expect(invocation(Arguments.parse(["split"]))?.args.axis == .horizontal)
    }

    @Test func cwdWithoutAPathIsAUsageFailure() {
        #expect(isUsage(Arguments.parse(["split", "--cwd"])))
    }

    /// Verbatim, because ghostty's own reading of the string is the contract:
    /// `direct:` and `shell:` and a bare value all mean different things and none
    /// of them is the CLI's to decide.
    @Test func splitTakesACommandAndPassesItThrough() {
        let call = invocation(Arguments.parse([
            "split", "--right", "--command", "claude --resume x; exec /bin/zsh -l",
        ]))
        #expect(call?.args.axis == .horizontal)
        #expect(call?.args.command == "claude --resume x; exec /bin/zsh -l")
        #expect(invocation(Arguments.parse(["split"]))?.args.command == nil)
    }

    /// **A newline is refused because the value becomes a line of a ghostty config
    /// file.** `clipboard-read = allow` is one such line, and it undoes the OSC 52
    /// denial every pane is built with.
    @Test func aCommandCarryingANewlineIsAUsageFailure() {
        #expect(isUsage(Arguments.parse(["split", "--command", "claude\nclipboard-read = allow"])))
        #expect(isUsage(Arguments.parse(["split", "--command", "claude\rclipboard-read = allow"])))
    }

    /// Omitting the flag is how a caller asks for a login shell. An empty string is
    /// a variable that did not expand, and answering it with a login shell would
    /// hide that.
    @Test func anEmptyCommandIsAUsageFailure() {
        #expect(isUsage(Arguments.parse(["split", "--command", ""])))
        #expect(isUsage(Arguments.parse(["split", "--command"])))
    }

    @Test func aCommandLongerThanTheCapIsAUsageFailure() {
        let long = String(repeating: "x", count: ControlWire.maxCommandBytes + 1)
        #expect(isUsage(Arguments.parse(["split", "--command", long])))
        let atTheCap = String(repeating: "x", count: ControlWire.maxCommandBytes)
        #expect(invocation(Arguments.parse(["split", "--command", atTheCap]))?.args.command == atTheCap)
    }

    @Test func theThreeVerbsThatTakeNothingTakeNothing() {
        for verb in ["close", "focus", "equalize"] {
            #expect(invocation(Arguments.parse([verb])) != nil)
            #expect(isUsage(Arguments.parse([verb, "anything"])))
        }
    }

    /// Nil is a toggle, true is `--on`, false is `--off`, which is what makes
    /// `baia zoom --on` idempotent in a script.
    @Test func zoomDistinguishesTheToggleFromTheTwoStates() {
        #expect(invocation(Arguments.parse(["zoom"]))?.args.on == nil)
        #expect(invocation(Arguments.parse(["zoom", "--on"]))?.args.on == true)
        #expect(invocation(Arguments.parse(["zoom", "--off"]))?.args.on == false)
    }

    @Test func resizeTakesOneOfFourDirectionsAndNothingElse() {
        for direction in ControlDirection.allCases {
            let call = invocation(Arguments.parse(["resize", direction.rawValue]))
            #expect(call?.args.direction == direction)
        }
        #expect(isUsage(Arguments.parse(["resize", "sideways"])))
        #expect(isUsage(Arguments.parse(["resize"])))
    }

    /// A `resize` without `--by` leaves `by` nil rather than filling in a
    /// fraction here. The step a bare resize moves is the app's
    /// `PaneTree.keyboardResizeStep`, so the arrow keys and this verb cannot
    /// drift apart; a default invented in the CLI would be a second opinion that
    /// only shows up as the divider moving further from one than the other.
    @Test func resizeWithoutByDefersTheStepToTheAppRatherThanInventingOne() {
        #expect(invocation(Arguments.parse(["resize", "left"]))?.args.by == nil)
    }

    @Test func byTakesAFractionAndRefusesAnythingElse() {
        #expect(invocation(Arguments.parse(["resize", "up", "--by", "0.05"]))?.args.by == 0.05)
        #expect(isUsage(Arguments.parse(["resize", "up", "--by"])))
        #expect(isUsage(Arguments.parse(["resize", "up", "--by", "lots"])))
        // `Double("nan")` parses, and a NaN fraction resizes a divider to
        // nowhere, so finiteness is checked and not merely parseability.
        #expect(isUsage(Arguments.parse(["resize", "up", "--by", "nan"])))
        #expect(isUsage(Arguments.parse(["resize", "up", "--by", "inf"])))
    }

    // MARK: Layout documents

    /// Two tokens at the prompt, one verb on the wire.
    @Test func layoutTakesItsSubcommandAsASecondToken() {
        #expect(invocation(Arguments.parse(["layout", "export"]))?.verb == .layoutExport)
        #expect(invocation(Arguments.parse(["layout", "apply"]))?.verb == .layoutApply)
    }

    /// The wire spelling parses too, because it *is* the head lookup every other
    /// verb goes through. Asserted rather than left to be discovered, so nobody
    /// adds a rejection for a spelling that means exactly the same thing.
    @Test func theHyphenatedWireSpellingParsesToTheSameVerb() {
        #expect(invocation(Arguments.parse(["layout-export"]))?.verb == .layoutExport)
        #expect(invocation(Arguments.parse(["layout-apply"]))?.verb == .layoutApply)
    }

    @Test func layoutWithNoSubcommandOrAnUnknownOneIsAUsageFailure() {
        #expect(isUsage(Arguments.parse(["layout"])))
        #expect(isUsage(Arguments.parse(["layout", "reshape"])))
        #expect(usageMessage(Arguments.parse(["layout", "reshape"]))?.contains("export") == true)
    }

    @Test func layoutTakesItsHelpUnderEitherSpelling() {
        #expect(isHelp(Arguments.parse(["layout", "--help"])))
        #expect(isHelp(Arguments.parse(["layout", "export", "--help"])))
        #expect(isHelp(Arguments.parse(["layout-apply", "-h"])))
    }

    /// `--json` is refused rather than accepted, and the refusal says why: the
    /// plain output already *is* the document, and a second JSON shape would hand
    /// somebody a file that looks right and applies to nothing.
    @Test func exportRefusesJsonAndSaysWhy() {
        let outcome = Arguments.parse(["layout", "export", "--json"])
        #expect(isUsage(outcome))
        #expect(usageMessage(outcome)?.contains("already prints JSON") == true)
    }

    /// The refusal names the verb the way it was typed. A message reading
    /// "baia layout-export does not take" would name a spelling nobody used.
    @Test func aRefusalNamesTheVerbTheWayAPersonTypesIt() {
        let outcome = Arguments.parse(["layout", "export", "--nonesuch"])
        #expect(usageMessage(outcome)?.contains("baia layout export") == true)
    }

    /// The document comes off stdin, and parsing does no I/O, so it is nil here
    /// and filled in after the environment has been checked.
    @Test func applyReadsItsDocumentFromStdinAndNotFromArgv() {
        let call = invocation(Arguments.parse(["layout", "apply"]))
        #expect(call?.stdin == .layoutDocument)
        #expect(call?.args.layout == nil)
        #expect(isUsage(Arguments.parse(["layout", "apply", "dev.json"])))
    }

    // MARK: Introspection

    @Test func whoamiAndPeersTakeOnlyJson() {
        for verb in ["whoami", "peers"] {
            #expect(invocation(Arguments.parse([verb]))?.json == false)
            #expect(invocation(Arguments.parse([verb, "--json"]))?.json == true)
            #expect(isUsage(Arguments.parse([verb, "--tree"])))
        }
    }

    @Test func listTakesTreeAndJson() {
        #expect(invocation(Arguments.parse(["list"]))?.tree == false)
        #expect(invocation(Arguments.parse(["list", "--tree"]))?.tree == true)
        #expect(invocation(Arguments.parse(["list", "--json"]))?.json == true)
    }

    /// Two renderings of one set of records, so asking for both is a question
    /// with no answer rather than a silent preference for whichever the switch
    /// happens to reach first.
    @Test func listRefusesTreeAndJsonTogether() {
        #expect(isUsage(Arguments.parse(["list", "--tree", "--json"])))
        #expect(isUsage(Arguments.parse(["list", "--json", "--tree"])))
    }

    // MARK: Peering

    @Test func publishTakesANameAndARotate() {
        #expect(invocation(Arguments.parse(["publish"]))?.args.name == nil)
        let call = invocation(Arguments.parse(["publish", "--as", "review", "--rotate"]))
        #expect(call?.args.name == "review")
        #expect(call?.args.rotate == true)
        #expect(isUsage(Arguments.parse(["publish", "--as"])))
    }

    @Test func sendTakesAPeerAndAMessage() {
        let call = invocation(Arguments.parse(["send", "pane-1", "ready"]))
        #expect(call?.args.peer == "pane-1")
        #expect(call?.args.text == "ready")
        #expect(call?.stdin == .unused)
    }

    @Test func sendReadsTheBodyFromStdinWhenAskedTo() {
        let call = invocation(Arguments.parse(["send", "pane-1", "--stdin"]))
        #expect(call?.args.peer == "pane-1")
        // Parsing does no I/O, so the body is still absent here and is filled in
        // after the environment has been checked.
        #expect(call?.args.text == nil)
        #expect(call?.stdin == .messageBody)
    }

    /// A message given twice, once inline and once promised on stdin, is a
    /// question about which one wins. It is refused rather than answered.
    @Test func sendRefusesAMessageAndStdinTogether() {
        #expect(isUsage(Arguments.parse(["send", "pane-1", "ready", "--stdin"])))
        #expect(isUsage(Arguments.parse(["send", "pane-1"])))
        #expect(isUsage(Arguments.parse(["send"])))
        #expect(isUsage(Arguments.parse(["send", "pane-1", "one", "two"])))
    }

    @Test func recvTakesAWaitInWholeSeconds() {
        #expect(invocation(Arguments.parse(["recv"]))?.args.wait == nil)
        #expect(invocation(Arguments.parse(["recv", "--wait", "5"]))?.args.wait == 5)
        #expect(invocation(Arguments.parse(["recv", "--wait", "0"]))?.args.wait == 0)
        #expect(isUsage(Arguments.parse(["recv", "--wait"])))
        #expect(isUsage(Arguments.parse(["recv", "--wait", "2.5"])))
        #expect(isUsage(Arguments.parse(["recv", "--wait", "-1"])))
    }

    /// The cap is the server's to enforce, so a large `--wait` parses here and is
    /// clamped later. Refusing it at parse time would be the CLI holding a second
    /// opinion about a bound only one side can honour.
    @Test func recvAcceptsAWaitOverTheCapAndLeavesTheClampToTheServer() {
        let over = ControlWire.maxWaitSeconds + 60
        #expect(invocation(Arguments.parse(["recv", "--wait", String(over)]))?.args.wait == over)
    }

    @Test func revokeTakesExactlyOnePeer() {
        #expect(invocation(Arguments.parse(["revoke", "pane-1"]))?.args.peer == "pane-1")
        #expect(isUsage(Arguments.parse(["revoke"])))
        #expect(isUsage(Arguments.parse(["revoke", "pane-1", "pane-2"])))
    }

    /// `run` is declared in v1 and refused in v1, so it takes no arguments here:
    /// the arguments it will take are v2's, and inventing their spelling now
    /// would ship a shape nothing honours.
    @Test func runParsesBareAndRefusesTheArgumentsItDoesNotHaveYet() {
        #expect(invocation(Arguments.parse(["run"]))?.verb == .run)
        #expect(isUsage(Arguments.parse(["run", "ls"])))
    }

    // MARK: Observation

    @Test func subscribeTakesACursorAWaitAndAKindList() {
        let call = invocation(
            Arguments.parse(
                ["subscribe", "--from", "41", "--wait", "30", "--kinds", "paneClosed,attentionRaised"]
            )
        )
        #expect(call?.verb == .subscribe)
        #expect(call?.args.from == 41)
        #expect(call?.args.wait == 30)
        #expect(call?.args.kinds == ["paneClosed", "attentionRaised"])
    }

    /// The cursor is required. Defaulting it to 0 would make "start from the
    /// beginning" the thing that happens when a script forgets to thread its
    /// cursor through, which is a re-read of the whole ring on every poll.
    @Test func subscribeNeedsACursor() {
        let outcome = Arguments.parse(["subscribe"])
        #expect(isUsage(outcome))
        #expect(usageMessage(outcome)?.contains("--from") == true)
    }

    /// Caught here as a convenience so the common case never round-trips. The
    /// server checks it too, and the server's check is the rule.
    @Test func subscribeRefusesAKindItDoesNotKnow() {
        let outcome = Arguments.parse(["subscribe", "--from", "0", "--kinds", "paneOpenned"])
        #expect(isUsage(outcome))
        #expect(usageMessage(outcome)?.contains("paneOpenned") == true)
    }

    @Test func subscribeRefusesANegativeCursor() {
        let outcome = Arguments.parse(["subscribe", "--from", "-1"])
        #expect(isUsage(outcome))
        #expect(usageMessage(outcome)?.contains("--from") == true)
    }

    /// Every kind spells itself the same way on the command line as on the wire,
    /// walked from `allCases` so a kind added to the package cannot arrive
    /// unparseable.
    @Test func everyEventKindIsAcceptedByItsWireSpelling() {
        for kind in ControlEventKind.allCases {
            let call = invocation(Arguments.parse(["subscribe", "--from", "0", "--kinds", kind.rawValue]))
            #expect(call?.args.kinds == [kind.rawValue], "\(kind.rawValue) should parse")
        }
    }

    /// A bare `--kinds` names no kind, and an empty list is a subscription that
    /// can never deliver anything. Both are refused rather than silently read as
    /// "all of them".
    @Test func kindsNeedsAtLeastOneName() {
        #expect(isUsage(Arguments.parse(["subscribe", "--from", "0", "--kinds"])))
        #expect(isUsage(Arguments.parse(["subscribe", "--from", "0", "--kinds", ","])))
    }

    /// The cap is the server's to enforce, exactly as it is for `recv`.
    @Test func subscribeAcceptsAWaitOverTheCapAndLeavesTheClampToTheServer() {
        let over = ControlWire.maxWaitSeconds + 60
        let call = invocation(Arguments.parse(["subscribe", "--from", "0", "--wait", String(over)]))
        #expect(call?.args.wait == over)
    }

    // MARK: Unwrapping

    private func invocation(_ outcome: ParseOutcome) -> Invocation? {
        guard case let .invoke(call) = outcome else { return nil }
        return call
    }

    private func usageMessage(_ outcome: ParseOutcome) -> String? {
        guard case let .usage(message) = outcome else { return nil }
        return message
    }

    private func isUsage(_ outcome: ParseOutcome) -> Bool {
        usageMessage(outcome) != nil
    }

    private func isHelp(_ outcome: ParseOutcome) -> Bool {
        if case .help = outcome { return true }
        return false
    }

    private func isVersion(_ outcome: ParseOutcome) -> Bool {
        if case .version = outcome { return true }
        return false
    }

    // MARK: report

    /// A statement about nothing is not a statement. Exactly one of the two
    /// forms is required, and both together is a caller that has not decided.
    @Test func reportRequiresExactlyOneOfStateOrRelease() {
        #expect(isUsage(Arguments.parse(["report"])))
        #expect(isUsage(Arguments.parse(["report", "--state", "working", "--release"])))
    }

    @Test func reportRefusesAnUnknownState() {
        #expect(isUsage(Arguments.parse(["report", "--state", "thinking"])))
    }

    /// A message rides a raise and never a clear, so it is meaningless on the two
    /// states that do not raise. Refused rather than ignored, like every other
    /// stray flag here.
    @Test func aMessageIsAcceptedOnlyWithBlocked() {
        #expect(isUsage(Arguments.parse(["report", "--state", "blocked", "--message", "hi"])) == false)
        #expect(isUsage(Arguments.parse(["report", "--state", "working", "--message", "hi"])))
        #expect(isUsage(Arguments.parse(["report", "--state", "idle", "--message", "hi"])))
    }

    @Test func reportCarriesItsFieldsOntoTheWire() {
        let call = invocation(Arguments.parse(["report", "--state", "blocked",
                                               "--message", "which branch?",
                                               "--ttl", "120", "--seq", "7"]))
        #expect(call?.verb == .report)
        #expect(call?.args.state == .blocked)
        #expect(call?.args.text == "which branch?")
        #expect(call?.args.ttl == 120)
        #expect(call?.args.seq == 7)
    }

    @Test func releaseCarriesNothingElse() {
        let call = invocation(Arguments.parse(["report", "--release"]))
        #expect(call?.args.release == true)
        #expect(call?.args.state == nil)
    }

    /// A TTL or a sequence that is not a number is a usage failure rather than a
    /// zero, which is the reading that cannot be mistaken for an answer.
    @Test func reportRefusesNonNumericTTLAndSeq() {
        #expect(isUsage(Arguments.parse(["report", "--state", "working", "--ttl", "soon"])))
        #expect(isUsage(Arguments.parse(["report", "--state", "working", "--seq", "next"])))
    }

    // MARK: install-hooks

    /// **Not a verb, and the suite that sweeps every verb must not see it.** The
    /// channel's enum is what a capability reaches; this edits a file at home and
    /// opens no socket.
    @Test func installHooksIsNotAControlVerb() {
        #expect(ControlVerb(rawValue: "install-hooks") == nil)
        #expect(ControlVerb.allCases.contains { $0.rawValue == "install-hooks" } == false)
    }

    @Test func installHooksParsesAsALocalCommand() {
        guard case let .local(command) = Arguments.parse(["install-hooks"]) else {
            Issue.record("install-hooks did not parse as a local command")
            return
        }
        #expect(command == .installHooks(uninstall: false))
    }

    @Test func uninstallParses() {
        guard case let .local(command) = Arguments.parse(["install-hooks", "--uninstall"]) else {
            Issue.record("--uninstall did not parse")
            return
        }
        #expect(command == .installHooks(uninstall: true))
    }

    /// A usage failure, not `unknownVerb`. That code is the socket's answer and
    /// claiming it here would say the channel had refused something it never saw.
    @Test func installHooksRefusesAFlagItDoesNotHave() {
        #expect(isUsage(Arguments.parse(["install-hooks", "--nonesuch"])))
        #expect(isUsage(Arguments.parse(["install-hooks", "stray"])))
    }

    // MARK: read

    /// A `read` with no pane would be an expensive way to ask what `whoami`
    /// answers, and a typo in an id would silently become a read of oneself.
    @Test func readNeedsAPaneAndRefusesAFlagInsteadOfOne() {
        #expect(isUsage(Arguments.parse(["read"])))
        #expect(isUsage(Arguments.parse(["read", "--lines", "10"])))
    }

    @Test func readCarriesItsTargetAndCount() {
        let call = invocation(Arguments.parse(["read", "pane-1", "--lines", "120"]))
        #expect(call?.verb == .read)
        #expect(call?.args.peer == "pane-1")
        #expect(call?.args.lines == 120)
    }

    /// An absent count is nil on the wire, not a number the CLI invented, so the
    /// default lives in one place and the server is the only thing that applies
    /// it.
    @Test func anAbsentCountIsLeftForTheServer() {
        #expect(invocation(Arguments.parse(["read", "pane-1"]))?.args.lines == nil)
    }

    @Test func readRefusesANonNumericCount() {
        #expect(isUsage(Arguments.parse(["read", "pane-1", "--lines", "lots"])))
    }
}
