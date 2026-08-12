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

/// The palette's query line: a drawn loupe, the field, the result count, and a
/// trailing keycap. Design v5 §6.
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

    /// Flat, unchanged, or glass with the material set the theme's own darkness
    /// picked, exactly the input ``PaneStatusBarView/resolvedChrome`` reads.
    /// The find panel leaves this at its default `.flat` — nothing sets it —
    /// so sharing this view costs the find panel nothing: it draws the same
    /// opaque fill it always has.
    var resolvedChrome: ResolvedChrome = .flat { didSet { needsDisplay = true } }

    /// The material set glass resolves to, or nil under flat.
    private var materialSet: MaterialSet? {
        switch resolvedChrome {
        case .flat: nil
        case let .glass(set): set
        }
    }

    /// Drawn ahead of the keycap, for example `3 of 12`.
    var countText: String = "" {
        didSet {
            guard countText != oldValue else { return }
            needsDisplay = true
        }
    }

    /// The keycap at the trailing edge, `⌘K` for the palette. Nil draws none:
    /// the find panel reuses this view and was never opened by a keystroke
    /// this header could name, so a hard-coded `⌘K` here would caption the
    /// wrong panel's summon key.
    var trailingKeycap: String? {
        didSet {
            guard trailingKeycap != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        field.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
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
            x: Self.loupeInset + Self.loupeWidth,
            y: (bounds.height - 20) / 2,
            width: bounds.width - Self.loupeInset - Self.loupeWidth - Self.trailingRoom,
            height: 20
        )
    }

    override func draw(_: NSRect) {
        // Flat draws the opaque panel background unchanged. Glass draws no
        // fill at all (Task 2 — untint the chrome): the panel's own
        // `NSGlassEffectView` backing (below every band, added by the
        // controller) is itself untinted now, and painting `fillMenu` here
        // would put back exactly the tinted layer that view no longer draws,
        // one level higher. See ``PaneStatusBarView/draw(_:)`` for the same
        // trade made on the footer.
        if materialSet == nil {
            nsColor(theme.panelBackground).setFill()
            bounds.fill()
        }

        drawLoupe(at: NSPoint(x: Self.loupeInset, y: bounds.height / 2))

        var trailingX = bounds.width - Self.loupeInset
        if let trailingKeycap {
            trailingX = drawKeycap(trailingKeycap, trailingAt: trailingX) - Self.keycapGap
        }
        if !countText.isEmpty {
            drawCount(countText, trailingAt: trailingX)
        }

        // The rule under the query, one step below the panel's own border so the
        // query reads as attached to the list rather than as a separate box.
        nsColor(theme.divider).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    private func drawCount(_ text: String, trailingAt trailing: Double) {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: nsColor(theme.inkFaint),
        ])
        let width = Double(string.size().width)
        string.draw(at: NSPoint(
            x: trailing - width,
            y: (bounds.height - Double(string.size().height)) / 2
        ))
    }

    /// An inline drawn shape rather than the `❯` glyph the header used before:
    /// vitreous ships no icon set (rule 12), so every non-text mark here is a
    /// stroked path, the same choice the sidebar's disclosure chevrons and the
    /// footer's capsule already make. A ring plus a short diagonal handle,
    /// stroked in the accent because this is the one place in the palette that
    /// says "type here" and the palette is what has focus.
    private func drawLoupe(at centre: NSPoint) {
        let ringDiameter = Self.loupeRingDiameter
        let ringRadius = ringDiameter / 2
        // The ring sits high and left of `centre`, the handle trails down and
        // right of it, so the glyph reads left-aligned at `loupeInset` the way
        // the query text beside it does.
        let ringCentre = NSPoint(x: centre.x + ringRadius, y: centre.y - Self.loupeHandleLength / 2 + ringRadius)

        let ring = NSBezierPath(ovalIn: NSRect(
            x: ringCentre.x - ringRadius, y: ringCentre.y - ringRadius,
            width: ringDiameter, height: ringDiameter
        ))
        ring.lineWidth = Self.loupeStrokeWidth
        nsColor(theme.focusedAccent).setStroke()
        ring.stroke()

        let handleStart = NSPoint(
            x: ringCentre.x + ringRadius * 0.72,
            y: ringCentre.y + ringRadius * 0.72
        )
        let handle = NSBezierPath()
        handle.move(to: handleStart)
        handle.line(to: NSPoint(
            x: handleStart.x + Self.loupeHandleLength * 0.72,
            y: handleStart.y + Self.loupeHandleLength * 0.72
        ))
        handle.lineWidth = Self.loupeStrokeWidth
        handle.lineCapStyle = .round
        nsColor(theme.focusedAccent).setStroke()
        handle.stroke()
    }

    /// The same drawn keycap ``PaletteHintsView`` draws its own copy of:
    /// outlined capsule corners, a centred glyph, right edge at `trailing`. Not
    /// shared with it — the header's keycap is 10pt like the hint row's but sits
    /// in a 40pt band with different vertical centring, and a routine bent to
    /// fit both heights would be harder to read than two short ones. There were
    /// three copies until 2026-08-12: the sidebar's action row drew a `⌘T` and
    /// went with the row on the owner's ruling that day, which cost this
    /// argument a case and did not change it.
    ///
    /// Answers the rect's leading edge, so the count text can be drawn flush
    /// against it rather than at a second hard-coded inset that could drift
    /// out of step with the keycap's own width.
    @discardableResult
    private func drawKeycap(_ text: String, trailingAt trailing: Double) -> Double {
        let glyph = NSAttributedString(
            string: text,
            attributes: [.font: Self.keycapFont, .foregroundColor: nsColor(theme.inkFaint)]
        )
        let glyphSize = glyph.size()
        let width = glyphSize.width + Self.keycapPadding * 2
        let rect = NSRect(
            x: trailing - width, y: (bounds.height - Self.keycapHeight) / 2,
            width: width, height: Self.keycapHeight
        )
        let path = NSBezierPath(roundedRect: rect, xRadius: Self.keycapRadius, yRadius: Self.keycapRadius)
        path.lineWidth = 1
        nsColor(theme.hairline).setStroke()
        path.stroke()

        let glyphY = rect.minY + (rect.height - Self.keycapFont.ascender + Self.keycapFont.descender) / 2 - Self.keycapFont.descender
        glyph.draw(at: NSPoint(x: rect.minX + Self.keycapPadding, y: glyphY))
        return rect.minX
    }

    private func nsColor(_ rgb: RGB, alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: CGFloat(alpha))
    }

    static let height: Double = 40
    private static let loupeInset: Double = 14
    private static let loupeWidth: Double = 16
    private static let loupeRingDiameter: Double = 10
    private static let loupeHandleLength: Double = 6
    private static let loupeStrokeWidth: Double = 1.4
    /// Room reserved at the trailing edge for the widest case: a keycap and a
    /// count both drawn. The field's width is computed from this rather than
    /// measured live, the same trade the row's fixed insets make elsewhere in
    /// this file — a field that grew and shrank with the count string on every
    /// keystroke would visibly resize the text as it was being typed into.
    private static let trailingRoom: Double = 96
    private static let keycapGap: Double = 8
    private static let keycapFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private static let keycapHeight: Double = 18
    private static let keycapPadding: Double = 6
    private static let keycapRadius: Double = 4
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

    /// Flat, unchanged, or glass with the material set the theme's own darkness
    /// picked. See ``PaletteQueryView/resolvedChrome`` for why the find panel,
    /// which reuses this view too, is unaffected: it never sets this and stays
    /// at the `.flat` default.
    var resolvedChrome: ResolvedChrome = .flat { didSet { needsDisplay = true } }

    private var materialSet: MaterialSet? {
        switch resolvedChrome {
        case .flat: nil
        case let .glass(set): set
        }
    }

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
            // Raised for a hover as well as for an arrow key, because the git
            // state on screen belongs to whichever row is selected however it
            // came to be selected. Without this the pointer moved the highlight
            // and left the previous row's branch drawn beside the new one.
            onSelectionChange?()
        }
    }

    /// Raised after the selection moves for any reason, so the owner can refresh
    /// what it shows for the selected row.
    ///
    /// Separate from ``onActivate`` because the two are different events: this
    /// fires while browsing and that fires on commit.
    var onSelectionChange: (() -> Void)?

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
        // See ``PaletteQueryView/draw(_:)`` for why glass skips this fill
        // rather than painting the translucent menu material.
        if materialSet == nil {
            nsColor(theme.panelBackground).setFill()
            bounds.fill()
        }

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

        if selected {
            // Radius 6, concentric with every other row-selection surface v5
            // draws (the sidebar's `FilesSurface` rows use the same
            // construction). No accent edge: v5 §6 spends the row's own
            // fill on saying "this one" and asks the text to carry the
            // high-contrast repair instead, which is what ``colour(for:selected:)``
            // is for.
            nsColor(theme.selectedRowBackground).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: Self.rowInsetX, y: top, width: bounds.width - Self.rowInsetX * 2, height: Self.rowHeight),
                xRadius: Self.rowRadius,
                yRadius: Self.rowRadius
            ).fill()
        }

        var x = Self.inset
        // One mono face for the whole row now, parent and name alike (design v5
        // §6: "still built through the shared segment table, mono 11.5pt"). The
        // tier boundary that used to be a font change is carried by
        // `PaneStatusEmphasis` alone, the same as every other segment table in
        // this app.
        x = drawRuns(row.parent, at: x, top: top, selected: selected)
        x = drawRuns(row.name, at: x, top: top, selected: selected)

        if let chip = row.chip {
            x = drawChip(chip, at: x + 6, top: top, selected: selected)
        }

        // The status word: git state on a project row, selected only, the
        // right-aligned word v5 §6 asks the selected row to carry. Unselected
        // rows show nothing here, the same "unavailable renders nothing" rule
        // the sidebar's counts hold to, because the git read only ever runs for
        // the selected row (`CommandPaletteController.refreshSelectedGitState`).
        guard selected, !selectedGitRuns.isEmpty else { return }
        drawTrailing(selectedGitRuns, top: top, selected: true)
    }

    private func drawRuns(_ runs: [PaneStatusRun], at x: Double, top: Double, selected: Bool) -> Double {
        var x = x
        for run in runs {
            let string = NSAttributedString(string: run.text, attributes: [
                .font: Self.rowFont,
                .foregroundColor: nsColor(colour(for: run.emphasis, selected: selected)),
            ])
            string.draw(at: NSPoint(x: x, y: top + Self.baseline))
            x += Double(string.size().width)
        }
        return x
    }

    /// The git state, measured from the right edge so it lands in the same column
    /// on every row it appears on.
    private func drawTrailing(_ runs: [PaneStatusRun], top: Double, selected: Bool) {
        let strings = runs.map { run in
            NSAttributedString(string: run.text, attributes: [
                .font: Self.rowFont,
                .foregroundColor: nsColor(colour(for: run.emphasis, selected: selected)),
            ])
        }
        let total = strings.reduce(0.0) { $0 + Double($1.size().width) }
        var x = bounds.width - Self.inset - total
        for string in strings {
            string.draw(at: NSPoint(x: x, y: top + Self.baseline))
            x += Double(string.size().width)
        }
    }

    /// The same outlined chip the footer draws for `PIN`, at the same weight and
    /// tracking, so `WT` in the palette and `PIN` on the bar are recognisably one
    /// device.
    private func drawChip(_ text: String, at x: Double, top: Double, selected: Bool) -> Double {
        let ink = selected ? theme.ink(on: theme.selectedRowBackground) : theme.inkContext
        let string = NSAttributedString(string: text, attributes: [
            .font: Self.chipFont,
            .foregroundColor: nsColor(ink),
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
        nsColor(ink.blended(with: selected ? theme.selectedRowBackground : effectiveBackground, fraction: 0.45)).setStroke()
        path.stroke()
        string.draw(at: NSPoint(
            x: x + Self.chipPadding,
            y: top + (Self.rowHeight - Double(string.size().height)) / 2
        ))
        return x + width
    }

    /// The colour a run is drawn in. Selected rows repair through
    /// ``PaneChrome/PaneTheme/color(for:focused:on:)`` against the row's own
    /// fill rather than the panel background, which is what "high-contrast
    /// ink" (v5 §6) means for a surface whose fill is `selectedRowBackground`
    /// rather than a bar-level colour: the same repair chain the footer's
    /// filled bar and every other bar-on-a-fill judgement already goes
    /// through, not a second contrast rule invented for this list.
    private func colour(for emphasis: PaneStatusEmphasis, selected: Bool) -> RGB {
        theme.color(for: emphasis, focused: true, on: selected ? theme.selectedRowBackground : effectiveBackground)
    }

    /// The surface unselected text is judged readable against:
    /// `theme.panelBackground`, unconditionally, on both flat and glass now.
    ///
    /// **Task 2, superseding Task 4's original clause**: this used to flatten
    /// the menu fill onto `theme.background` as an approximation for the
    /// repair chain to grade glass text against. See
    /// `PaneStatusBarView.effectiveBarFill` for the measured reason that
    /// approximation was dropped (2.09:1 predicted versus 9.49:1 measured):
    /// the repair chain now applies to the flat/Reduce-Transparency rendering
    /// only, and glass takes the same ungraded ink flat always used.
    private var effectiveBackground: RGB {
        theme.panelBackground
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard let index = row(at: event) else { return }
        selection = index
        onActivate?(index, event.modifierFlags.contains(.shift) ? .splitRight : .newTab)
    }

    /// Moving the pointer over a row selects it, the way a menu does.
    ///
    /// The palette is driven from the keyboard and the selection was only ever
    /// moved by the arrows, so the pointer could sit on one row while the
    /// highlight stayed on another and Return took the highlighted one. Clicking
    /// worked, which is what made the gap easy to miss: the click sets the
    /// selection on its way through.
    override func mouseMoved(with event: NSEvent) {
        guard let index = row(at: event), index != selection else { return }
        selection = index
    }

    /// The row under an event, or nil when the pointer is past the last one.
    ///
    /// Shared by the click and the hover so one arithmetic mistake cannot make
    /// them disagree, which would show a highlight on one row and open another.
    private func row(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        guard point.y >= 0 else { return nil }
        let index = scrollOffset + Int(point.y / Self.rowHeight)
        return rows.indices.contains(index) ? index : nil
    }

    /// Rebuilt whenever the frame changes, because the list is resized on every
    /// keystroke as the result count moves and an area built against the old
    /// frame tracks a rectangle the rows no longer occupy.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                // `activeAlways` rather than `activeInKeyWindow`: the palette
                // lives in an `NSPanel` that takes key from its host, so the
                // window under the pointer is not the key window and the
                // in-key-window variant delivers nothing.
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                owner: self,
                userInfo: nil
            )
        )
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

    private func nsColor(_ rgb: RGB, alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: CGFloat(alpha))
    }

    /// The height this list wants for `count` rows, which is what sizes the
    /// panel: a palette showing three results should not be a panel with five
    /// rows of empty space under them.
    static func height(forRowCount count: Int) -> Double {
        Double(max(1, min(count, visibleRows))) * rowHeight
    }

    static let visibleRows = 8
    static let rowHeight: Double = 28
    private static let inset: Double = 14
    /// The selection fill's own inset, so the rounded rect reads as a row
    /// floating inside the list rather than a stripe that touches both edges,
    /// the same margin the sidebar's rows leave outside their own fill.
    private static let rowInsetX: Double = 4
    private static let rowRadius: Double = 6
    private static let baselineFromTop: Double = 19
    private static let baseline: Double = baselineFromTop - rowFont.ascender
    private static let chipPadding: Double = 4
    private static let chipHeight: Double = 13
    /// One mono face for the whole row, design v5 §6: parent, name and the
    /// trailing git state all read at the same size now, the tier boundary
    /// carried by `PaneStatusEmphasis` alone rather than by a font change.
    private static let rowFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let chipFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
}

