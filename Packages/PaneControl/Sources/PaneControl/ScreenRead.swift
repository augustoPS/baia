import Foundation

/// Choosing which of a pane's lines a `read` answers with, and cutting them to a
/// budget.
///
/// **Pure, and here rather than in the app, for the reason every rule in this
/// package is.** Getting the lines needs a live surface and stays in
/// `TerminalPaneController`; deciding which of them fit needs nothing but the
/// lines, and the app target has no test target.
public enum ScreenRead {
    /// What a read answers with.
    public struct Result: Sendable, Equatable {
        public var lines: [String]

        /// True when either bound bit: the line count, or the byte budget.
        ///
        /// **One flag for both, and it is not laziness.** A caller cannot act on
        /// the difference: either way there was more and it did not arrive, and
        /// asking again gets the same answer. What a caller must not do is
        /// mistake a short pane for a truncated read, and one honest flag
        /// prevents that in both directions.
        public var truncated: Bool

        public init(lines: [String], truncated: Bool) {
            self.lines = lines
            self.truncated = truncated
        }
    }

    /// How many lines a read answers with when it asks for no number.
    public static let defaultLines = 50

    /// The most a read may ask for.
    ///
    /// The frame budget is the real bound and this sits under it, so an ordinary
    /// read is answered by count and only an extraordinary one meets the byte
    /// cap. Two bounds rather than one because a thousand short lines and one
    /// enormous line are different failures and a single number answers only one.
    public static let maxLines = 2000

    /// The bytes a read's payload may occupy.
    ///
    /// Well under ``ControlWire/maxFrameBytes``, because the frame carries the
    /// envelope and the JSON escaping of every line as well as the lines, and a
    /// payload measured to the frame's own limit would be the thing that made the
    /// frame unsendable.
    public static let maxBytes = 48 * 1024

    /// The last `limit` lines that fit in the budget, newest kept first.
    ///
    /// **The tail rather than the head.** A caller reading a pane wants what it
    /// just did, and a read that answered with the oldest lines in the scrollback
    /// would be useless for the case the verb exists for.
    ///
    /// **Dropped from the front when the budget bites**, for the same reason.
    /// The newest line is the one worth keeping, so the oldest go first and the
    /// order of what survives is unchanged.
    public static func tail(_ lines: [String], limit: Int?, budget: Int = maxBytes) -> Result {
        let wanted = min(max(limit ?? defaultLines, 0), maxLines)
        guard wanted > 0 else { return Result(lines: [], truncated: lines.isEmpty == false) }

        var kept = Array(lines.suffix(wanted))
        var truncated = kept.count < lines.count

        // Newest backwards, so the budget is spent on what the caller came for.
        var used = 0
        var fitted: [String] = []
        for line in kept.reversed() {
            let width = line.utf8.count + 1  // the newline the caller will re-add
            if used + width > budget {
                // A single line larger than the whole budget is cut rather than
                // dropped, or a pane holding one enormous line would answer with
                // nothing at all and look idle.
                if fitted.isEmpty {
                    fitted.append(clipped(line, to: budget))
                }
                truncated = true
                break
            }
            used += width
            fitted.append(line)
        }
        kept = fitted.reversed()
        return Result(lines: kept, truncated: truncated)
    }

    /// Cuts a line to a byte budget on a scalar boundary.
    ///
    /// **The boundary rule is load-bearing.** `String` is UTF-8 underneath and a
    /// cut through a multi-byte scalar yields bytes no JSON encoder will emit, so
    /// a naive truncation would be the very thing that made the response
    /// unsendable. The same argument ``ControlEvent/capped(_:)`` makes for the
    /// ring.
    static func clipped(_ line: String, to budget: Int) -> String {
        guard line.utf8.count > budget else { return line }
        var cut = ""
        var used = 0
        for character in line {
            let width = String(character).utf8.count
            guard used + width <= budget else { break }
            cut.append(character)
            used += width
        }
        return cut
    }
}
