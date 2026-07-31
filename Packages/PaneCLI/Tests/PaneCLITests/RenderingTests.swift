import Foundation
import PaneControl
import Testing

@testable import PaneCLI

/// What a pane sees, and on which stream it sees it.
///
/// The stream split is the invariant worth guarding: `baia publish | pbcopy` must
/// carry a ticket and nothing else, and `baia recv > log` must carry message
/// bodies and not a drop counter. A note that drifted onto stdout would break
/// both without breaking anything that looks like a test.
@Suite struct RenderingTests {
    // MARK: The scope hint

    /// A `list` answering one record is the ordinary case for a pane the owner
    /// opened by hand: it created nothing and has no peers, so it is the whole of
    /// its own scope. It reads as broken the first time, which is why the CLI
    /// says so.
    @Test func listExplainsItselfWhenTheOnlyRecordIsTheCallingPane() throws {
        let lines = Rendering.render(result(panes: [record("pane-1")]), for: try call("list"))
        let hint = try #require(lines.first { $0.stream == .err })
        #expect(hint.text.contains("only this pane is in scope"))
        #expect(hint.text.contains("created through the channel"))
    }

    /// On stderr, not stdout. The hint is prose for a reader, and `baia list`
    /// piped into anything must carry records only.
    @Test func theScopeHintNeverReachesStdout() throws {
        let lines = Rendering.render(result(panes: [record("pane-1")]), for: try call("list"))
        for line in lines where line.stream == .out {
            #expect(!line.text.contains("only this pane is in scope"))
        }
    }

    /// Two records is a pane with a descendant or a peer, which explains itself.
    @Test func listSaysNothingExtraOnceThereIsMoreThanOneRecord() throws {
        let records = [record("pane-1"), record("pane-2", createdBy: "pane-1")]
        let lines = Rendering.render(result(panes: records), for: try call("list"))
        #expect(!lines.contains { $0.stream == .err })
    }

    /// The hint is about the count of records and not about the rendering, so
    /// `--tree` gets it too.
    @Test func theScopeHintSurvivesTheTreeRendering() throws {
        let lines = Rendering.render(result(panes: [record("pane-1")]), for: try call("list", "--tree"))
        #expect(lines.contains { $0.stream == .err && $0.text.contains("only this pane is in scope") })
        #expect(lines.contains { $0.stream == .out && $0.text == "pane-1" })
    }

    // MARK: The bootstrap

    /// The help tells a script to take its first cursor from `baia list`, and
    /// this is the line it takes it from. Last and on stdout, exactly like
    /// `subscribe`, so one `tail -1` reads either.
    ///
    /// Without it the documented `list` then `subscribe --from SEQ` is
    /// impossible in the line format, and a script's only ways out are
    /// `list --json | jq .seq`, which is the JSON parser the format exists to
    /// avoid, or `--from 0`, which answers `gap: true` on any wrapped ring.
    @Test func listPrintsTheSequenceItReadAtOnItsLastLine() throws {
        let records = [record("pane-1"), record("pane-2", createdBy: "pane-1")]
        let lines = Rendering.render(result(panes: records, seq: 17), for: try call("list"))

        #expect(lines.filter { $0.stream == .out }.map(\.text).last == "seq 17")
    }

    /// `--tree` is a second rendering of the same records, not a second answer,
    /// so it reports the same cursor. A flag that decided whether a script could
    /// bootstrap would be the kind of thing nobody finds until the ring wraps.
    @Test func theTreeRenderingReportsTheSameSequence() throws {
        let lines = Rendering.render(
            result(panes: [record("pane-1")], seq: 17), for: try call("list", "--tree")
        )

        #expect(lines.filter { $0.stream == .out }.map(\.text) == ["pane-1", "seq 17"])
    }

    /// An answer carrying no sequence prints no seq line. A `list` that invented
    /// one would hand a subscriber a cursor no ring ever minted.
    @Test func aListWithNoSequenceSaysNothingAboutOne() throws {
        let lines = Rendering.render(result(panes: [record("pane-1")]), for: try call("list"))

        #expect(!lines.contains { $0.text.hasPrefix("seq") })
    }

    // MARK: --json