/// The key hints along the bottom edge.
final class PaletteHintsView: NSView {
    var theme: PaneTheme = .darkPastel { didSet { needsDisplay = true } }

    /// Flat, unchanged, or glass with the material set the theme's own darkness
    /// picked. See ``PaletteQueryView/resolvedChrome``; the find panel that
    /// also owns one of these never sets it and stays flat.
    var resolvedChrome: ResolvedChrome = .flat { didSet { needsDisplay = true } }

    private var materialSet: MaterialSet? {
        switch resolvedChrome {
        case .flat: nil
        case let .glass(set): set
        }
    }

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
        // See ``PaletteQueryView/draw(_:)`` for why glass skips this fill
        // rather than painting the translucent menu material.
        if materialSet == nil {
            nsColor(theme.panelBackground).setFill()
            bounds.fill()
        }
        nsColor(theme.divider).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        var x = 14.0
        for hint in hints {
            x = drawKeycap(hint.key, leadingAt: x) + Self.keycapGap
            x = draw(hint.label, colour: theme.inkFaint, at: x) + Self.hintGap
        }
    }

    /// Each hint's key drawn as its own outlined capsule, 10pt tertiary ink
    /// (design v5 §6), the same construction the header's `⌘K` draws
    /// independently: a stroked rounded rect sized to
    /// its glyph rather than plain mono text, so `esc`/`⏎`/`⇧⏎` read as keys
    /// rather than as prose abbreviations.
    @discardableResult
    private func drawKeycap(_ text: String, leadingAt leading: Double) -> Double {
        let glyph = NSAttributedString(string: text, attributes: [
            .font: Self.keycapFont,
            .foregroundColor: nsColor(theme.inkFaint),
        ])
        let glyphSize = glyph.size()
        let width = glyphSize.width + Self.keycapPadding * 2
        let rect = NSRect(x: leading, y: (bounds.height - Self.keycapHeight) / 2, width: width, height: Self.keycapHeight)
        let path = NSBezierPath(roundedRect: rect, xRadius: Self.keycapRadius, yRadius: Self.keycapRadius)
        path.lineWidth = 1
        nsColor(theme.hairline).setStroke()
        path.stroke()
        let glyphY = rect.minY + (rect.height - Self.keycapFont.ascender + Self.keycapFont.descender) / 2 - Self.keycapFont.descender
        glyph.draw(at: NSPoint(x: rect.minX + Self.keycapPadding, y: glyphY))
        return rect.maxX
    }

    private func draw(_ text: String, colour: RGB, at x: Double) -> Double {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: nsColor(colour),
        ])
        string.draw(at: NSPoint(x: x, y: (bounds.height - Double(string.size().height)) / 2))
        return x + Double(string.size().width)
    }

    private func nsColor(_ rgb: RGB, alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: CGFloat(alpha))
    }

    static let height: Double = 26
    private static let keycapFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private static let keycapHeight: Double = 16
    private static let keycapPadding: Double = 5
    private static let keycapRadius: Double = 4
    private static let keycapGap: Double = 6
    private static let hintGap: Double = 14
}
