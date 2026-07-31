import AppKit
import PaneChrome

/// What opening a project from the palette should do.
enum PaletteAction: Sendable, Equatable {
    /// Return. A project is usually a second thing to work on rather than a
    /// second view of the thing already in front.
    case newTab

    /// Shift-Return. Opens beside the focused pane, for the case where the two
    /// projects are being worked on together.
    case splitRight
}

/// The palette's query line: a chevron, the field, and the result count.
///
/// An `NSTextField` is used here and would be forbidden thirty points away
/// inside a pane. The rule is not "no controls in baia", it is that
/// `AppTerminalView.performKeyEquivalent` opens with
/// `guard window?.firstResponder === self`, so anything that takes first
/// responder *within a pane's window* disables that pane's key bindings. The
/// palette is a separate panel and is supposed to take the keyboard.
final class PaletteQueryView: NSView {
    let field = PaletteQueryField(frame: .zero)

    var theme: PaneTheme = .darkPastel { didSet { needsDisplay = true } }

    /// Drawn at the trailing edge, for example `3 of 12`.
    var countText: String = "" {
        didSet {
            guard countText != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        field.font = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingHead
        field.cell?.usesSingleLineMode = true
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("baia does not use nibs")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        field.frame = NSRect(
            x: Self.chevronInset + Self.chevronWidth,
            y: (bounds.height - 20) / 2,
            width: bounds.width - Self.chevronInset - Self.chevronWidth - Self.countRoom,
            height: 20
        )
    }

    override func draw(_: NSRect) {
        nsColor(theme.panelBackground).setFill()
        bounds.fill()

        // The same glyph the icon draws and the same one a shell prompt uses.
        // Accent, because it is the one place in the palette that says "type
        // here" and the palette is what has focus.
        draw(
            "\u{276F}",
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            colour: theme.focusedAccent,
            x: Self.chevronInset,
            alignedRight: false
        )

        if !countText.isEmpty {
            draw(
                countText,
                font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
                colour: theme.inkFaint,
                x: bounds.width - Self.chevronInset,
                alignedRight: true
            )
        }

        // The rule under the query, one step below the panel's own border so the
        // query reads as attached to the list rather than as a separate box.
        nsColor(theme.divider).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    private func draw(
        _ text: String,
        font: NSFont,
        colour: RGB,
        x: Double,
        alignedRight: Bool
    ) {
        let string = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: nsColor(colour),
        ])
        let width = Double(string.size().width)
        string.draw(at: NSPoint(
            x: alignedRight ? x - width : x,
            y: (bounds.height - Double(string.size().height)) / 2
        ))
    }

    private func nsColor(_ rgb: RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
    }

    static let height: Double = 44
    private static let chevronInset: Double = 14
    private static let chevronWidth: Double = 16
    private static let countRoom: Double = 74
}