    /// `--json` prints the result object and nothing else: no hint, no note, one
    /// line on stdout.
    ///
    /// Re-encoded from the decoded value rather than reshaped, so a scope leak
    /// shows up verbatim instead of being tidied away by a renderer. The way to
    /// assert that is to decode the printed text back and compare values, which
    /// is what happens below.
    @Test func jsonEmitsTheResultObjectUnchanged() throws {
        let original = result(
            panes: [record("pane-1", createdBy: "pane-0", peers: ["pane-9"])],
            pane: "pane-1",
            rendezvous: "a-rendezvous-value",
            zoomed: true,
            more: true,
            dropped: 3
        )
        let lines = Rendering.render(original, for: try call("list", "--json"))
        #expect(lines.allSatisfy { $0.stream == .out })
        #expect(lines.count == 1)

        let text = try #require(lines.first?.text)
        let decoded = try JSONDecoder().decode(ControlResult.self, from: Data(text.utf8))
        #expect(decoded == original)
    }

    /// Including the fields a renderer would have dropped. `whoami --json` shows
    /// the record whole, `createdBy` and `peers` included, because redaction is
    /// the server's job and hiding a leak at the last moment would make the
    /// server's job unobservable.
    @Test func jsonKeepsTheFieldsTheHumanRenderingWouldHaveDropped() throws {
        let leaky = record("pane-1", createdBy: "pane-0", peers: ["pane-9"])
        let lines = Rendering.render(result(panes: [leaky]), for: try call("whoami", "--json"))
        let text = try #require(lines.first?.text)
        #expect(text.contains("pane-0"))
        #expect(text.contains("pane-9"))
    }

    /// No scope hint under `--json`, because the note is prose and `--json` is the
    /// machine format. A parser that had to strip a sentence off stderr would be
    /// parsing prose.
    @Test func jsonSuppressesTheScopeHint() throws {
        let lines = Rendering.render(result(panes: [record("pane-1")]), for: try call("list", "--json"))
        #expect(!lines.contains { $0.stream == .err })
    }

    // MARK: The stream split, verb by verb

    @Test func publishPutsTheTicketOnStdoutAndTheExplanationOnStderr() throws {
        let lines = Rendering.render(result(rendezvous: "a-rendezvous-value"), for: try call("publish"))
        let out = lines.filter { $0.stream == .out }
        #expect(out.count == 1)
        #expect(out.first?.text == "a-rendezvous-value")
        #expect(lines.contains { $0.stream == .err && $0.text.contains("confers no control") })
    }

    @Test func recvPutsBodiesOnStdoutAndTheDropCounterOnStderr() throws {
        let received = result(messages: [ControlMessage(from: "pane-2", text: "ready")], dropped: 2)
        let lines = Rendering.render(received, for: try call("recv"))
        #expect(lines.filter { $0.stream == .out }.map(\.text) == ["from pane-2", "ready", ""])
        let note = try #require(lines.first { $0.stream == .err })
        #expect(note.text.contains("2 messages were dropped"))
    }

    /// One dropped message is singular. A counter that said "1 messages" is the
    /// kind of thing a reader stops trusting the rest of.
    @Test func oneDroppedMessageIsReportedInTheSingular() throws {
        let lines = Rendering.render(result(dropped: 1), for: try call("recv"))
        #expect(lines.contains { $0.stream == .err && $0.text.contains("1 message was dropped") })
    }

    /// A drop counter of zero is not news, and printing it every time is how a
    /// note stops being read.
    @Test func aRecvThatDroppedNothingSaysNothing() throws {
        let lines = Rendering.render(result(dropped: 0), for: try call("recv"))
        #expect(lines.isEmpty)
    }

    @Test func peersSaysSoOnStderrWhenThereAreNone() throws {
        let lines = Rendering.render(result(panes: []), for: try call("peers"))
        #expect(lines.allSatisfy { $0.stream == .err })
        #expect(lines.first?.text.contains("baia publish mints a ticket") == true)
    }

    @Test func zoomPrintsTheStateItEndedIn() throws {
        #expect(rendered("zoom", result(zoomed: true)) == ["on"])
        #expect(rendered("zoom", result(zoomed: false)) == ["off"])
        // An answer with no state in it is not a zoom that succeeded silently.
        #expect(rendered("zoom", result()) == ["off"])
    }

    @Test func splitPrintsTheNewPaneAndTheSilentVerbsPrintNothing() throws {
        #expect(rendered("split", result(pane: "pane-2")) == ["pane-2"])
        for verb in ["close", "focus", "equalize", "run"] {
            #expect(Rendering.render(result(pane: "pane-2"), for: try call(verb)).isEmpty)
        }
    }

