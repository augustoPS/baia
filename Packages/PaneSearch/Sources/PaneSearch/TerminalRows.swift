import Foundation

/// The arithmetic that turns a logical line index into a screen row.
///
/// Here rather than in the app target so it runs in the one-second `make test`
/// loop, which is where the wide-character cases belong: they are pure string
/// arithmetic, and the app target can only be exercised against a real surface.
///
/// The whole reason this exists is that the two reads count different things.
/// The screen read returns logical lines, so a 500 character line in a 144
/// column pane is one line; the row read and `scrollToRow` count screen rows, so
/// the same content is four of them. Nothing in the text says where the wraps
/// fell, so they are recomputed here.
public enum TerminalRows {
    /// How many cells a character occupies on screen.
    ///
    /// Cells and not characters, which is the distinction the first version of
    /// this got wrong. A terminal wraps when the cells run out, so counting
    /// characters loses a row for every wide character above the match, and the
    /// error accumulates over the whole scrollback rather than over a screenful:
    /// 200 lines of 60 CJK characters in an 80 column pane put the match 200
    /// rows away from where the arithmetic said. Emoji have the same width and
    /// turn up in ordinary build and test output.
    public static func cells(of character: Character) -> Int {
        // The overwhelming majority of terminal output, taken first so the
        // scrollback walk does not pay for the checks below on every character.
        if character.isASCII {
            guard let scalar = character.unicodeScalars.first else { return 0 }
            return scalar.value >= 0x20 && scalar.value != 0x7F ? 1 : 0
        }

        guard let scalar = character.unicodeScalars.first else { return 0 }

        // The emoji variation selector asks for the emoji presentation of a
        // character that is otherwise narrow, and the emoji presentation is two
        // cells wide. Checked before the base scalar, which is the narrow one.
        if character.unicodeScalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
        if scalar.properties.isEmojiPresentation { return 2 }
        if isWide(scalar.value) { return 2 }

        // A grapheme whose first scalar is a mark hangs off a base that is not
        // there, and draws in no cell of its own.
        return switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format, .control: 0
        default: 1
        }
    }

    /// How many screen rows `line` occupies at `columns` cells wide.
    ///
    /// One for an empty line, because a terminal draws it as one.
    public static func rowSpan(of line: String, columns: Int) -> Int {
        guard columns > 0 else { return 1 }
        return 1 + wrapsCrossed(in: line, columns: columns, before: nil)
    }

    /// The screen row that the character at `offset` of line `index` is drawn
    /// on, counting from the first row of `lines`.
    ///
    /// The offset matters: a match halfway through a soft-wrapped line is
    /// several rows below the row that line starts on, and pointing at the start
    /// costs a read per wrap to walk back to it.
    public static func row(
        ofLine index: Int,
        offset: Int,
        in lines: [String],
        columns: Int
    ) -> Int {
        guard columns > 0 else { return 0 }
        var row = 0
        for line in lines.prefix(max(0, index)) {
            row += rowSpan(of: line, columns: columns)
        }
        guard lines.indices.contains(index) else { return row }
        return row + wrapsCrossed(in: lines[index], columns: columns, before: offset)
    }

    /// How many times the terminal wraps while writing `line`, stopping before
    /// the character at `before` when it is given.
    ///
    /// A character that does not fit in the cells left on the row moves to the
    /// next row whole, which is why the width is tested against the remaining
    /// columns rather than added and taken modulo. A line of exactly `columns`
    /// cells stays on one row: the wrap is charged to the character that does
    /// not fit, and there is none.
    private static func wrapsCrossed(in line: String, columns: Int, before: Int?) -> Int {
        var wraps = 0
        var column = 0
        var index = 0

        for character in line {
            if let before, index >= before { break }
            index += 1

            let width = character == "\t" ? tabAdvance(from: column) : cells(of: character)
            guard width > 0 else { continue }

            if column + width > columns {
                wraps += 1
                column = character == "\t" ? tabAdvance(from: 0) : width
            } else {
                column += width
            }
        }
        return wraps
    }

    /// Cells to the next tab stop. Eight columns, ghostty's default, and the
    /// only reason this is not a width lookup like every other character.
    private static func tabAdvance(from column: Int) -> Int {
        Self.tabStop - column % Self.tabStop
    }

    /// East Asian Wide and Fullwidth, plus the emoji blocks that carry no
    /// presentation property of their own. Ranges rather than a property lookup
    /// because `isEmojiPresentation` covers only part of this and Foundation
    /// exposes no East Asian Width.
    private static func isWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100 ... 0x115F, 0x2E80 ... 0x303E, 0x3041 ... 0x33FF,
             0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xA000 ... 0xA4CF,
             0xA960 ... 0xA97F, 0xAC00 ... 0xD7A3, 0xF900 ... 0xFAFF,
             0xFE10 ... 0xFE19, 0xFE30 ... 0xFE6F, 0xFF00 ... 0xFF60,
             0xFFE0 ... 0xFFE6,
             0x17000 ... 0x18AFF, 0x1B000 ... 0x1B12F, 0x1B150 ... 0x1B2FF,
             0x1F300 ... 0x1F64F, 0x1F900 ... 0x1F9FF, 0x1FA70 ... 0x1FAFF,
             0x20000 ... 0x3FFFD:
            true
        default:
            false
        }
    }

    private static let tabStop = 8
}
