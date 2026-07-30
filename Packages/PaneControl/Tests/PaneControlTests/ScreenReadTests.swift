import Foundation
import Testing

@testable import PaneControl

/// Which of a pane's lines a `read` answers with.
@Suite struct ScreenReadTests {
    private func lines(_ count: Int) -> [String] {
        (1...count).map { "line \($0)" }
    }

    // MARK: The tail

    /// **The tail, not the head.** A caller reading a pane wants what it just did.
    @Test func theNewestLinesAreTheOnesKept() {
        let result = ScreenRead.tail(lines(100), limit: 3)
        #expect(result.lines == ["line 98", "line 99", "line 100"])
    }

    @Test func orderIsPreserved() {
        let result = ScreenRead.tail(lines(5), limit: 5)
        #expect(result.lines == ["line 1", "line 2", "line 3", "line 4", "line 5"])
    }

    /// A pane shorter than the ask is not a truncated read, and must not say it
    /// is: a caller that cannot tell a short pane from a cut one will conclude the
    /// wrong thing in both directions.
    @Test func aShortPaneIsNotTruncated() {
        let result = ScreenRead.tail(lines(3), limit: 50)
        #expect(result.lines.count == 3)
        #expect(result.truncated == false)
    }

    @Test func moreLinesThanAskedForIsTruncated() {
        #expect(ScreenRead.tail(lines(100), limit: 10).truncated)
    }

    @Test func anEmptyPaneAnswersNothingAndIsNotTruncated() {
        let result = ScreenRead.tail([], limit: 50)
        #expect(result.lines.isEmpty)
        #expect(result.truncated == false)
    }

    // MARK: The limit

    @Test func anAbsentLimitTakesTheDefault() {
        #expect(ScreenRead.tail(lines(500), limit: nil).lines.count == ScreenRead.defaultLines)
    }

    @Test func anOversizedLimitIsCappedRatherThanRefused() {
        let result = ScreenRead.tail(lines(5000), limit: 999_999)
        #expect(result.lines.count == ScreenRead.maxLines)
        #expect(result.truncated)
    }

    /// Zero lines is a caller asking for nothing, answered with nothing. It says
    /// truncated only when there was something to leave out.
    @Test func zeroIsAnsweredWithNothing() {
        #expect(ScreenRead.tail(lines(10), limit: 0).lines.isEmpty)
        #expect(ScreenRead.tail(lines(10), limit: 0).truncated)
        #expect(ScreenRead.tail([], limit: 0).truncated == false)
    }

    @Test func aNegativeLimitIsTreatedAsZero() {
        #expect(ScreenRead.tail(lines(10), limit: -5).lines.isEmpty)
    }

    // MARK: The budget

    /// **Dropped from the front.** The newest line is the one worth keeping, so
    /// the oldest go first and what survives keeps its order.
    @Test func theBudgetDropsTheOldestFirst() {
        // Lines 1 to 9 are 100 bytes, line 10 is 101, and each costs a newline on
        // top. Newest first: 102, then 203, and the third would be 304.
        let wide = (1...10).map { "\($0)" + String(repeating: "x", count: 99) }
        let result = ScreenRead.tail(wide, limit: 10, budget: 300)
        #expect(result.lines.count == 2)
        #expect(result.lines.last?.hasPrefix("10") == true)
        #expect(result.lines.first?.hasPrefix("9") == true)
        #expect(result.truncated)
    }

    /// **A line bigger than the whole budget is cut, not dropped.** Dropping it
    /// would answer with nothing and make a busy pane look idle.
    @Test func oneEnormousLineIsCutRatherThanDropped() {
        let huge = String(repeating: "x", count: 5000)
        let result = ScreenRead.tail([huge], limit: 10, budget: 100)
        #expect(result.lines.count == 1)
        #expect(result.lines[0].utf8.count <= 100)
        #expect(result.truncated)
    }

    /// The cut lands on a scalar boundary, or the response carries bytes no JSON
    /// encoder will emit and the whole frame becomes unsendable.
    @Test func aCutLineLandsOnAScalarBoundary() {
        // Three-byte scalars against a budget that is not a multiple of three.
        let huge = String(repeating: "\u{4E00}", count: 200)
        let result = ScreenRead.tail([huge], limit: 1, budget: 100)
        guard let only = result.lines.first else {
            Issue.record("nothing came back")
            return
        }
        #expect(only.utf8.count == 99)
        #expect(only.count == 33)
        #expect(String(data: Data(only.utf8), encoding: .utf8) != nil)
    }

    /// The budget counts the newline the caller will put back, so a payload
    /// measured here cannot exceed what a caller reassembles.
    @Test func theBudgetCountsTheSeparators() {
        let result = ScreenRead.tail(["ab", "cd", "ef"], limit: 3, budget: 6)
        #expect(result.lines == ["cd", "ef"])
    }

    /// Well under the frame, because the frame carries the envelope and every
    /// line's JSON escaping as well as the lines.
    @Test func theBudgetSitsUnderTheFrame() {
        #expect(ScreenRead.maxBytes < ControlWire.maxFrameBytes)
    }
}