    @Test func connectPrintsThePeerAndTheChannelNameWhenThereIsOne() throws {
        #expect(rendered("connect", result(pane: "pane-2", name: "review")) == ["pane-2 review"])
        #expect(rendered("connect", result(pane: "pane-2")) == ["pane-2"])
        #expect(rendered("connect", result()) == [])
    }

    // MARK: Observation

    /// One line per event, fields separated by spaces, so `while read` splits it
    /// without a JSON parser. The cursor is last and on stdout, because it is the
    /// one value the next call needs and a script reads it with `tail -1`.
    @Test func subscribePrintsOneLinePerEventAndTheCursorLast() throws {
        let received = result(
            events: [
                ControlEvent(seq: 42, kind: .attentionRaised, pane: "pane-1", message: "needs input"),
                ControlEvent(seq: 43, kind: .paneClosed, pane: "pane-2"),
            ],
            gap: false,
            seq: 43
        )
        let lines = Rendering.render(received, for: try call("subscribe", "--from", "0"))
        let out = lines.filter { $0.stream == .out }.map(\.text)
        #expect(out.contains("42 attentionRaised pane-1 needs input"))
        #expect(out.contains("43 paneClosed pane-2"))
        #expect(out.last == "seq 43")
    }

    /// The source is marked and sits before the text it qualifies, so a reader
    /// taking everything after `via osc` has the message and knows what it is
    /// worth. Unmarked it would be indistinguishable from the free text.
    @Test func aRaiseNamesWhereItCameFrom() throws {
        let received = result(
            events: [
                ControlEvent(
                    seq: 42, kind: .attentionRaised, pane: "pane-1",
                    message: "needs input", source: .osc
                ),
                ControlEvent(seq: 43, kind: .attentionCleared, pane: "pane-1"),
            ],
            gap: false,
            seq: 43
        )
        let lines = Rendering.render(received, for: try call("subscribe", "--from", "0"))
        let out = lines.filter { $0.stream == .out }.map(\.text)
        #expect(out.contains("42 attentionRaised pane-1 via osc needs input"))
        // A clear has one possible source and names none.
        #expect(out.contains("43 attentionCleared pane-1"))
    }

    /// A gap goes to stderr, so `baia subscribe > log` carries events while a
    /// re-bootstrap warning still reaches a human.
    @Test func aGapIsReportedOnStandardError() throws {
        let lines = Rendering.render(
            result(events: [], gap: true, seq: 600), for: try call("subscribe", "--from", "0")
        )
        let errors = lines.filter { $0.stream == .err }.map(\.text)
        #expect(errors.contains { $0.contains("baia list") })
        #expect(lines.filter { $0.stream == .out }.map(\.text) == ["seq 600"])
    }

    @Test func moreTellsTheReaderToPollAgain() throws {
        let received = result(
            more: true,
            events: [ControlEvent(seq: 1, kind: .paneOpened, pane: "pane-1")],
            gap: false,
            seq: 1
        )
        let lines = Rendering.render(received, for: try call("subscribe", "--from", "0"))
        let errors = lines.filter { $0.stream == .err }.map(\.text)
        #expect(errors.contains { $0.contains("more") })
    }

    /// `createdBy` and `activity` ride on the same line rather than on lines of
    /// their own, so one event is one record however many fields it carries.
    @Test func anEventCarriesItsCreatorAndItsActivityOnTheSameLine() throws {
        let received = result(
            events: [
                ControlEvent(seq: 7, kind: .paneOpened, pane: "pane-2", createdBy: "pane-1"),
                ControlEvent(seq: 8, kind: .activityChanged, pane: "pane-2", activity: "claude"),
            ],
            gap: false,
            seq: 8
        )
        let out = Rendering.render(received, for: try call("subscribe", "--from", "0"))
            .filter { $0.stream == .out }.map(\.text)
        #expect(out.contains("7 paneOpened pane-2 by pane-1"))
        #expect(out.contains("8 activityChanged pane-2 claude"))
    }

    // MARK: The tree

    /// A pane whose `createdBy` names something outside the returned set is a root
    /// here, which is the ordinary case for the caller itself: the pane that
    /// created it is not in the caller's own scope.
    @Test func theTreeIndentsChildrenUnderTheParentThatIsPresent() throws {
        let records = [
            record("pane-1", createdBy: "pane-0"),
            record("pane-2", createdBy: "pane-1"),
            record("pane-3", createdBy: "pane-2"),
        ]
        let lines = Rendering.render(result(panes: records), for: try call("list", "--tree"))
        #expect(lines.map(\.text) == ["pane-1", "  pane-2", "    pane-3"])
    }