/// The field itself, which exists only to hand the navigation keys back.
final class PaletteQueryField: NSTextField {
    /// Raised for every key the palette steers with, so the controller decides
    /// what they mean rather than the field editor.
    var onCommand: ((Selector) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    /// Escape does not reach `doCommandBy` as reliably as the rest, because
    /// AppKit routes it through `cancelOperation(_:)` on the responder chain
    /// first. Catching it here as well means one path handles it whichever way
    /// it arrives.
    override func cancelOperation(_: Any?) {
        _ = onCommand?(#selector(NSResponder.cancelOperation(_:)))
    }
}

/// The result list, drawn rather than tabulated.
///
/// Not an `NSTableView`. The list is at most a few hundred rows, only eight are
/// visible, and every one of them is a fixed height, so a table view's cell
/// reuse and delegate round trips buy nothing and cost exact control over a row
/// whose whole design is which of its characters are accented.
final class PaletteListView: NSView {
    var theme: PaneTheme = .darkPastel { didSet { needsDisplay = true } }

    /// The rows, already reduced to coloured runs by `PaletteRow`.
    var rows: [PaletteRow] = [] {
        didSet {
            scrollOffset = 0
            needsDisplay = true
        }
    }

    /// Git state for the selected row only, for example `main *`, or nil while it
    /// is still being read.
    ///
    /// One row rather than all of them. State comes from a `git` subprocess per
    /// repository, so a branch on every row would be twelve subprocesses on every
    /// open, before the first keystroke. It also says less than it looks: twelve
    /// rows all reading `main` repeat a fact that distinguishes nothing, which is
    /// the same argument that took `baia — ` off the tab bar.
    var selectedGitRuns: [PaneStatusRun] = [] { didSet { needsDisplay = true } }

    var selection: Int = 0 {
        didSet {
            guard selection != oldValue else { return }
            scrollSelectionIntoView()
            needsDisplay = true
        }
    }

    /// Raised when a row is clicked. The palette closes on a click the same way
    /// it closes on Return.
    var onActivate: ((Int, PaletteAction) -> Void)?

    private var scrollOffset = 0

    override var isFlipped: Bool { true }

    /// Never first responder. The query field keeps the keyboard for the whole
    /// life of the panel, so typing continues to filter while the arrows move
    /// the selection.
    override var acceptsFirstResponder: Bool { false }

    override var canBecomeKeyView: Bool { false }

    override func draw(_: NSRect) {
        nsColor(theme.panelBackground).setFill()
        bounds.fill()

        guard !rows.isEmpty else {
            drawEmptyState()
            return
        }

        for offset in 0 ..< min(Self.visibleRows, rows.count - scrollOffset) {
            let index = scrollOffset + offset
            draw(rows[index], at: offset, selected: index == selection)
        }
    }

    /// `NO MATCHES` rather than a sentence.
    ///
    /// The palette's voice is the footer's: labels, not prose. A sentence here
    /// would be the only prose in the application.
    private func drawEmptyState() {
        let string = NSAttributedString(string: "NO MATCHES", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: nsColor(theme.inkFaint),
            .tracking: 0.66,
        ])
        string.draw(at: NSPoint(x: Self.inset, y: Self.rowHeight / 2 - 6))
    }

    private func draw(_ row: PaletteRow, at offset: Int, selected: Bool) {
        let top = Double(offset) * Self.rowHeight
        let rowRect = NSRect(x: 0, y: top, width: bounds.width, height: Self.rowHeight)

        if selected {
            nsColor(theme.selectedRowBackground).setFill()
            rowRect.fill()
            // The accent is spent on the edge rather than on the fill. A filled
            // row would be the brightest thing on screen while the palette is
            // open, and the palette is a thing you pass through.
            nsColor(theme.focusedAccent).setFill()
            NSRect(x: 0, y: top, width: Self.edgeWidth, height: Self.rowHeight).fill()
        }

        var x = Self.inset
        // The parent path in mono, the name in the proportional system face. The
        // font change is the tier boundary, exactly as it is on the footer, and
        // it is what lets a row still read when the parent is empty.
        x = drawRuns(row.parent, font: Self.parentFont, at: x, top: top)
        x = drawRuns(row.name, font: Self.nameFont, at: x, top: top)

        if let chip = row.chip {
            x = drawChip(chip, at: x + 6, top: top)
        }

        guard selected, !selectedGitRuns.isEmpty else { return }
        drawTrailing(selectedGitRuns, top: top)
    }

    private func drawRuns(_ runs: [PaneStatusRun], font: NSFont, at x: Double, top: Double) -> Double {
        var x = x
        for run in runs {
            let string = NSAttributedString(string: run.text, attributes: [
                .font: font,
                .foregroundColor: nsColor(colour(for: run.emphasis)),
            ])
            string.draw(at: NSPoint(x: x, y: top + baseline(for: font)))
            x += Double(string.size().width)
        }
        return x
    }

    /// The git state, measured from the right edge so it lands in the same column
    /// on every row it appears on.
    private func drawTrailing(_ runs: [PaneStatusRun], top: Double) {
        let strings = runs.map { run in
            NSAttributedString(string: run.text, attributes: [
                .font: Self.parentFont,
                .foregroundColor: nsColor(colour(for: run.emphasis)),
            ])
        }
        let total = strings.reduce(0.0) { $0 + Double($1.size().width) }
        var x = bounds.width - Self.inset - total
        for string in strings {
            string.draw(at: NSPoint(x: x, y: top + baseline(for: Self.parentFont)))
            x += Double(string.size().width)
        }
    }

    /// The same outlined chip the footer draws for `PIN`, at the same weight and
    /// tracking, so `WT` in the palette and `PIN` on the bar are recognisably one
    /// device.
    private func drawChip(_ text: String, at x: Double, top: Double) -> Double {
        let string = NSAttributedString(string: text, attributes: [
            .font: Self.chipFont,
            .foregroundColor: nsColor(theme.inkContext),
            .tracking: Self.chipFont.pointSize * 0.06,
        ])
        let width = Double(string.size().width) + Self.chipPadding * 2
        let box = NSRect(
            x: x + 0.5,
            y: top + (Self.rowHeight - Self.chipHeight) / 2 + 0.5,
            width: width - 1,
            height: Self.chipHeight - 1
        )
        let path = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
        path.lineWidth = 1
        nsColor(theme.inkContext.blended(with: theme.panelBackground, fraction: 0.45)).setStroke()
        path.stroke()
        string.draw(at: NSPoint(
            x: x + Self.chipPadding,
            y: top + (Self.rowHeight - Double(string.size().height)) / 2
        ))
        return x + width
    }

    /// One baseline per row, the way the footer has one baseline per bar. Two
    /// fonts centred independently in a 34 pt row sit a fraction of a point apart
    /// and read as a mistake rather than as a difference.
    private func baseline(for font: NSFont) -> Double {
        Self.baselineFromTop - Double(font.ascender)
    }

    private func colour(for emphasis: PaneStatusEmphasis) -> RGB {
        theme.color(for: emphasis, focused: true, on: theme.panelBackground)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let offset = Int(point.y / Self.rowHeight)
        let index = scrollOffset + offset
        guard rows.indices.contains(index) else { return }
        selection = index
        onActivate?(index, event.modifierFlags.contains(.shift) ? .splitRight : .newTab)
    }

    // MARK: - Scrolling

    /// Keeps the selection on screen by moving the window of visible rows, rather
    /// than by scrolling a clip view. There is no scroller and nothing to drag:
    /// the list is driven from the keyboard and the mouse only ever clicks a row
    /// it can already see.
    private func scrollSelectionIntoView() {
        if selection < scrollOffset {
            scrollOffset = selection
        } else if selection >= scrollOffset + Self.visibleRows {
            scrollOffset = selection - Self.visibleRows + 1
        }
        scrollOffset = max(0, min(scrollOffset, max(0, rows.count - Self.visibleRows)))
    }

    private func nsColor(_ rgb: RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
    }

    /// The height this list wants for `count` rows, which is what sizes the
    /// panel: a palette showing three results should not be a panel with five
    /// rows of empty space under them.
    static func height(forRowCount count: Int) -> Double {
        Double(max(1, min(count, visibleRows))) * rowHeight
    }

    static let visibleRows = 8
    static let rowHeight: Double = 34
    private static let inset: Double = 14
    private static let edgeWidth: Double = 2
    private static let baselineFromTop: Double = 22
    private static let chipPadding: Double = 4
    private static let chipHeight: Double = 13
    private static let parentFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let nameFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let chipFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
}

/// The key hints along the bottom edge.
final class PaletteHintsView: NSView {
    var theme: PaneTheme = .darkPastel { didSet { needsDisplay = true } }

