import Foundation
import Testing

@testable import PaneControl

@Suite struct ControlWireTests {
    /// A stand-in display pane id. A UUID string, because that is what
    /// `$BAIA_PANE` carries and what every record on this wire spells.
    static let paneID = "8B0E6B1E-6C1B-4C56-9E5E-2C1E9F3A7D40"

    /// One representative request per verb, built by a switch with no
    /// `default:`, so a verb added without a decided wire shape fails to compile
    /// in this test as well as in ``ControlVerb/scope``.
    static func representativeArgs(for verb: ControlVerb) -> ControlArgs {
        switch verb {
        case .split: ControlArgs(
            axis: .vertical,
            cwd: "/Users/x/Projects/vault",
            command: "exec '/bin/zsh' -lc 'claude --resume a-session; exec \"$SHELL\" -l'"
        )
        case .close: ControlArgs()
        case .focus: ControlArgs()
        case .zoom: ControlArgs(on: true)
        case .resize: ControlArgs(direction: .left, by: 0.05)
        case .equalize: ControlArgs()
        case .cwd: ControlArgs(cwd: "/Users/x/Projects/website")
        case .whoami: ControlArgs()
        case .list: ControlArgs()
        case .publish: ControlArgs(name: "reviewer", rotate: true)
        case .connect: ControlArgs(name: "reviewer", rendezvous: "an-admission-ticket")
        case .peers: ControlArgs()
        case .send: ControlArgs(peer: paneID, text: "two\nlines and a \"quote\"")
        case .recv: ControlArgs(wait: 60)
        case .revoke: ControlArgs(peer: paneID)
        case .subscribe: ControlArgs(wait: 30, from: 41, kinds: ["paneClosed"])
        case .report: ControlArgs(text: "which branch?", state: .blocked, ttl: 120, seq: 7)
        case .read: ControlArgs(lines: 50)
        // Export sends nothing; the window it describes is the caller's own.
        case .layoutExport: ControlArgs()
        // A nested tree with a directory on one leaf and none on the other, which
        // is what a redacted export looks like coming back in.
        case .layoutApply: ControlArgs(layout: ControlLayout(tabs: [
            .split(
                axis: .horizontal,
                ratio: 0.4,
                first: .pane(cwd: "/Users/x/Projects/baia"),
                second: .pane(cwd: nil)
            ),
            .pane(cwd: nil),
        ]))
        case .run: ControlArgs()
        }
    }

    @Test func everyRequestShapeSurvivesTheRoundTrip() {
        for verb in ControlVerb.allCases {
            let request = ControlRequest(
                token: "opaque",
                verb: verb,
                args: Self.representativeArgs(for: verb)
            )
            guard let line = ControlWire.encodeRequest(request) else {
                Issue.record("\(verb) did not encode")
                continue
            }
            switch ControlWire.decodeRequest(line) {
            case let .request(decoded):
                #expect(decoded == request)
            case let .failure(error):
                Issue.record("\(verb) decoded as \(error.code): \(error.message)")
            }
        }
    }

    @Test func everyResponseShapeSurvivesTheRoundTrip() {
        var responses: [ControlResponse] = [
            .success(),
            .success(ControlResult(pane: Self.paneID)),
            .success(ControlResult(rendezvous: "an-admission-ticket")),
            .success(ControlResult(zoomed: true)),
            .success(ControlResult(pane: Self.paneID, name: "reviewer")),
            .success(ControlResult(panes: [
                PaneRecord(
                    pane: Self.paneID,
                    window: 1,
                    tab: 2,
                    workingDirectory: "/Users/x/Projects/vault",
                    anchor: "/Users/x/Projects",
                    branch: "control-channel",
                    activity: "running",
                    attention: "needsInput",
                    createdBy: Self.paneID,
                    channels: ["reviewer"],
                    peers: [Self.paneID]
                ),
                PaneRecord(pane: Self.paneID, window: 1, tab: 2),
            ])),
            .success(ControlResult(
                messages: [ControlMessage(from: Self.paneID, text: "two\nlines")],
                more: true,
                dropped: 3
            )),
        ]
        // Every code, walked from `allCases`, so a code added without a
        // round-trip is a failing test rather than a value that encodes and
        // comes back as something else.
        responses += ControlErrorCode.allCases.map {
            .failure(ControlError(code: $0, message: "why it failed"))
        }

        for response in responses {
            guard let line = ControlWire.encodeResponse(response) else {
                Issue.record("response did not encode: \(response)")
                continue
            }
            #expect(ControlWire.decodeResponse(line) == response)
        }
    }

