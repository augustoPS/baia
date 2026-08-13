import AppKit
import BaiaSettings
import PaneChrome

/// `NSGlassEffectView`, with the same refusals every other popover-owned glass
/// backing in this app makes (the palette's own copy carries the identical doc
/// comment, and `PaneStatusBarView`'s did until that view was deleted on
/// 2026-08-13): a plain `NSGlassEffectView`
/// hit-tests itself, and ``ApprovalPopoverView`` relies on the buttons
/// underneath it (in ``ApprovalPopoverContentView``) receiving every click.
private final class ApprovalPopoverGlassBacking: NSGlassEffectView {
    override var acceptsFirstResponder: Bool { false }

    override var canBecomeKeyView: Bool { false }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// The title, body and buttons, drawn above ``ApprovalPopoverGlassBacking``
/// rather than in ``ApprovalPopoverView/draw(_:)`` itself.
///
/// `draw(_:)` is a view's own base layer, which every subview (including a
/// glass backing) renders above — the same fact `PaneStatusBarView.draw(_:)`
/// documented on its own copy of this split before it was deleted. Content painted in the parent's
/// `draw(_:)` would sit *under* the glass and be blurred and refracted along
/// with it, so the title, the message and both capsules live in this sibling
/// view instead, stacked above the backing.
///
/// Returns nil from `hitTest` for the same reason `PaneStatusContentView` and
/// `CommandPaletteController`'s own content children do: the parent
/// (``ApprovalPopoverView``) is what stays first responder and answers
/// `mouseDown`/`mouseUp` for the buttons and ⏎/⎋, and a child that accepted
/// hits would take the click before the parent ever saw it.
private final class ApprovalPopoverContentView: NSView {
    var render: ((NSRect) -> Void)?

    override func draw(_: NSRect) { render?(bounds) }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { false }

    override var canBecomeKeyView: Bool { false }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// The approval popover's content: the title, the message, and the two
/// buttons. Design v5 §6.
///
/// A plain `NSView` drawing everything itself rather than `NSButton`s for the
/// two capsules. Nothing in this popover sits inside a pane — it is its own
/// panel, the same as the palette and the find panel — so the first-responder
/// rule that forbids `NSControl` in a pane does not reach here. Drawn anyway,
/// for one reason specific to this surface: ⏎ and ⎋ are already bound to
/// Approve and Deny while the popover holds the keyboard (the controller's own
/// key handling), and a real `NSButton` bound to the same keys through
/// `keyEquivalent` would fight the controller for which one answers a key
/// press. Drawn buttons keep exactly one place deciding what a key does.
final class ApprovalPopoverView: NSView {
    var theme: PaneTheme = .darkPastel {
        didSet {
            needsDisplay = true
            contentView.needsDisplay = true
        }
    }

    /// Flat, unchanged, or glass with the menu material, mirroring the palette's
    /// own copy (and `PaneStatusBarView.resolvedChrome`, until that view was
    /// deleted on 2026-08-13).
    var resolvedChrome: ResolvedChrome = .flat {
        didSet {
            guard resolvedChrome != oldValue else { return }
            applyResolvedChrome()
        }
    }

    /// Which of the four fill roles this popover's glass is tinted with, or nil
    /// for the untinted glass that ships.
    ///
    /// Nil unless the debug design panel has pointed this surface somewhere, and
    /// in Release it can hold nothing else. See ``SurfaceFill``.
    var fillMaterial: DesignOverrides.Chrome.Material? {
        didSet {
            guard fillMaterial != oldValue else { return }
            updateGlassTint()
        }
    }

    /// `agent · repo`, or the bare repo name when no agent is running.
    var title: String = "" { didSet { contentView.needsDisplay = true } }

    /// The attention message verbatim, or ``ApprovalPopover/body(for:)``'s
    /// fallback. Set by the caller, which is the one place that knows both
    /// the reported message and the fallback rule.
    var messageText: String = "" { didSet { contentView.needsDisplay = true } }

