import AppKit
import PaneChrome

/// The sidebar's bottom row: "New session" and a drawn keycap naming the
/// shortcut that opens it. Design v5 §5.
///
/// **Drawn, not a control**, the same rule every other clickable thing in this
/// column follows and for the same reason: `AppTerminalView.performKeyEquivalent`
/// guards on the window's first responder, and an `NSButton` here would join the
/// key view loop and be reachable by tab, which is the one thing nothing in this
/// window may do. Clicks are hit-tested in `mouseDown` with no
/// `becomeFirstResponder` anywhere near it, the same shape
/// ``ChangesRowsView``/``FileTreeRowsView`` already use.
@MainActor
final class SidebarActionRowView: NSView {
    var theme: PaneTheme = .darkPastel { didSet { needsDisplay = true } }

    /// Gates the opaque fill in ``draw(_:)``. Pushed by `SidebarHost` the same
    /// way it pushes ``SurfaceTitleView/resolvedChrome`` (Task 3, following
    /// Task 2's pattern): this row sits directly over `SidebarHost`'s own
    /// glass backing, and its `barBackground` fill was still unconditional,
    /// which painted an opaque strip across that glass. The label, keycap
    /// outline and hover/press washes are unaffected — none of them was part
    /// of the spike's contrast measurement (finding 6 covered only
    /// ``SurfaceTitleView``'s caps label), so their inks are left unchanged
    /// for the live pass rather than guessed at here.
    ///
    /// **Read a second time by ``labelInk`` since the design panel's wiring**,
    /// so the backdrop this property picks and the keycap ink graded against it
    /// come from one value rather than two that could disagree.
    var resolvedChrome: ResolvedChrome = .flat { didSet { needsDisplay = true } }

    /// The keycap glyph's ink, from ``PaneChrome/PaneTheme/actionRowInk(on:)``
    /// on the backdrop this row is actually drawn on.
    ///
    /// **Moves no pixel until something is dialled.** Unadjusted, the derivation
    /// is ``PaneChrome/PaneTheme/inkFaint`` graded against its backdrop and the
    /// repair is a no-op wherever the faint tier already clears, which under
    /// flat is exactly the `theme.inkFaint` the glyph always drew. What routing
    /// through it buys is `actionRowMinimumRatio` and `actionRowHex` reaching a
    /// site that would otherwise be a constant no dial can touch.
    ///
    /// The backdrop is named the way ``SurfaceTitleView/labelInk`` and
    /// ``SidebarSessionHeaderView/labelInk`` name theirs, off the same measured
    /// stand-in and with the same wallpaper caveat.
    ///
    /// The row's own "New session" label and its hover/press washes are
    /// deliberately not routed here: they are a different tier and a fill, and
    /// the panel offers one dial for this row rather than one per element.
    private var labelInk: RGB {
        switch resolvedChrome {
        case .flat: theme.actionRowInk(on: theme.barBackground)
        case .glass: theme.actionRowInk(on: SurfaceTitleView.measuredBrightGlass)
        }
    }

    /// The keycap glyph drawn trailing, e.g. `⌘T`. Set by the caller from
    /// `WorkspaceMenu.MenuBarLayout.shortcutText(of: .newTab)` rather than
    /// hardcoded here: the row's click opens a tab
    /// (``AppDelegate/openWindow(tree:joining:tabbing:)`` called with
    /// `joining: controller.window`, the same shape as `newTab(_:)`), and a
    /// caption written independently of the menu's own shortcut table is
    /// exactly the drift `PaletteHints` was extracted to prevent: a hint that
    /// names the wrong action is read once and believed. Defaults to `⌘T` so
    /// a caller that forgets to set it still shows the right key rather than
    /// the wrong one.
    var keycap: String = "⌘T" { didSet { needsDisplay = true } }

    /// Fired on mouse-up inside the row. The tab opens beside whatever the
    /// caller decides "New session" means; this view knows only that it was
    /// clicked.
    var onNewSession: (() -> Void)?

    private var isHovered = false { didSet { guard isHovered != oldValue else { return }; needsDisplay = true } }
    private var isPressed = false { didSet { guard isPressed != oldValue else { return }; needsDisplay = true } }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { false }

    override func draw(_: NSRect) {
        // Flat draws its own opaque fill, unchanged from what Plan 1/Plan 3
        // shipped. Glass draws no fill at all (Task 3, same pattern as
        // ``SurfaceTitleView`` and `PaneStatusBarView.draw(_:)`): the label,
        // keycap and hover/press washes below render directly over
        // `SidebarHost.glassBacking`.
        switch resolvedChrome {
        case .flat:
            nsColor(theme.barBackground).setFill()
            bounds.fill()
        case .glass:
            break
        }

        nsColor(theme.hairline).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        if isPressed || isHovered {
            nsColor(theme.background.blended(with: theme.foreground, fraction: isPressed ? 0.10 : 0.06)).setFill()
            bounds.fill()
        }

        let label = NSAttributedString(
            string: "New session",
            attributes: [.font: Self.labelFont, .foregroundColor: nsColor(theme.foreground.blended(with: theme.background, fraction: 0.40))]
        )
        let labelY = (bounds.height - Self.labelFont.ascender + Self.labelFont.descender) / 2 - Self.labelFont.descender
        label.draw(at: NSPoint(x: Self.inset, y: labelY))

        drawKeycap(keycap, trailingAt: bounds.width - Self.inset)
    }

    /// A capsule-cornered outline with a centred glyph, right edge at `trailing`.
    /// The one keycap this task draws; Tasks 3 and 4 draw their own and none of
    /// the three shares a helper yet, the same "add a role when a task first
    /// needs it" restraint ``ChromeMaterials`` documents for itself, since a
    /// palette row's keycap and a popover button's are different heights and
    /// different inks and a shared routine today would be three call sites
    /// guessing which knobs the next one needs.
    private func drawKeycap(_ text: String, trailingAt trailing: Double) {
        let glyph = NSAttributedString(
            string: text,
            attributes: [.font: Self.keycapFont, .foregroundColor: nsColor(labelInk)]
        )
        let glyphSize = glyph.size()
        let width = glyphSize.width + Self.keycapPadding * 2
        let rect = NSRect(x: trailing - width, y: (bounds.height - Self.keycapHeight) / 2, width: width, height: Self.keycapHeight)

        let path = NSBezierPath(roundedRect: rect, xRadius: Self.keycapRadius, yRadius: Self.keycapRadius)
        nsColor(theme.hairline).setStroke()
        path.lineWidth = 1
        path.stroke()

        let glyphY = rect.minY + (rect.height - Self.keycapFont.ascender + Self.keycapFont.descender) / 2 - Self.keycapFont.descender
        glyph.draw(at: NSPoint(x: rect.minX + Self.keycapPadding, y: glyphY))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with _: NSEvent) { isHovered = true }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with _: NSEvent) { isPressed = true }

    /// Held rather than fired on the way down, the same reason every other row
    /// in this column does: a press is a state the eye can see and a drag off
    /// the row cancels rather than acts.
    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        guard wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onNewSession?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func nsColor(_ rgb: RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
    }

    static let height: Double = 32

    private static let inset = ChangesRowsView.inset
    private static let labelFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    private static let keycapFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private static let keycapHeight: Double = 18
    private static let keycapPadding: Double = 6
    private static let keycapRadius: Double = 4
}
