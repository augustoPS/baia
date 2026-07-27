import Foundation

public extension PaletteRow {
    /// A find result: the project it came from, then the matching line with the
    /// hit picked out.
    ///
    /// Separate from ``PaletteRow/make(relativePath:matchedIndices:kind:)``
    /// rather than a parameter on it. That factory splits on the last `/` to
    /// tell a path's parent from its name, and terminal output is full of
    /// slashes that mean nothing of the sort, so reusing it would cut a log line
    /// at whatever slash happened to be last.
    ///
    /// The line is drawn faint with the hit at ``PaneStatusEmphasis/strong``, so
    /// the eye lands on what was searched for rather than on the noise around
    /// it. That is the reverse of a palette row, where the name is the point and
    /// the match is a hint.
    static func match(line: String, highlight: Range<Int>, project: String) -> PaletteRow {
        let window = window(of: line, around: highlight)

        return PaletteRow(
            parent: [PaneStatusRun(text: project + " ", emphasis: .context)],
            name: runs(in: window.text, highlight: window.highlight),
            chip: nil
        )
    }

    /// The part of the line the row shows, with the hit's offsets moved to
    /// match, and an ellipsis wherever something was cut.
    ///
    /// A row is not a line. The screen read returns logical lines, so a `cat` of
    /// a minified bundle is one line of hundreds of kilobytes, and a hit in it
    /// used to put the whole thing in the row: copying the line into an array of
    /// characters per hit cost 0.56 seconds for 200 rows of an 80,000 character
    /// line, on every keystroke, to draw a row 100 characters wide.
    ///
    /// Leading whitespace goes with it. Indentation is the program's, not the
    /// owner's, and a row that spends a third of its width on it has less room
    /// for the part being read. Trimmed only when the window starts at the line
    /// start, since anywhere else the whitespace is content.
    private static func window(
        of line: String,
        around highlight: Range<Int>
    ) -> (text: [Character], highlight: Range<Int>) {
        let start = max(0, highlight.lowerBound - Self.contextBefore)
        let end = max(highlight.upperBound, start + Self.maxRowLength)

        var text: [Character] = []
        var cutAtEnd = false
        for (offset, character) in line.enumerated() {
            if offset < start { continue }
            if offset >= end {
                cutAtEnd = true
                break
            }
            text.append(character)
        }

        var dropped = start
        if start == 0 {
            let indent = text.prefix { $0 == " " || $0 == "\t" }.count
            text.removeFirst(indent)
            dropped = indent
        } else {
            text.insert(Self.ellipsis, at: 0)
            dropped -= 1
        }
        if cutAtEnd { text.append(Self.ellipsis) }

        return (text, (highlight.lowerBound - dropped) ..< (highlight.upperBound - dropped))
    }

    /// Splits the line into at most three runs: before, the hit, and after.
    ///
    /// Empty runs are dropped rather than emitted. Each one costs a measurement
    /// and an attribute range on every row of every keystroke and draws nothing,
    /// and a hit at either edge would produce one every time.
    private static func runs(
        in characters: [Character],
        highlight: Range<Int>
    ) -> [PaneStatusRun] {
        // A range the line cannot satisfy degrades to the plain line. The
        // alternative is a trap inside a draw call, and the offsets crossing
        // from `PaneSearch` are the kind of thing that goes wrong once.
        guard highlight.lowerBound >= 0,
              highlight.upperBound <= characters.count,
              highlight.lowerBound < highlight.upperBound
        else {
            return [PaneStatusRun(text: String(characters), emphasis: .faint)]
        }

        var runs: [PaneStatusRun] = []
        let before = String(characters[0 ..< highlight.lowerBound])
        let hit = String(characters[highlight])
        let after = String(characters[highlight.upperBound ..< characters.count])

        if !before.isEmpty { runs.append(PaneStatusRun(text: before, emphasis: .faint)) }
        runs.append(PaneStatusRun(text: hit, emphasis: .strong))
        if !after.isEmpty { runs.append(PaneStatusRun(text: after, emphasis: .faint)) }
        return runs
    }

    /// Characters kept before the hit, and the whole row's budget. Both are
    /// larger than the 720 point panel can draw, so the cut is never visible on
    /// a line anyone reads; they exist for the lines nobody meant to print.
    private static var contextBefore: Int { 80 }

    private static var maxRowLength: Int { 400 }

    private static var ellipsis: Character { "\u{2026}" }
}