    /// Which button, if any, currently reads as pressed: the mouse is down
    /// inside it. ⏎/⎋ commit straight through ``keyDown(with:)`` without ever
    /// setting this — a key press dismisses the popover in the same turn, so
    /// there is no frame in which a pressed key state would be seen. Drawn as
    /// a filled highlight; nothing here is a real `NSControl` so there is no
    /// system pressed state to inherit.
    private var pressedAction: ApprovalPopover.Action?

    var onAction: ((ApprovalPopover.Action) -> Void)?

    private var glassBacking: ApprovalPopoverGlassBacking?

    /// Title, body and buttons, stacked above ``glassBacking`` so glass never
    /// composites over them. See ``ApprovalPopoverContentView``'s own doc
    /// comment for why this has to be a sibling rather than this view's own
    /// `draw(_:)`. Always a subview (flat has no glass to sit above, but the
    /// content still needs to live somewhere), added once in `init` and never
    /// torn down the way ``glassBacking`` is.
    private let contentView = ApprovalPopoverContentView(frame: .zero)

    /// This view is first responder while the popover is up (the controller
    /// makes it so on presenting), which is what design v5 §6's "⏎/⎋ map to
    /// the buttons only while the popover is presented" needs: a borderless
    /// `NSPanel` with no field inside it still routes key events to whatever
    /// the window's first responder is, and this view is the only thing in
    /// this window that could be it. Nothing here joins a pane's key view
    /// loop or fights `AppTerminalView.performKeyEquivalent` for first
    /// responder — this popover is its own window, the same exemption
    /// ``PaletteQueryField`` already carries.
    override var acceptsFirstResponder: Bool { true }

    /// Escape does not reach `keyDown(with:)` as reliably as Return does,
    /// because AppKit can route it through `cancelOperation(_:)` on the
    /// responder chain first — the same fact ``PaletteQueryField`` documents
    /// on its own copy of this override. Caught here as well so Deny answers
    /// however Escape arrives.
    override func cancelOperation(_: Any?) {
        onAction?(.deny)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case Self.returnKeyCode: onAction?(.approve)
        case Self.escapeKeyCode: onAction?(.deny)
        default: super.keyDown(with: event)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true

        contentView.render = { [weak self] bounds in self?.drawContent(in: bounds) }
        addSubview(contentView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("baia does not use nibs")
    }

    override var isFlipped: Bool { true }

    // MARK: - Chrome material

    private var materialSet: MaterialSet? {
        switch resolvedChrome {
        case .flat: nil
        case let .glass(set): set
        }
    }

    /// **Untinted glass (Task 2) is still what ships.** `backing.tintColor` used
    /// to carry `set.fillMenu`; the tint is nil now, the same untinted `regular`
    /// glass the pane's own plane (`PaneGlassPlaneView`) ships with.
    ///
    /// ``fillMaterial`` can put it back and only the debug design panel can set
    /// it, which is why the `.glass` case below still does not bind its `set`:
    /// ``updateGlassTint()`` re-reads ``resolvedChrome`` for the material set at
    /// the one line that needs one, so a tint written before the backing existed
    /// still lands. See ``SurfaceFill``.
    private func applyResolvedChrome() {
        switch resolvedChrome {
        case .flat:
            glassBacking?.removeFromSuperview()
            glassBacking = nil
        case .glass:
            let backing: ApprovalPopoverGlassBacking
            if let existing = glassBacking {
                backing = existing
            } else {
                backing = ApprovalPopoverGlassBacking(frame: bounds)
                backing.style = .regular
                backing.wantsLayer = true
                // Below `contentView`, not below every subview: `nil` here
                // would still be above this view's own `draw(_:)` layer (an
                // `NSView`'s base layer always renders under its subviews
                // regardless of subview order), but ordering explicitly
                // against `contentView` is what keeps the title, body and
                // buttons stacked above the glass rather than under it.
                addSubview(backing, positioned: .below, relativeTo: contentView)
                glassBacking = backing
            }
            backing.frame = bounds
        }
        updateGlassTint()
        needsDisplay = true
        // `effectiveBackground` (and so the body's ink) depends on
        // `materialSet`, which just changed.
        contentView.needsDisplay = true
    }

    /// Writes ``fillMaterial``'s colour onto the backing, or nil — which is what
    /// ships and what every Release build resolves.
    private func updateGlassTint() {
        guard let glassBacking, let materialSet else { return }
        glassBacking.tintColor = SurfaceFill.colour(fillMaterial, in: materialSet)
    }

    override func layout() {
        super.layout()
        glassBacking?.frame = bounds
        contentView.frame = bounds
    }

    // MARK: - Drawing

    /// This view's own base layer: the flat fill (glass draws none, Task 2)
    /// and the hairline stroke. Everything else lives in ``contentView``, a
    /// sibling stacked above ``glassBacking`` — see
    /// ``ApprovalPopoverContentView``'s doc comment for why the split exists.
    override func draw(_: NSRect) {
        if materialSet == nil {
            nsColor(theme.panelBackground).setFill()
            bounds.fill()
        }

        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        path.lineWidth = 1
        nsColor(theme.hairline).setStroke()
        path.stroke()
    }

    private func drawContent(in _: NSRect) {
        drawTitle()
        drawBody()
        drawButtons()
    }

    private func drawTitle() {
        let string = NSAttributedString(string: title, attributes: [
            .font: Self.titleFont,
            .foregroundColor: nsColor(theme.foreground),
        ])
        string.draw(at: NSPoint(x: Self.inset, y: Self.inset))
    }

    /// The message, wrapped rather than truncated: it is the whole reason the
    /// popover is open, and a body cut to one line could hide the part of the
    /// prompt that matters.
    private func drawBody() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let string = NSAttributedString(string: messageText, attributes: [
            .font: Self.bodyFont,
            .foregroundColor: nsColor(theme.color(for: .normal, focused: true, on: effectiveBackground)),
            .paragraphStyle: paragraph,
        ])
        string.draw(with: bodyRect, options: [.usesLineFragmentOrigin])
    }