    /// `internal` is a Swift keyword and the case is backticked. The wire
    /// spelling has to be the plain word anyway, and nothing but a test says so.
    @Test func theInternalErrorCodeSpellsItselfPlainlyOnTheWire() {
        #expect(ControlErrorCode.internal.rawValue == "internal")
        #expect(ControlErrorCode(rawValue: "internal") == .internal)
    }

    /// Both directions of the version mismatch, and the message has to name both
    /// versions: the reader is holding a helper from another build and has no
    /// other way to work out which.
    @Test func aFrameFromAnotherVersionNamesBothVersions() {
        for received in [0, 2, 99] {
            let line = Data(
                #"{"v": \#(received), "token": "t", "verb": "whoami", "args": {}}"#.utf8
            )
            guard case let .failure(error) = ControlWire.decodeRequest(line) else {
                Issue.record("v: \(received) decoded as a request")
                continue
            }
            #expect(error.code == .badVersion)
            #expect(error.message.contains("v\(ControlWire.version)"))
            #expect(error.message.contains("v\(received)"))
        }
    }

    /// The version is read on its own pass, before anything else can fail, so a
    /// frame from a future build is told which version it is talking to rather
    /// than being told its shape is wrong. Without the separate pass this frame
    /// answers `unknownVerb`, which sends the reader looking for a typo.
    @Test func theVersionIsAnsweredBeforeTheVerbIs() {
        let line = Data(#"{"v": 2, "token": "t", "verb": "teleport", "args": {}}"#.utf8)
        guard case let .failure(error) = ControlWire.decodeRequest(line) else {
            Issue.record("a v2 frame decoded as a request")
            return
        }
        #expect(error.code == .badVersion)
    }

    /// An unknown verb is an ordinary answer with its own code, produced as a
    /// value. Decoding the verb as a `ControlVerb` directly would throw on an
    /// unknown case, and a throw here is a failure path the server would have to
    /// catch on the way to the same answer.
    @Test func anUnknownVerbIsAnAnswerAndNotAThrow() {
        let line = Data(#"{"v": 1, "token": "t", "verb": "teleport", "args": {}}"#.utf8)
        guard case let .failure(error) = ControlWire.decodeRequest(line) else {
            Issue.record("an unknown verb decoded as a request")
            return
        }
        #expect(error.code == .unknownVerb)
        #expect(error.message.contains("teleport"))
    }

    /// A verb long enough to fill a frame comes back clamped. The verb is
    /// attacker-controlled up to the frame cap, and a 256 KiB error message is
    /// a 256 KiB response written to somebody's terminal for a typo.
    @Test func anUnknownVerbIsEchoedBackClamped() {
        let long = String(repeating: "z", count: 4096)
        let line = Data(#"{"v": 1, "token": "t", "verb": "\#(long)"}"#.utf8)
        guard case let .failure(error) = ControlWire.decodeRequest(line) else {
            Issue.record("a very long verb decoded as a request")
            return
        }
        #expect(error.code == .unknownVerb)
        #expect(error.message.count < 200)
    }

    /// A line that stops mid-object is the shape a crashed writer and a
    /// half-flushed socket both leave behind.
    @Test func aTruncatedFrameIsABadFrame() {
        let whole = Data(#"{"v": 1, "token": "t", "verb": "whoami", "args": {}}"#.utf8)
        let truncated = whole.prefix(whole.count - 12)
        guard case let .failure(error) = ControlWire.decodeRequest(truncated) else {
            Issue.record("a truncated frame decoded as a request")
            return
        }
        #expect(error.code == .badFrame)
    }

    /// Neither a fragment nor a JSON value that is not an object is a request.
    @Test func aFrameThatIsNotARequestObjectIsABadFrame() {
        for text in ["", "   ", "[1, 2, 3]", "null", #"{"v": "one"}"#, #"{"token": "t"}"#] {
            guard case let .failure(error) = ControlWire.decodeRequest(Data(text.utf8)) else {
                Issue.record("\(text) decoded as a request")
                continue
            }
            #expect(error.code == .badFrame)
        }
    }

    /// A frame carrying every field a request needs, and one field too large,
    /// is refused on size before it is parsed.
    ///
    /// The server never reaches this path, because a line exceeding the cap
    /// before its newline arrives is closed on without a response by the read
    /// loop, which is rule 5's one carve-out. The decoder answers anyway, so
    /// that a caller which assembled a line some other way cannot get an
    /// over-cap request past it.
    @Test func aFrameOverTheCapIsABadFrame() {
        let request = ControlRequest(
            token: "t",
            verb: .send,
            args: ControlArgs(
                peer: Self.paneID,
                text: String(repeating: "x", count: ControlWire.maxFrameBytes)
            )
        )
        guard let line = ControlWire.encodeRequest(request) else {
            Issue.record("the over-cap request did not encode")
            return
        }
        #expect(line.count > ControlWire.maxFrameBytes)
        guard case let .failure(error) = ControlWire.decodeRequest(line) else {
            Issue.record("an over-cap frame decoded as a request")
            return
        }
        #expect(error.code == .badFrame)
        #expect(error.message.contains("cap"))
    }

    /// The message cap sits below the frame cap so that a maximal message still
    /// fits a response. It does for every payload a message plausibly holds:
    /// 48 KiB of text that is entirely quotes and backslashes doubles to 96 KiB
    /// and clears the 256 KiB cap with room for the record around it.
    ///
    /// It does not for the worst case the budget's own justification names, and
    /// that arithmetic is pinned here rather than left to be discovered: 48 KiB
    /// of C0 control bytes escape to a six-byte JSON escape each, which is 288
    /// KiB and over the frame cap. A payload that cannot be framed would sit in
    /// a mailbox undrainable forever, because a message leaves the mailbox only
    /// once it has been framed into a response that fits. `send` is therefore
    /// the place that has to refuse it, and it has to measure the framed size
    /// rather than the payload size.
    @Test func aMaximalMessageFitsAFrameUnlessItIsAllControlBytes() {
        func framedSize(ofPayload payload: String) -> Int? {
            ControlWire.encodeResponse(.success(ControlResult(
                messages: [ControlMessage(from: Self.paneID, text: payload)],
                more: false,
                dropped: 0
            )))?.count
        }

        let escapedByDoubling = String(
            repeating: #"\""#, count: ControlWire.maxMessagePayloadBytes / 2
        )
        guard let doubled = framedSize(ofPayload: escapedByDoubling) else {
            Issue.record("a maximal quoted message did not encode")
            return
        }
        #expect(doubled <= ControlWire.maxFrameBytes)

        let controlBytes = String(
            repeating: "\u{1}", count: ControlWire.maxMessagePayloadBytes
        )
        guard let sixfold = framedSize(ofPayload: controlBytes) else {
            Issue.record("a maximal control-byte message did not encode")
            return
        }
        #expect(sixfold > ControlWire.maxFrameBytes)
    }

    /// The framing is newline-delimited, so a body carrying newlines must not be
    /// able to break it. One encoded line holds exactly one newline, its
    /// terminator, whatever the message said.
    @Test func anEncodedFrameHoldsOneNewlineAndItIsTheTerminator() {
        let request = ControlRequest(
            token: "t",
            verb: .send,
            args: ControlArgs(peer: Self.paneID, text: "one\ntwo\r\nthree\n")
        )
        guard let line = ControlWire.encodeRequest(request) else {
            Issue.record("the request did not encode")
            return
        }
        #expect(line.filter { $0 == 0x0A }.count == 1)
        #expect(line.last == 0x0A)
    }

    /// The reader that split the line off the socket is not made to care whether
    /// it kept the terminator, and a frame typed by hand into `nc` from
    /// something that ends lines the DOS way still decodes.
    @Test func theTrailingNewlineIsOptionalInEitherSpelling() {
        let body = #"{"v": 1, "token": "t", "verb": "whoami", "args": {}}"#
        for suffix in ["", "\n", "\r\n"] {
            guard case let .request(decoded) = ControlWire.decodeRequest(Data((body + suffix).utf8))
            else {
                Issue.record("a frame ending in \(suffix.debugDescription) did not decode")
                continue
            }
            #expect(decoded.verb == .whoami)
        }
    }

    /// A verb that needs no arguments can be typed without an `args` object at
    /// all, which is what makes the diagnostic's hand-written frames short. It
    /// decodes to the same request the CLI would have built.
    @Test func aFrameWithNoArgsDecodesToEmptyArgs() {
        let line = Data(#"{"v": 1, "token": "t", "verb": "whoami"}"#.utf8)
        guard case let .request(decoded) = ControlWire.decodeRequest(line) else {
            Issue.record("a frame with no args did not decode")
            return
        }
        #expect(decoded == ControlRequest(token: "t", verb: .whoami))
    }

    /// Nil arguments are absent from the frame rather than spelled `null`, so a
    /// frame read with `nc` shows what the verb was actually asked, and an empty
    /// `args` is `{}`.
    @Test func absentArgumentsAreAbsentFromTheFrame() {
        guard let line = ControlWire.encodeRequest(
            ControlRequest(token: "t", verb: .zoom, args: ControlArgs(on: false))
        ) else {
            Issue.record("the request did not encode")
            return
        }
        let text = String(decoding: line, as: UTF8.self)
        #expect(text.contains(#""args":{"on":false}"#))
        #expect(text.contains("null") == false)

        guard let empty = ControlWire.encodeRequest(
            ControlRequest(token: "t", verb: .whoami)
        ) else {
            Issue.record("the empty request did not encode")
            return
        }
        #expect(String(decoding: empty, as: UTF8.self).contains(#""args":{}"#))
    }

    /// The decoder authenticates nothing, deliberately.
    ///
    /// A value that happens to parse as a well-formed pane id decodes like any
    /// other string and is rejected by the registry, not here. Rejecting it at
    /// the wire would put a second copy of the rule in a second place, and two
    /// copies of a security rule is how one of them ends up wrong. What this
    /// test pins is the layering: a pane id arriving where a per-run secret
    /// belongs is a *decoded* request that authorization must then refuse.
    @Test func theDecoderDoesNotAuthenticateAndSaysSoByShape() {
        let line = Data(#"{"v": 1, "token": "\#(Self.paneID)", "verb": "list"}"#.utf8)
        guard case let .request(decoded) = ControlWire.decodeRequest(line) else {
            Issue.record("a pane-id-shaped credential failed to decode, hiding it from authorization")
            return
        }
        #expect(decoded.token == Self.paneID)
    }

    /// A response this build cannot read is nil rather than a half-built one,
    /// and the CLI has exactly one thing to say about it: the app it is talking
    /// to is not the build it shipped with.
    @Test func aResponseThatIsNotOneDecodesToNil() {
        #expect(ControlWire.decodeResponse(Data(#"{"ok": true"#.utf8)) == nil)
        let unknownCode = #"{"v": 1, "ok": false, "error": {"code": "teleported", "message": "x"}}"#
        #expect(ControlWire.decodeResponse(Data(unknownCode.utf8)) == nil)
        #expect(ControlWire.decodeResponse(Data(repeating: 0x7B, count: ControlWire.maxFrameBytes + 1)) == nil)
    }

    /// `kinds` crosses as strings rather than as the enum, so a frame written by
    /// hand with a misspelled kind is answered `refused` with the bad name in it
    /// rather than `badFrame` from a decoder that got no further.
    // MARK: The wait cap

    /// The cap the budget table has claimed since v1 and nothing exercised. It
    /// was one line in the app target, which has no test target, so "60 s
    /// maximum" was a number in a document rather than a number under test.
    // MARK: What a split may be told to run

    /// **The rule that matters.** The value is rendered into a ghostty config file
    /// as `command = <value>` and that file is parsed line by line, so a value
    /// carrying a newline writes a second key of the caller's choosing.
    /// `clipboard-read = allow` is one line long and undoes the OSC 52 denial
    /// every pane is built with, which is the one setting this project has a
    /// standing rule never to relax.
    @Test func aCommandCarryingANewlineIsRefused() {
        #expect(ControlWire.refusalForCommand("claude\nclipboard-read = allow") != nil)
        #expect(ControlWire.refusalForCommand("claude\rclipboard-read = allow") != nil)
        #expect(ControlWire.refusalForCommand("claude\r\nclipboard-read = allow") != nil)
        // The Unicode line separators, because `isNewline` counts them and a
        // config parser splitting on them would be a second way in.
        #expect(ControlWire.refusalForCommand("claude\u{2028}x") != nil)
        #expect(ControlWire.refusalForCommand("claude\u{0085}x") != nil)
    }

    /// Everything a caller genuinely needs is still spellable, including the two
    /// forms the fork hook writes.
    @Test func anOrdinaryCommandIsAllowed() {
        #expect(ControlWire.refusalForCommand("claude --resume x; exec /bin/zsh -l") == nil)
        #expect(ControlWire.refusalForCommand("direct:nvim") == nil)
        #expect(ControlWire.refusalForCommand("shell:ls | wc -l") == nil)
        #expect(ControlWire.refusalForCommand(
            "exec '/bin/zsh' -lc 'claude --resume a; exec \"$SHELL\" -l'"
        ) == nil)
    }

    /// Omitting `--command` is how a caller asks for a login shell. An empty string
    /// is a variable that did not expand, and honouring it as a login shell would
    /// hide that from the only person who could fix it.
    @Test func anEmptyCommandIsRefusedRatherThanTreatedAsAbsent() {
        #expect(ControlWire.refusalForCommand("") != nil)
    }

    /// Refused rather than truncated. A command cut in half is a different command,
    /// and running one is worse than running none.
    @Test func aCommandOverTheCapIsRefused() {
        #expect(ControlWire.refusalForCommand(
            String(repeating: "x", count: ControlWire.maxCommandBytes)
        ) == nil)
        #expect(ControlWire.refusalForCommand(
            String(repeating: "x", count: ControlWire.maxCommandBytes + 1)
        ) != nil)
        // Bytes and not characters, so a command of multibyte text is measured the
        // way the frame will measure it.
        #expect(ControlWire.refusalForCommand(
            String(repeating: "é", count: ControlWire.maxCommandBytes / 2 + 1)
        ) != nil)
    }

    @Test func aWaitIsCappedRatherThanTrusted() {
        #expect(ControlWire.cappedWait(3600) == ControlWire.maxWaitSeconds)
        #expect(ControlWire.cappedWait(30) == 30)
        #expect(ControlWire.cappedWait(ControlWire.maxWaitSeconds) == ControlWire.maxWaitSeconds)
    }

    /// Nil is "do not park", and so is zero, and so is a negative. A client
    /// asking to wait for a negative time has asked for no wait, and answering it
    /// immediately is the reading that cannot surprise anybody.
    @Test func noWaitIsSpelledSeveralWaysAndAllOfThemMeanAnswerNow() {
        #expect(ControlWire.cappedWait(nil) == nil)
        #expect(ControlWire.cappedWait(0) == nil)
        #expect(ControlWire.cappedWait(-1) == nil)
        #expect(ControlWire.cappedWait(Int.min) == nil)
    }

    // MARK: How long a report may hold authority

    /// The default is what a reporter that says nothing gets, and it is finite on
    /// purpose: an unbounded report is a pane holding authority forever against a
    /// poller that can see it is wrong.
    @Test func anAbsentTTLTakesTheDefault() {
        #expect(ControlWire.cappedReportTTL(nil) == ControlWire.defaultReportTTLSeconds)
    }

    @Test func aTTLInsideTheBudgetIsKept() {
        #expect(ControlWire.cappedReportTTL(120) == 120)
        #expect(ControlWire.cappedReportTTL(ControlWire.maxReportTTLSeconds) == ControlWire.maxReportTTLSeconds)
    }

    /// Capped rather than trusted, the same reading ``ControlWire/cappedWait(_:)``
    /// gives a long poll, so the two cannot drift apart on what a client may ask
    /// for.
    @Test func anOversizedTTLIsCappedRatherThanRefused() {
        #expect(ControlWire.cappedReportTTL(999_999) == ControlWire.maxReportTTLSeconds)
        #expect(ControlWire.cappedReportTTL(Int.max) == ControlWire.maxReportTTLSeconds)
    }

    /// **Zero is kept here where `cappedWait` folds it into nil.** The two verbs
    /// mean opposite things by it: a zero wait is "answer me now", and a zero TTL
    /// is "this expires at once", which is `--release` said with a number. Both
    /// readings are the one that cannot surprise the caller, and they differ
    /// because the underlying quantities do.
    @Test func zeroAndNegativeTTLsExpireImmediately() {
        #expect(ControlWire.cappedReportTTL(0) == 0)
        #expect(ControlWire.cappedReportTTL(-5) == 0)
        #expect(ControlWire.cappedReportTTL(Int.min) == 0)
    }

    @Test func anUnknownKindIsNamedInTheRefusal() {
        let error = ControlError.unknownEventKind("paneOpenned")
        #expect(error.code == .refused)
        #expect(error.message.contains("paneOpenned"))
    }

    @Test func subscribeArgumentsSurviveARoundTrip() {
        let caller = "c1-not-a-uuid-caller"
        let request = ControlRequest(
            token: caller,
            verb: .subscribe,
            args: ControlArgs(wait: 30, from: 41, kinds: ["paneClosed"])
        )
        guard let line = ControlWire.encodeRequest(request) else {
            Issue.record("a well-formed subscribe did not encode")
            return
        }
        switch ControlWire.decodeRequest(line) {
        case let .request(decoded):
            #expect(decoded.args.from == 41)
            #expect(decoded.args.kinds == ["paneClosed"])
            #expect(decoded.args.wait == 30)
        case let .failure(error):
            Issue.record("a well-formed subscribe was refused: \(error.message)")
        }
    }

    /// A response from another build is nil, not a v1 response with a `v` nobody
    /// looked at.
    ///
    /// This frame is well-formed in every other respect and decodes into
    /// ``ControlResponse`` without complaint, because `v` is an `Int` the
    /// synthesized decoder is happy to accept. Only the separate version pass
    /// catches it. The request direction has answered `badVersion` for the
    /// mirror image of this frame since it was written, and for a while this
    /// direction claimed the same check in a doc comment without performing it.
    @Test func aResponseFromAnotherVersionDecodesToNil() {
        for received in [0, 2, 99] {
            let ok = #"{"v": \#(received), "ok": true, "result": {"pane": "\#(Self.paneID)"}}"#
            #expect(ControlWire.decodeResponse(Data(ok.utf8)) == nil)

            let failed = #"{"v": \#(received), "ok": false, "error": {"code": "refused", "message": "x"}}"#
            #expect(ControlWire.decodeResponse(Data(failed.utf8)) == nil)
        }

        // The same frame at this build's version still reads, so the guard
        // rejects the version and not the shape.
        let current = #"{"v": \#(ControlWire.version), "ok": true, "result": {"pane": "\#(Self.paneID)"}}"#
        #expect(ControlWire.decodeResponse(Data(current.utf8))
            == .success(ControlResult(pane: Self.paneID)))
    }
}