    /// The graph cannot hold a cycle, and a renderer that hung a pane's shell if
    /// it ever did is not worth the four lines saved. Everything a cycle would
    /// have hidden is still printed, flat.
    @Test func theTreeTerminatesOnACycleAndPrintsEveryRecordAnyway() throws {
        let records = [
            record("pane-1", createdBy: "pane-2"),
            record("pane-2", createdBy: "pane-1"),
        ]
        let lines = Rendering.render(result(panes: records), for: try call("list", "--tree"))
        #expect(Set(lines.map { $0.text.trimmingCharacters(in: .whitespaces) }) == ["pane-1", "pane-2"])
    }

    // MARK: Layout documents

    /// **The output of `layout export` is the document and nothing else**, which
    /// is the whole reason `baia layout export > dev.json` produces a file
    /// `baia layout apply` reads back. A note on stdout here would land in the
    /// middle of somebody's committed layout.
    @Test func exportPrintsTheDocumentAndOnlyTheDocument() throws {
        let layout = ControlLayout(tabs: [
            .split(
                axis: .horizontal,
                ratio: 0.5,
                first: .pane(cwd: "/Users/x/Projects/baia"),
                second: .pane(cwd: nil)
            ),
        ])
        let lines = Rendering.render(
            ControlResult(layout: layout),
            for: try call("layout", "export")
        )
        #expect(lines.allSatisfy { $0.stream == .out })

        let text = lines.map(\.text).joined(separator: "\n")
        let decoded = try JSONDecoder().decode(
            ControlLayout.self,
            from: Data(text.utf8)
        )
        #expect(decoded == layout, "what export printed did not read back as the same document")
    }

    /// Slashes unescaped, because a path full of `\/` is a document nobody wants
    /// to read in a diff.
    @Test func anExportedPathIsWrittenTheWayItIsSpelled() throws {
        let lines = Rendering.render(
            ControlResult(layout: ControlLayout(tabs: [.pane(cwd: "/Users/x/Projects/baia")])),
            for: try call("layout", "export")
        )
        let text = lines.map(\.text).joined(separator: "\n")
        #expect(text.contains("/Users/x/Projects/baia"))
        #expect(text.contains("\\/") == false)
    }

    /// An export the app could not answer prints nothing rather than an empty
    /// document. A `{}` on stdout would be a file that applies to no panes and
    /// looks like a successful capture.
    @Test func exportWithNoLayoutInTheAnswerPrintsNothing() throws {
        #expect(Rendering.render(ControlResult(), for: try call("layout", "export")).isEmpty)
    }

    /// `apply` prints nothing at all: every id it could report is in
    /// `baia list --tree`, which is where a script has to look anyway because it
    /// needs the records to tell the new panes apart.
    @Test func applyPrintsNothingOnEitherStream() throws {
        #expect(Rendering.render(ControlResult(), for: try call("layout", "apply")).isEmpty)
    }

    // MARK: Fixtures

    private func rendered(_ verb: String, _ result: ControlResult) -> [String] {
        guard case let .invoke(call) = Arguments.parse([verb]) else { return [] }
        return Rendering.render(result, for: call).map(\.text)
    }

    /// Built through the parser rather than by hand, so a rendering test cannot
    /// pass against an invocation the CLI would never produce.
    private func call(_ argv: String...) throws -> Invocation {
        guard case let .invoke(call) = Arguments.parse(argv) else {
            throw RenderingFixtureError.notAnInvocation(argv.joined(separator: " "))
        }
        return call
    }

    private func record(
        _ pane: String,
        createdBy: String? = nil,
        peers: [String] = []
    ) -> PaneRecord {
        PaneRecord(pane: pane, window: 1, tab: 1, createdBy: createdBy, peers: peers)
    }

    private func result(
        panes: [PaneRecord]? = nil,
        pane: String? = nil,
        name: String? = nil,
        rendezvous: String? = nil,
        zoomed: Bool? = nil,
        messages: [ControlMessage]? = nil,
        more: Bool? = nil,
        dropped: Int? = nil,
        events: [ControlEvent]? = nil,
        gap: Bool? = nil,
        seq: UInt64? = nil
    ) -> ControlResult {
        ControlResult(
            pane: pane,
            name: name,
            rendezvous: rendezvous,
            zoomed: zoomed,
            panes: panes,
            messages: messages,
            more: more,
            dropped: dropped,
            events: events,
            gap: gap,
            seq: seq
        )
    }

    private enum RenderingFixtureError: Error {
        case notAnInvocation(String)
    }
}