    private func drawButtons() {
        for action in ApprovalPopover.Action.allCases {
            drawButton(action, in: rect(for: action))
        }
    }

    private func drawButton(_ action: ApprovalPopover.Action, in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        let pressed = pressedAction == action
        let fill: RGB
        let ink: RGB
        switch action {
        case .approve:
            fill = pressed ? theme.focusedAccent.blended(with: theme.background, fraction: 0.12) : theme.focusedAccent
            ink = theme.ink(on: theme.focusedAccent)
            nsColor(fill).setFill()
            path.fill()
        case .deny:
            // Clear fill: only the stroke, so Approve stays the one accented
            // control in the overlay, per the plan. The pressed state still
            // needs some fill to read as pressed at all, so it borrows the
            // same neutral wash a selected row wears rather than reaching for
            // the accent Deny is deliberately drawn without.
            ink = theme.foreground
            if pressed {
                nsColor(theme.selectedRowBackground).setFill()
                path.fill()
            }
            nsColor(theme.hairline).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        let label = "\(Self.title(for: action))  \(Self.glyph(for: action))"
        let string = NSAttributedString(string: label, attributes: [
            .font: Self.buttonFont,
            .foregroundColor: nsColor(ink),
        ])
        let size = string.size()
        string.draw(at: NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2
        ))
    }

    /// The surface the body text is judged readable against:
    /// `theme.panelBackground`, unconditionally, on both flat and glass now.
    ///
    /// **Task 2, superseding Task 4's original clause.** See
    /// `PaneStatusBarView.effectiveBarFill` for the measured reason grading
    /// against a flattened menu-fill swatch was dropped in favour of the same
    /// ungraded ink flat always used: the repair chain now applies to the
    /// flat/Reduce-Transparency rendering only.
    private var effectiveBackground: RGB {
        theme.panelBackground
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressedAction = ApprovalPopover.Action.allCases.first { rect(for: $0).contains(point) }
        contentView.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressedAction = nil
            contentView.needsDisplay = true
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let action = pressedAction, rect(for: action).contains(point) else { return }
        onAction?(action)
    }

