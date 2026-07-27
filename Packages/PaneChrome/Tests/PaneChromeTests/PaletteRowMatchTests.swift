import Testing

@testable import PaneChrome

@Suite struct PaletteRowMatchTests {
    @Test func theProjectIsTheParentAndTheLineIsTheName() {
        let row = PaletteRow.match(line: "build failed", highlight: 6 ..< 12, project: "baia")
        #expect(row.parent.map(\.text).joined() == "baia ")
        #expect(row.name.map(\.text).joined() == "build failed")
        #expect(row.chip == nil)
    }

    /// The hit is the only thing on the row drawn at full strength, so the eye
    /// lands on it rather than on the line it sits in.
    @Test func onlyTheHitIsEmphasised() {
        let row = PaletteRow.match(line: "aXXXb", highlight: 1 ..< 4, project: "p")
        #expect(row.name.map(\.text) == ["a", "XXX", "b"])
        #expect(row.name.map(\.emphasis) == [.faint, .strong, .faint])
    }

    /// A hit at either end must not produce an empty leading or trailing run.
    /// An empty run costs a measurement and an attribute range on every row and
    /// draws nothing.
    @Test func ahitAtTheEdgesProducesNoEmptyRuns() {
        let leading = PaletteRow.match(line: "abc", highlight: 0 ..< 1, project: "p")
        #expect(leading.name.map(\.text) == ["a", "bc"])

        let trailing = PaletteRow.match(line: "abc", highlight: 2 ..< 3, project: "p")
        #expect(trailing.name.map(\.text) == ["ab", "c"])

        let whole = PaletteRow.match(line: "abc", highlight: 0 ..< 3, project: "p")
        #expect(whole.name.map(\.text) == ["abc"])
    }

    /// Terminal output arrives with whatever indentation the program chose, and
    /// a row of leading spaces wastes the width the line needs. Trimmed for
    /// display only; the offsets are corrected to match.
    @Test func leadingWhitespaceIsTrimmedAndTheHitMovesWithIt() {
        let row = PaletteRow.match(line: "      needle", highlight: 6 ..< 12, project: "p")
        #expect(row.name.map(\.text) == ["needle"])
        #expect(row.name.map(\.emphasis) == [.strong])
    }

    /// A range outside the line cannot render. It should degrade to the plain
    /// line rather than trapping inside a draw call.
    @Test func anOutOfBoundsRangeDegradesToThePlainLine() {
        let row = PaletteRow.match(line: "abc", highlight: 5 ..< 9, project: "p")
        #expect(row.name.map(\.text) == ["abc"])
        #expect(row.name.map(\.emphasis) == [.faint])
    }

    /// Grapheme clusters, because the offsets come from `PaneSearch` as
    /// character offsets and a flag emoji is one character of several scalars.
    /// `🇧🇷 needle` is 8 characters, 9 scalars and 11 UTF-16 units, so the hit
    /// starts at 2 here and at 3 or 5 under the other two counts. Splitting on
    /// the wrong one draws a broken box where the flag was.
    @Test func offsetsAreCharacterOffsets() {
        let row = PaletteRow.match(line: "🇧🇷 needle", highlight: 2 ..< 8, project: "p")
        #expect(row.name.map(\.text) == ["🇧🇷 ", "needle"])
    }

    /// A row is not a line. The screen read returns logical lines, so a minified
    /// bundle or a base64 blob arrives as one line of hundreds of kilobytes, and
    /// putting all of it in a row costs a copy per hit and a text measurement per
    /// draw for a row a hundred characters wide.
    @Test func alongLineIsCutDownToArow() {
        let line = String(repeating: "x", count: 5_000) + "needle" + String(repeating: "y", count: 5_000)
        let row = PaletteRow.match(line: line, highlight: 5_000 ..< 5_006, project: "p")
        let drawn = row.name.map(\.text).joined()
        #expect(drawn.count <= 402)
        #expect(row.name.map(\.emphasis) == [.faint, .strong, .faint])
        #expect(row.name[1].text == "needle")
        #expect(drawn.hasPrefix("\u{2026}"))
        #expect(drawn.hasSuffix("\u{2026}"))
        // The hit keeps its context on both sides rather than landing on an edge.
        #expect(row.name[0].text.count == 81)
    }

    /// A hit near the start of a long line keeps the start, so the row still
    /// begins where the line does and only the tail is cut.
    @Test func ahitNearTheStartKeepsTheStartOfTheLine() {
        let line = "needle " + String(repeating: "y", count: 5_000)
        let row = PaletteRow.match(line: line, highlight: 0 ..< 6, project: "p")
        let drawn = row.name.map(\.text).joined()
        #expect(row.name.first?.text == "needle")
        #expect(row.name.first?.emphasis == .strong)
        #expect(drawn.hasPrefix("needle"))
        #expect(drawn.hasSuffix("\u{2026}"))
        #expect(drawn.count <= 401)
    }

    /// A line that fits, with its hit near the start, comes through whole: the
    /// window is a bound, not a reformat.
    @Test func alineThatFitsIsLeftAlone() {
        let line = "a needle in " + String(repeating: "x", count: 300)
        let row = PaletteRow.match(line: line, highlight: 2 ..< 8, project: "p")
        #expect(row.name.map(\.text).joined() == line)
        #expect(row.name.map(\.text) == ["a ", "needle", " in " + String(repeating: "x", count: 300)])
    }

    /// A hit past the width the panel can draw moves into view, which is the
    /// other half of the window: a row showing the first 100 characters of a
    /// line whose hit is at character 300 shows the reader nothing.
    @Test func ahitLateInAshortLineIsBroughtIntoView() {
        let line = String(repeating: "x", count: 300) + "needle"
        let row = PaletteRow.match(line: line, highlight: 300 ..< 306, project: "p")
        #expect(row.name.map(\.text) == ["\u{2026}" + String(repeating: "x", count: 80), "needle"])
    }
}
