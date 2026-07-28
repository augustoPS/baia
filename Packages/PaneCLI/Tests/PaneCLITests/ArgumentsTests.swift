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
        // The three that need an operand, and what they need. Bare, they must
        // answer usage rather than send an incomplete request.
        let needsAnOperand: Set<ControlVerb> = [.resize, .send, .revoke]
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
}
