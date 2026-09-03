import Foundation
import Testing

@testable import PaneControl

@Suite struct PaneExplanationTests {
    private func sample(
        matched: String = "claude", message: String? = "which branch?", reason: String = "why"
    ) -> PaneExplanation {
        PaneExplanation(
            pane: "PANE-1",
            hasForeground: true,
            processes: [
                PaneExplanation.Process(pid: 100, parentPid: 10, depth: 0, matched: nil, verdict: "pane shell", won: false),
                PaneExplanation.Process(pid: 200, parentPid: 100, depth: 1, matched: matched, verdict: "agent", won: true),
            ],
            activity: "claude",
            activityReading: "running",
            activityReason: reason,
            report: PaneExplanation.Report(state: .blocked, message: message, seq: 17, live: true, secondsLeft: 240),
            latch: "none",
            seen: false,
            attention: "asking",
            attentionDecidedBy: "report",
            attentionReason: reason
        )
    }

    /// Four of the strings are chosen by whoever runs in the pane: the token, the
    /// message, and the two reasons that quote them. Flattened at init, the rule
    /// `PaneRecord` follows, so no renderer has to know which ones.
    @Test func everyPaneNamedStringIsOneLine() {
        let e = sample(matched: "cla\nude", message: "a\nb", reason: "x\ny")
        #expect(e.processes[1].matched?.contains("\n") == false)
        #expect(e.report?.message?.contains("\n") == false)
        #expect(e.activityReason.contains("\n") == false)
        #expect(e.attentionReason.contains("\n") == false)
    }

    @Test func itRoundTripsThroughTheWire() throws {
        let e = sample()
        let data = try JSONEncoder().encode(ControlResult(explanation: e))
        let back = try JSONDecoder().decode(ControlResult.self, from: data)
        #expect(back.explanation == e)
    }

    /// `secondsLeft` is what a reader acts on; a negative one is a report that
    /// expired, which `live` already says.
    @Test func secondsLeftIsNeverNegative() {
        let r = PaneExplanation.Report(state: .idle, message: nil, seq: nil, live: false, secondsLeft: -5)
        #expect(r.secondsLeft == 0)
    }
}