    /// What Return and Shift-Return do in the panel this bar is in, in the state
    /// it is in.
    ///
    /// A property rather than the constant it was, because the find panel reuses
    /// this view and Return means something else there. Left hard-coded, the
    /// find panel's footer offered "new tab" and "split right" under a list of
    /// search hits, which is worse than no footer: a hint that names the wrong
    /// action is read once and believed.
    ///
    /// The same argument reaches one panel's two states, which is what
    /// ``PaneChrome/PaletteHints`` answers and what this drew wrongly until
    /// 2026-07-31: under `NO MATCHES` both palette actions return on an empty
    /// result set and the row named them anyway.
    var hints: [PaletteHint] = PaletteHints.palette(hasResults: true) {
        didSet {
            guard hints != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { false }

    override func draw(_: NSRect) {
        nsColor(theme.panelBackground).setFill()
        bounds.fill()
        nsColor(theme.divider).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        var x = 14.0
        for hint in hints {
            x = draw(hint.key, colour: theme.inkContext, at: x)
            x = draw(" " + hint.label, colour: theme.inkFaint, at: x) + 14
        }
    }

    private func draw(_ text: String, colour: RGB, at x: Double) -> Double {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: nsColor(colour),
        ])
        string.draw(at: NSPoint(x: x, y: (bounds.height - Double(string.size().height)) / 2))
        return x + Double(string.size().width)
    }

    private func nsColor(_ rgb: RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
    }

    static let height: Double = 26

}
