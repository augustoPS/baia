import Testing

@testable import PaneSearch

@Suite struct TerminalRowsTests {
    /// The rule the row arithmetic rests on: a terminal wraps on cells, and a
    /// CJK character is two of them. Counting characters instead loses a row per
    /// wide character, which is the drift that sent the pane to the wrong place.
    @Test func awideCharacterIsTwoCells() {
        #expect(TerminalRows.cells(of: "a") == 1)
        #expect(TerminalRows.cells(of: "\u{6F22}") == 2)
        #expect(TerminalRows.cells(of: "\u{FF21}") == 2)
        #expect(TerminalRows.cells(of: "\u{1F600}") == 2)
        // Emoji presentation of a character that is narrow without it.
        #expect(TerminalRows.cells(of: "\u{2600}\u{FE0F}") == 2)
        // A grapheme is one unit however many scalars it carries.
        #expect(TerminalRows.cells(of: "e\u{0301}") == 1)
        #expect(TerminalRows.cells(of: "\u{00E9}") == 1)
    }

    /// 60 CJK characters is 120 cells, so an 80 column pane draws them as two
    /// rows. The character count says one.
    @Test func rowSpanCountsCellsNotCharacters() {
        let cjk = String(repeating: "\u{6F22}", count: 60)
        #expect(TerminalRows.rowSpan(of: cjk, columns: 80) == 2)
        #expect(cjk.count == 60)
    }

    /// A line that exactly fills the row does not wrap. The wrap is charged to
    /// the character that does not fit, and there is none.
    @Test func alineOfExactlyTheWidthStaysOnOneRow() {
        #expect(TerminalRows.rowSpan(of: String(repeating: "x", count: 80), columns: 80) == 1)
        #expect(TerminalRows.rowSpan(of: String(repeating: "x", count: 81), columns: 80) == 2)
        #expect(TerminalRows.rowSpan(of: String(repeating: "x", count: 160), columns: 80) == 2)
        #expect(TerminalRows.rowSpan(of: String(repeating: "x", count: 161), columns: 80) == 3)
    }

    /// A wide character with one cell left moves to the next row whole, leaving
    /// the last cell blank, so 40 wide characters after 79 narrow ones is not
    /// the same as 80 cells of anything.
    @Test func awideCharacterThatDoesNotFitMovesWhole() {
        let line = String(repeating: "x", count: 79) + "\u{6F22}"
        #expect(TerminalRows.rowSpan(of: line, columns: 80) == 2)
    }

    @Test func anEmptyLineIsStillOneRow() {
        #expect(TerminalRows.rowSpan(of: "", columns: 80) == 1)
    }

    /// A tab advances to the next multiple of eight, not by one, so a line of
    /// tabs wraps far sooner than its character count suggests.
    @Test func atabAdvancesToTheNextStop() {
        #expect(TerminalRows.rowSpan(of: String(repeating: "\t", count: 10), columns: 80) == 1)
        #expect(TerminalRows.rowSpan(of: String(repeating: "\t", count: 11), columns: 80) == 2)
    }

    /// The row a match sits on is the sum of the spans above it plus the wraps
    /// crossed inside its own line, which is what makes the confirmation read
    /// land on the first try instead of walking back a row at a time.
    @Test func theRowOfAmatchSumsTheSpansAboveIt() {
        let lines = [
            String(repeating: "\u{6F22}", count: 60), // 2 rows
            "short", // 1 row
            String(repeating: "x", count: 200), // 3 rows
            "needle here",
        ]
        #expect(TerminalRows.row(ofLine: 3, offset: 0, in: lines, columns: 80) == 6)
        // A hit 150 characters into the third line is on that line's second row.
        #expect(TerminalRows.row(ofLine: 2, offset: 150, in: lines, columns: 80) == 4)
        #expect(TerminalRows.row(ofLine: 0, offset: 0, in: lines, columns: 80) == 0)
    }

    /// A line index past the end reports the row after everything, rather than
    /// trapping. The lines and the index come from the same read, so this is a
    /// guard and not a case.
    @Test func anIndexPastTheEndDoesNotTrap() {
        #expect(TerminalRows.row(ofLine: 9, offset: 0, in: ["a", "b"], columns: 80) == 2)
        #expect(TerminalRows.row(ofLine: 0, offset: 0, in: [], columns: 80) == 0)
    }

    /// Zero columns is the pane before its surface has reported a size. It has
    /// no rows to speak of, and the caller treats the answer as unusable.
    @Test func zeroColumnsIsNotAdivisionByZero() {
        #expect(TerminalRows.rowSpan(of: "anything", columns: 0) == 1)
        #expect(TerminalRows.row(ofLine: 1, offset: 0, in: ["a", "b"], columns: 0) == 0)
    }
}