    // MARK: - Layout

    /// Where the button row's top edge sits, in this flipped view's
    /// coordinates, measured down from the title and the wrapped body.
    /// Recomputed from ``bounds`` and ``messageText`` rather than cached,
    /// because ``draw(_:)`` and the two mouse handlers all need the same
    /// answer and this view has no autolayout pass to keep a cached one
    /// current when either input changes.
    private var buttonRowY: Double {
        Self.inset + Self.titleHeight + wrappedBodyHeight + Self.buttonRowGap
    }

    private var bodyRect: NSRect {
        NSRect(
            x: Self.inset,
            y: Self.inset + Self.titleHeight,
            width: bounds.width - Self.inset * 2,
            height: wrappedBodyHeight
        )
    }

    private var wrappedBodyHeight: Double {
        Self.wrappedBodyHeight(for: messageText, width: bounds.width - Self.inset * 2)
    }

    private func rect(for action: ApprovalPopover.Action) -> NSRect {
        let width = (bounds.width - Self.inset * 2 - Self.buttonGap) / 2
        let x = Self.inset + (action == .deny ? 0 : width + Self.buttonGap)
        return NSRect(x: x, y: buttonRowY, width: width, height: Self.buttonHeight)
    }

    private func nsColor(_ rgb: RGB, alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: CGFloat(alpha))
    }

    private static func title(for action: ApprovalPopover.Action) -> String {
        switch action {
        case .approve: "Approve"
        case .deny: "Deny"
        }
    }

    private static func glyph(for action: ApprovalPopover.Action) -> String {
        switch action {
        case .approve: "\u{23CE}" // ⏎
        case .deny: "\u{238B}" // ⎋
        }
    }

    private static let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let bodyFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let buttonFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    static let width: Double = 300
    static let cornerRadius: Double = 10
    private static let inset: Double = 14
    private static let titleHeight: Double = 20
    static let buttonHeight: Double = 22
    private static let buttonGap: Double = 10
    private static let buttonRowGap: Double = 14

    /// `messageText`'s height once wrapped to `width`, the one measurement
    /// ``wrappedBodyHeight``, ``measuredHeight(forMessage:width:)`` and
    /// ``bodyRect`` all need and must agree on. A static function of the
    /// string and the width rather than a value read off `self` in two
    /// places, so the panel the controller sizes before presenting and the
    /// view drawn inside it cannot measure the same message two different
    /// ways.
    private static func wrappedBodyHeight(for text: String, width: Double) -> Double {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let string = NSAttributedString(string: text, attributes: [
            .font: Self.bodyFont,
            .paragraphStyle: paragraph,
        ])
        return string.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        ).height
    }

    /// The total height this view needs to draw `messageText` in full: title,
    /// wrapped body and button row stacked with their fixed insets. The
    /// controller sizes the panel to this before presenting, so the message
    /// is never clipped and the button row this view computes at draw time
    /// lands exactly at the panel's own bottom inset.
    static func measuredHeight(forMessage message: String, width: Double) -> Double {
        let bodyHeight = wrappedBodyHeight(for: message, width: width - inset * 2)
        return inset + titleHeight + bodyHeight + buttonRowGap + buttonHeight + inset
    }

    // Virtual key codes, `Carbon/HIToolbox`'s own constants (`kVK_Return` /
    // `kVK_Escape`) spelled as literals: this target links no Carbon, and the
    // two codes are stable ABI, unchanged since the original ADB keyboard map.
    private static let returnKeyCode: UInt16 = 0x24
    private static let escapeKeyCode: UInt16 = 0x35
}
