import AppKit
import BaiaSettings
import PaneChrome
import WorkspaceLayout

/// A pane of the footer that draws through a closure its owner supplies.
///
/// The footer needs four stacked surfaces: the bar, an alert wash that can be
/// animated on its own, the text above both, and the focus frame above all of
/// them. A view's own `draw(_:)` renders *below* its subviews and sublayers, so
/// the text cannot live there if anything is to fade in behind it, and the two
/// things that fade need separate layers because they fade on their own clocks.
///
/// A view rather than a `CALayer` subclass. This target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and `CALayer`'s `draw(in:)`,
/// `action(forKey:)` and initializers are all nonisolated, so a subclass of it
/// cannot override them without being torn out of the isolation every other type
/// here lives in. `NSView` is main-actor already.
private final class PaneStatusContentView: NSView {
    var render: ((NSRect) -> Void)?

    override func draw(_: NSRect) { render?(bounds) }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { false }

    override var canBecomeKeyView: Bool { false }

    /// The footer swallows no clicks. See the note on the view below: anything in
    /// a pane that can take first responder silently disables every ghostty key
    /// binding in it.
    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// `NSGlassEffectView`, with the same three refusals every other layer of this
/// footer makes.
///
/// A plain `NSGlassEffectView` hit-tests itself by AppKit's own default, and
/// this bar's container relies on every child returning nil from `hitTest` so
/// the click bubbles up to its own `mouseDown(with:)` (see that method's own
/// note). Without this override the glass backing would be the view a click
/// inside the footer actually lands on, and the container's `mouseDown` would
/// never fire, so the pane it sits over could no longer be focused by clicking
/// its footer once glass was on.
private final class PaneStatusGlassBacking: NSGlassEffectView {
    override var acceptsFirstResponder: Bool { false }

    override var canBecomeKeyView: Bool { false }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// The thin footer under one terminal surface.
///
/// Drawing only. Every decision about which segments exist, what they say, and
/// which ones survive a narrow pane lives in the `PaneChrome` package, which has
/// no AppKit and is tested without a window. This type measures strings, hands
/// the widths to the solver, and fills in rectangles.
///
/// It must never become first responder.
/// `AppTerminalView.performKeyEquivalent` opens with
/// `guard window?.firstResponder === self else { return false }`, so any view
/// that takes first responder away from the terminal silently disables *every*
/// ghostty key binding in that pane. That is why this is a plain `NSView` that
/// draws text rather than an `NSStackView` of labels, and why there is no
/// `NSControl` anywhere in it: an `NSTextField` or `NSButton` would join the key
/// view loop and be reachable by tab. The pin chip looks like a button and is a
/// stroked rectangle for exactly this reason.
final class PaneStatusBarView: NSView {
    /// Set by the pane controller whenever the anchor, git state, or agent state
    /// moves. Redraws only on a real change, because the anchor tracker polls
    /// once a second and an unconditional `needsDisplay` would repaint the footer
    /// of every pane every second for nothing.
    var status: PaneStatus? {
        didSet {
            guard status != oldValue else { return }
            // Read before the redraw, so the arrival pulse is decided by the
            // transition rather than by the state. A pane that repaints while it
            // is still waiting must not blink again.
            let became = oldValue?.attention ?? .none
            // Stripped *before* the repaint, not after. `invalidate` only writes
            // the wash's opacity when no animation is running, so removing the
            // arrival pulse afterwards left the model value at 1 with the alert
            // colour behind it: acknowledging a pane inside the 0.51 s pulse
            // froze its footer as a solid red band until some later change
            // happened to repaint it.
            if attention != .asking { attentionWash.layer?.removeAllAnimations() }
            invalidate()
            // `runArrivalPulse` removes animations itself, so the entry path is
            // unaffected by the reordering above.
            if became != .asking, attention == .asking { runArrivalPulse() }
        }
    }

    var theme: PaneTheme = .darkPastel {
        didSet {
            guard theme != oldValue else { return }
            invalidate()
        }
    }

    /// What the bar draws, chosen by `PaneChrome.resolvedStyle(setting:appearance:)`
    /// upstream: flat, unchanged from what Plan 1 shipped, or glass with a
    /// material set to draw a translucent backing under this bar's own content.
    ///
    /// A stored property with a `didSet`, the same shape as ``theme``, rather
    /// than a value read fresh on every draw: the backing view's existence has to
    /// change with it, and a view is created or torn down here, once, not on
    /// every `draw(_:)` pass.
    ///
    /// **Flat creates no backing view at all, not merely a hidden one.** A hidden
    /// `NSGlassEffectView` still costs a compositing pass macOS runs whether or
    /// not it draws anything, and flat is the byte-identical spec: the absence of
    /// the view is part of what "byte-identical" means here, not just the
    /// absence of its visible effect.
    var resolvedChrome: ResolvedChrome = .flat {
        didSet {
            guard resolvedChrome != oldValue else { return }
            applyResolvedChrome()
        }
    }

    var isFocused: Bool = false {
        didSet {
            guard isFocused != oldValue else { return }
            invalidate()
        }
    }

    /// Whether this pane's window is the key window.
    ///
    /// Separate from ``isFocused`` rather than folded into it, because the two
    /// are owed different things. A background window recedes as one object, so
    /// the focus frame goes; but the anchor name keeps its focus ink, because the
    /// whole pane is already behind the inactive scrim and taking the colour too
    /// would say the same thing twice while losing which pane the keyboard comes
    /// back to. Folding this into `isFocused` would take the name with it.
    var isWindowActive: Bool = true {
        didSet {
            guard isWindowActive != oldValue else { return }
            invalidate()
        }
    }

    /// How loudly an unacknowledged pane asks. Read straight off the config: the
    /// only thing that fills this bar is attention, so nothing else can claim the
    /// fill first and force this quiet.
    var attentionStyle: AttentionStyle = .loud {
        didSet {
            guard attentionStyle != oldValue else { return }
            invalidate()
        }
    }

    /// Which derivation the attention signal is drawn from, and what to do when it
    /// lands on the focus colour. Pushed from the config beside ``attentionStyle``.
    ///
    /// Stored rather than resolved, and resolved rather than stored resolved: the
    /// answer depends on ``theme`` as well as on these two, and a colour cached
    /// here would survive a live theme edit that moved everything it was derived
    /// from.
    var attentionAccent: AttentionAccent = .alert {
        didSet {
            guard attentionAccent != oldValue else { return }
            invalidate()
        }
    }

    var alertBehavior: AlertBehavior = .stock {
        didSet {
            guard alertBehavior != oldValue else { return }
            invalidate()
        }
    }

    /// Which of the window's bottom corners this bar sits in, pushed by the pane
    /// tree from the layout. Empty for every pane away from the window's edge,
    /// which is most of them.
    ///
    /// Set rather than derived, because a view cannot see the arrangement it is
    /// in: a footer at the bottom left of its own pane has no way to know whether
    /// the pane is at the bottom left of the window or in the middle of a grid.
    var bottomCorners: BottomCorners = [] {
        didSet {
            guard bottomCorners != oldValue else { return }
            invalidate()
            // The glass backing has no `draw(_:)` of its own for `cornerPath` to
            // clip the way the drawn fill does, so its mask has to be rebuilt by
            // hand whenever the corners it should match move.
            updateGlassMask()
        }
    }

    private let attentionWash = PaneStatusContentView(frame: .zero)
    private let contentView = PaneStatusContentView(frame: .zero)
    /// Above the text rather than below it, so a filled bar cannot swallow the
    /// frame. Its own view because the fade is on `opacity`, and animating a
    /// value that `draw(_:)` paints would mean redrawing the text for 160 ms.
    private let barFrame = PaneStatusContentView(frame: .zero)

    /// The glass material under everything else, or nil under flat.
    ///
    /// Created and torn down by ``applyResolvedChrome()``, not merely hidden:
    /// see ``resolvedChrome``'s own doc comment for why flat has to mean no view
    /// exists rather than an invisible one. Always the first subview when it
    /// exists, below ``attentionWash``, so the glass reads as the surface the
    /// bar's own drawing sits on rather than as a layer painted over the text.
    private var glassBacking: PaneStatusGlassBacking?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The footer changes only when the status does, so AppKit must not
        // repaint it as a side effect of the terminal above it resizing.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        focusRingType = .none

        // Order matters and is the whole reason these are separate views. The bar
        // itself is drawn by `draw(_:)`, which lands below all three; the alert
        // wash sits above it so it can fade in on its own; the text sits above
        // the wash so it stays legible while that happens; the focus frame sits
        // above everything, because a bar filled for attention would otherwise
        // paint over the edge that says which pane the keyboard is in.
        attentionWash.wantsLayer = true
        attentionWash.layer?.opacity = 0
        // Drawn rather than a layer background colour, so that it takes the same
        // corner path everything else on the bar takes. A background colour fills
        // the layer's rectangle, and a pane in the corner would have worn a square
        // red block against a bar that curves away from it. The fade still happens
        // on `opacity`, which is why this is a layer of its own.
        attentionWash.render = { [weak self] bounds in self?.drawCapsuleFill(in: bounds) }
        addSubview(attentionWash)

        contentView.render = { [weak self] bounds in self?.drawContent(in: bounds) }
        addSubview(contentView)

        barFrame.wantsLayer = true
        barFrame.layer?.opacity = 0
        barFrame.render = { [weak self] bounds in self?.drawBarFrame(in: bounds) }
        addSubview(barFrame)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("baia does not use nibs")
    }

    /// Two separate refusals, because AppKit offers two routes in:
    /// `acceptsFirstResponder` covers a click and a programmatic
    /// `makeFirstResponder`, and `canBecomeKeyView` covers tabbing through the
    /// key view loop.
    ///
    /// `refusesFirstResponder` is not the third: it is declared on `NSControl`,
    /// not `NSView`. Reaching for it is a sign of having made the footer a
    /// control, which is the thing to avoid.
    override var acceptsFirstResponder: Bool { false }

    override var canBecomeKeyView: Bool { false }

    /// Raised when the footer is clicked outside the capsule (or the capsule
    /// draws nothing pressable), so the pane can focus itself.
    var onClick: (() -> Void)?

    /// Raised instead of ``onClick`` when the click lands inside the capsule's
    /// own frame on a bar whose attention is asking or acknowledged — the one
    /// case ``ApprovalPopover/presents(for:)`` says has something to open.
    /// Carries the capsule's frame in this view's own coordinates, which is
    /// what the caller converts to the screen to anchor the popover: this view
    /// is the one thing that knows both the frame and the window it sits in,
    /// and a caller re-deriving either would risk disagreeing with what was
    /// actually drawn.
    var onCapsuleClick: ((NSRect) -> Void)?

    /// The footer is 22 pt of opaque view over the pane, and the child content
    /// view returns nil from `hitTest` while this one did not, so a click landing
    /// on the strip resolved here and stopped: the pane stayed scrimmed and the
    /// keyboard stayed where it was. Handled as `mouseDown` rather than by
    /// returning nil from `hitTest`, because the container underneath does
    /// nothing with the click either.
    ///
    /// A click inside the capsule while it has something to open routes to
    /// ``onCapsuleClick`` instead of ``onClick``, per the plan's "the rest of
    /// the bar keeps its click-to-focus behaviour": the capsule is the one
    /// pressable-looking thing on the bar, and everywhere else on it still
    /// only focuses the pane.
    ///
    /// Safe against the rule above: `acceptsFirstResponder` stays false, and
    /// AppKit does not make a view first responder for implementing `mouseDown`.
    override func mouseDown(with event: NSEvent) {
        if let capsule = capsuleRect(), ApprovalPopover.presents(for: attention) {
            let point = convert(event.locationInWindow, from: nil)
            if capsule.contains(point) {
                onCapsuleClick?(capsule)
                return
            }
        }
        onClick?()
    }

    /// Height only. The width comes from the pane, and claiming a width here
    /// would fight the terminal for horizontal space.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: PaneStatusBarMetrics.height)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        for child in [attentionWash, contentView, barFrame] {
            child.frame = bounds
            child.needsDisplay = true
        }
        if let glassBacking {
            glassBacking.frame = bounds
            updateGlassMask()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidate()
    }

    private func invalidate() {
        needsDisplay = true
        // Held at its target rather than re-animated when the pane is already
        // asking, so a redraw mid-wait does not restart the fade. A marker that
        // pulsed on every git poll would be one the eye learns to ignore.
        if attentionWash.layer?.animationKeys()?.isEmpty ?? true {
            attentionWash.layer?.opacity = showsCapsuleFill ? 1 : 0
        }
        attentionWash.needsDisplay = true
        contentView.needsDisplay = true
        barFrame.needsDisplay = true
        applyBarFrameOpacity()
        // The glass backing has no `draw(_:)` of its own, so a theme or focus
        // change still has to reach its tint here even though the tint is
        // now always nil (Task 2): a stale non-nil tint left by some future
        // caller must not survive a change that runs through `invalidate()`.
        updateGlassTint()
    }

    // MARK: - Chrome material

    /// The material set glass resolves to, or nil under flat. One place to
    /// unwrap ``resolvedChrome`` for every reader below rather than a `switch`
    /// repeated at each of them.
    ///
    /// **Untinted glass (Task 2).** Nothing below reads ``MaterialSet/fillChrome``
    /// or ``MaterialSet/fillThick`` any more: the footer's glass backing draws
    /// no fill of its own and carries no tint (see ``updateGlassTint()``), and
    /// `draw(_:)` no longer paints a material fill under glass either. Every
    /// remaining read of this property (`draw(_:)`'s own) only asks whether it
    /// is `nil`, i.e. whether chrome is flat or glass at all — none reads the
    /// `MaterialSet`'s fields. It is kept as a resolved value, rather than
    /// narrowed to a `Bool`, because a later task's rim/lift work needs the
    /// resolved set itself; today it is not a source of anything this file
    /// fills or tints with.
    private var materialSet: MaterialSet? {
        switch resolvedChrome {
        case .flat: nil
        case let .glass(set): set
        }
    }

    /// Creates or tears down ``glassBacking`` to match ``resolvedChrome``, and
    /// repaints: `draw(_:)` reads ``materialSet`` too, to know whether to skip
    /// its own fill (Task 2 — glass draws none).
    ///
    /// Verified against the installed SDK before this package's Task 4 built on
    /// it (see the plan's Task 4 gate): `NSGlassEffectView.cornerRadius`,
    /// `.tintColor`, `.style` and `.contentView` all compile against macOS 26,
    /// unguarded, matching `project.yml`'s deployment target, so this is the
    /// real glass view rather than the `NSVisualEffectView` fallback the plan
    /// named for the case a member was missing.
    private func applyResolvedChrome() {
        switch resolvedChrome {
        case .flat:
            glassBacking?.removeFromSuperview()
            glassBacking = nil
        case .glass:
            let backing: PaneStatusGlassBacking
            if let existing = glassBacking {
                backing = existing
            } else {
                backing = PaneStatusGlassBacking(frame: bounds)
                backing.style = .regular
                backing.wantsLayer = true
                // Below everything: added first, ahead of `attentionWash`, so the
                // bar's own drawing still lands on top of it.
                addSubview(backing, positioned: .below, relativeTo: attentionWash)
                glassBacking = backing
            }
            backing.cornerRadius = 0 // The mask carries the window's own squircle instead; see `updateGlassMask()`.
        }
        updateGlassMask()
        invalidate()
    }

    /// Keeps ``glassBacking``'s tint nil, or does nothing under flat where
    /// there is no backing to write to.
    ///
    /// **Untinted glass (Task 2).** `NSGlassEffectView.tintColor` used to carry
    /// ``MaterialSet/fillChrome`` or ``MaterialSet/fillThick``, stepped by
    /// focus; the spike at `Diagnostics/glass-backdrop/` measured the tint+fill
    /// layers as the largest single term in the bar's appearance and found they
    /// pin it near mid-grey, defeating the material's own adaptation.
    /// Untinted `regular` glass is the platform-correct default (HIG: glass is
    /// colorless unless one element is deliberately accented), so this writes
    /// `nil` explicitly rather than leaving the property untouched.
    ///
    /// Still routed through ``invalidate()`` rather than set once at creation:
    /// a stale non-nil tint left over from a future accented element (the
    /// capsule, a later task) must not survive a focus change or a theme
    /// change reaching this bar, the same Ghostty #9973 lesson the constraint
    /// names.
    private func updateGlassTint() {
        guard let glassBacking else { return }
        glassBacking.tintColor = nil
    }

    /// Clips ``glassBacking`` to the same outline the drawn fill clips to in
    /// `draw(_:)`, so the glass does not square off a corner the window itself
    /// rounds.
    ///
    /// `NSGlassEffectView.cornerRadius` draws a uniform radius on every corner,
    /// which is the wrong shape twice over for this bar: it would round corners
    /// the window does not cut as well as the ones it does, and a circular arc
    /// beside the window's own squircle reads as a visible mismatch the way
    /// `WindowCorner`'s own doc comment measures for the drawn frame. A
    /// `CAShapeLayer` mask built from the identical `WindowCorner.path` is what
    /// keeps the glass and the drawn fill agreeing about the shape.
    private func updateGlassMask() {
        guard let glassBacking, let layer = glassBacking.layer else { return }
        guard bounds.width > 0, bounds.height > 0 else { return }
        let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.frame = bounds
        mask.path = WindowCorner.cgPath(in: bounds, corners: bottomCorners)
        layer.mask = mask
    }

    // MARK: - State

    private var attention: PaneStatus.Attention { status?.attention ?? .none }

    /// Gated on ``isWindowActive`` as well as focus. An accent stroke left on a
    /// background window would leave one pane un-recessed in a window that is
    /// meant to read as one recessed object. See ``isWindowActive`` for why the
    /// anchor name does not go with it.
    private var framesForFocus: Bool {
        isFocused && isWindowActive
    }

    /// Fades rather than cuts. Focus moves on every click, and a hard step
    /// across four panes reads as the window flashing.
    private func applyBarFrameOpacity() {
        guard let layer = barFrame.layer else { return }
        let target: Float = framesForFocus ? 1 : 0
        guard layer.opacity != target else { return }

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = target
            CATransaction.commit()
            return
        }

        let fade = CABasicAnimation(keyPath: "opacity")
        // The presentation value, not the model one. The model was written to
        // its target by the previous call, so reading it starts a reversal from
        // where the last fade *ended* rather than from where it currently is:
        // clicking A, B, A inside 160 ms would snap to 0 and animate back, which
        // is the hard step this method exists to avoid.
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = target
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        layer.opacity = target
        layer.add(fade, forKey: "baia.barFrame")
    }

    /// The 2 pt inset stroke, in the same ink as the anchor name.
    ///
    /// Inset by half the width so the stroke lands inside the bar rather than
    /// straddling its edge, which on the bottom edge would put a point of it
    /// outside the view and clip it to one.
    ///
    /// Below `frameCollapseWidth` the sides are dropped and it becomes a
    /// bracket: two filled rects at the full width, no path, so there is no
    /// rectangle left to read as a chip.
    ///
    /// Painted whether or not the pane is focused, because ``barFrame``'s
    /// `opacity` is the only thing that decides whether it is seen. Gating the
    /// paint on focus as well would clear the layer's contents on the same pass
    /// that starts the fade *out*, so leaving a pane would cut rather than fade
    /// and only half of ``applyBarFrameOpacity`` would be true. Nothing read
    /// here may depend on `isFocused` for the same reason, which is why the ink
    /// below is spelled with `focused: true` baked in rather than routed through
    /// ``colour(for:)``: that helper answers `#bbbbbb` for an unfocused pane and
    /// would flash the frame grey on its way out.
    private func drawBarFrame(in rect: NSRect) {
        let width = PaneStatusBarMetrics.focusFrameWidth
        let ink = theme.inkFocus
        nsColor(ink).setStroke()
        nsColor(ink).setFill()

        // The view is flipped, so `y: 0` is the edge against the terminal and
        // `rect.height - width` is the edge against the window.
        guard PaneStatusBarMetrics.framesSides(atWidth: Double(rect.width)) else {
            NSRect(x: 0, y: 0, width: rect.width, height: width).fill()
            // The bracket's lower bar lands on the curved edge, so it is cut to
            // the same shape as the fill under it. A square bar there would put
            // the one thing that says "this pane" outside the window's outline,
            // where the system mask takes a bite out of it.
            NSGraphicsContext.saveGraphicsState()
            cornerPath(in: rect).addClip()
            NSRect(x: 0, y: rect.height - width, width: rect.width, height: width).fill()
            NSGraphicsContext.restoreGraphicsState()
            return
        }

        // Inset by half the stroke width, and the radius comes down by the same
        // amount, which is what keeps the frame concentric with the window rather
        // than crossing it through the corner.
        let path = cornerPath(in: rect, inset: width / 2)
        path.lineWidth = width
        path.stroke()
    }

    /// The one outline the bar is drawn to: its own rectangle, with any corner it
    /// shares with the window curved to match.
    ///
    /// Every surface goes through this rather than each drawing its own shape.
    /// The bug being fixed is two shapes disagreeing at the same corner, so a
    /// second spelling of it anywhere is the bug coming back.
    private func cornerPath(in rect: NSRect, inset: Double = 0) -> NSBezierPath {
        WindowCorner.path(in: rect, corners: bottomCorners, inset: inset)
    }

    /// The colour every attention mark on this bar is drawn in: the capsule fill,
    /// its stroke once acknowledged, and the glyph ink asking derives from it.
    ///
    /// One property feeding all of them, and the pane frame is derived from the
    /// same call in ``TerminalPaneController``. A value spelled per site is a
    /// footer whose capsule and whose frame can disagree about what attention
    /// looks like.
    ///
    /// `PaneTheme.alert` is deliberately still reached directly by the git
    /// segments, through `PaneStatusSegments` and the `.alert` emphasis. Red means
    /// conflict whatever this resolves to.
    private var attentionColour: RGB {
        theme.attentionColour(attentionAccent, behavior: alertBehavior)
    }

    // MARK: - Base drawing

    override func draw(_: NSRect) {
        // Clipped rather than filled through the path, so the hairline below is
        // cut by the same outline without having to be built as a second shape.
        // The bar's fill already looked round, because the window's mask was
        // cutting it; what this changes is that everything else on the bar now
        // stops where the fill does.
        NSGraphicsContext.saveGraphicsState()
        cornerPath(in: bounds).addClip()
        // Flat draws its own opaque fill, unchanged from what Plan 1 shipped.
        // Glass draws no fill at all (Task 2): `draw(_:)` is this view's base
        // layer, which every subview (including `glassBacking`) renders above,
        // so any fill here — opaque or translucent — would sit under the glass
        // and either hide it or repeat the tint `updateGlassTint()` just
        // dropped. Leaving this layer transparent under glass is what lets the
        // glass view's own blur and vibrancy read with nothing painted between
        // it and the terminal beneath.
        if materialSet == nil {
            nsColor(theme.barBackground).setFill()
            bounds.fill()
        }
        drawHairline()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// True when the capsule is tinted, which is the only fill this bar draws
    /// and the only thing the arrival pulse animates. Both volumes: the capsule
    /// is the v5 resolution of "findable without shouting", and `loud` keeps
    /// the whole-pane frame on top of it (`TerminalPaneController` gates that).
    private var showsCapsuleFill: Bool {
        attention == .asking
    }

    /// The tinted capsule (asking). On its own layer so the arrival pulse can
    /// run on opacity beneath a glyph that never fades.
    private func drawCapsuleFill(in rect: NSRect) {
        guard let frame = capsuleRect() else { return }
        nsColor(attentionColour).setFill()
        NSBezierPath(
            roundedRect: frame,
            xRadius: frame.height / 2,
            yRadius: frame.height / 2
        ).fill()
    }

    private static let capsuleGlyphFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .heavy)

    /// The capsule's glyph for the current level, measured once per draw pass.
    private func capsuleGlyph(ink: RGB) -> NSAttributedString? {
        let text: String? = switch attention {
        case .asking, .acknowledged: "!"
        case .done: "\u{2713}"
        case .none: nil
        }
        guard let text else { return nil }
        return NSAttributedString(string: text, attributes: [
            .font: Self.capsuleGlyphFont,
            .foregroundColor: nsColor(ink),
        ])
    }

    /// Where the capsule sits, or nil at a level that draws none. One call
    /// into the metrics so the fill, the stroke, the glyph and the popover
    /// anchor cannot disagree (v5 open item 2).
    private func capsuleRect() -> NSRect? {
        guard attention == .asking || attention == .acknowledged else { return nil }
        let width = Double(glyphWidth())
        let frame = PaneStatusBarMetrics.attentionCapsuleFrame(glyphWidth: width)
        return NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    private func glyphWidth() -> CGFloat {
        capsuleGlyph(ink: theme.foreground)?.size().width ?? 0
    }

    /// The capsule's frame in this view's coordinates, for the approval
    /// popover to spring from. Nil when nothing pressable-looking is drawn,
    /// which includes `done`: a ✓ is a fact, not a question to open.
    var attentionCapsuleFrame: NSRect? { capsuleRect() }

    /// A one-point separator at the bottom edge rather than the top, so the
    /// terminal grid above meets the footer with no gap. Drawn as a blend rather
    /// than a system separator colour because the footer tracks the terminal
    /// theme, not the system appearance: a pane on a dark theme under a light
    /// system appearance would otherwise grow a bright line across it.
    private func drawHairline() {
        let hairline = NSRect(
            x: 0,
            y: bounds.maxY - PaneStatusBarMetrics.hairlineHeight,
            width: bounds.width,
            height: PaneStatusBarMetrics.hairlineHeight
        )
        nsColor(theme.hairline).setFill()
        hairline.fill()
    }

    // MARK: - Content drawing

    private func drawContent(in rect: NSRect) {
        var offset: Double = 0
        switch attention {
        case .asking, .acknowledged:
            guard let capsule = capsuleRect() else { break }
            if attention == .acknowledged {
                // Stroked here rather than on the wash view: nothing animates
                // at this level, and a stroke under a pulsing fill would be
                // the wrong z-order anyway.
                let stroke = NSBezierPath(
                    roundedRect: capsule.insetBy(dx: 0.5, dy: 0.5),
                    xRadius: (capsule.height - 1) / 2,
                    yRadius: (capsule.height - 1) / 2
                )
                stroke.lineWidth = 1
                nsColor(attentionColour).setStroke()
                stroke.stroke()
            }
            let ink = attention == .asking ? theme.ink(on: attentionColour) : attentionColour
            if let glyph = capsuleGlyph(ink: ink) {
                glyph.draw(at: NSPoint(
                    x: capsule.midX - glyph.size().width / 2,
                    y: capsule.midY - glyph.size().height / 2
                ))
            }
            offset = PaneStatusBarMetrics.attentionLeadingAdvance(
                for: attention,
                glyphWidth: Double(glyphWidth()),
                doneGlyphWidth: 0
            )
        case .done:
            // The done glyph is drawn straight on the bar's own surface, same as
            // every ordinary run, so it is judged against the same
            // ``effectiveBarFill`` those go through: ``theme.barBackground``
            // on both flat and glass now (Task 2 — the repair chain no longer
            // grades glass ink against the material fill at all).
            let ink = theme.ink(on: effectiveBarFill)
            if let glyph = capsuleGlyph(ink: ink) {
                glyph.draw(at: NSPoint(
                    x: PaneStatusBarMetrics.horizontalInset,
                    y: Double(rect.height) / 2 - glyph.size().height / 2
                ))
                offset = PaneStatusBarMetrics.attentionLeadingAdvance(
                    for: .done,
                    glyphWidth: 0,
                    doneGlyphWidth: Double(glyph.size().width)
                )
            }
        case .none:
            break
        }

        guard let status else { return }
        let segments = PaneStatusSegments.build(from: status)
        guard !segments.isEmpty else { return }

        let rendered = segments.map { render($0) }
        let solved = PaneStatusLayout.solve(
            segments: segments,
            widths: rendered.map(\.width),
            // The full bar width. `solve` subtracts the insets itself, and
            // subtracting them here as well is what used to cost the bar 16 pt of
            // usable width and push every segment to twice its intended inset.
            availableWidth: Double(rect.width) - offset
        )

        for placed in solved.placed {
            guard let index = segments.firstIndex(of: placed.segment) else { continue }
            draw(rendered[index], at: placed.x + offset, width: placed.width, in: rect)
        }
    }

    /// One segment, ready to measure and draw.
    private struct Rendered {
        var string: NSAttributedString
        var role: PaneStatusSegmentRole
        /// Space reserved before the text for a dot or a chip's left padding.
        var leadingOrnament: Double
        /// Space reserved after it, for a chip's right padding.
        var trailingOrnament: Double

        var width: Double {
            Double(string.size().width) + leadingOrnament + trailingOrnament
        }
    }

    private func render(_ segment: PaneStatusSegment) -> Rendered {
        let bold = segment.role == .agent && attention == .asking
        let font = Self.font(for: segment.role, emphatic: bold)

        let paragraph = NSMutableParagraphStyle()
        // The path is informative at its tail and the names at their head, which
        // is why truncation is per-segment rather than one style for the bar.
        switch segment.truncation {
        case .head: paragraph.lineBreakMode = .byTruncatingHead
        case .tail: paragraph.lineBreakMode = .byTruncatingTail
        case .none: paragraph.lineBreakMode = .byClipping
        }

        let string = NSMutableAttributedString()
        for run in segment.runs {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: nsColor(colour(for: run.emphasis)),
                .paragraphStyle: paragraph,
            ]
            // Letterspacing on the chip only. It is a label rather than a word,
            // and the tracking is most of what stops `PIN` reading as part of the
            // sentence the bar is not.
            if segment.role == .pin { attributes[.tracking] = font.pointSize * 0.06 }
            string.append(NSAttributedString(string: run.text, attributes: attributes))
        }

        let busy = segment.role == .agent && (status?.agent?.isBusy ?? false) && attention == .none
        return Rendered(
            string: string,
            role: segment.role,
            leadingOrnament: PaneStatusBarMetrics.leading(
                for: segment.role,
                busy: busy,
                chipPadding: Self.chipPadding,
                busyDotAdvance: Self.dotDiameter + Self.dotGap
            ),
            trailingOrnament: segment.role == .pin ? Self.chipPadding : 0
        )
    }

    /// The surface this bar's text is judged readable against.
    ///
    /// `theme.barBackground`, unconditionally, on both flat and glass.
    ///
    /// **Task 2 (untint the chrome), superseding Task 4's original clause:**
    /// this used to flatten the glass material's own fill onto `theme.background`
    /// as an "honest approximation" for the repair chain to grade glass text
    /// against, on the reasoning that this package cannot see what the
    /// compositor actually draws under a translucent bar. The three-round
    /// spike at `Diagnostics/glass-backdrop/` (its README is the measured
    /// record) found that approximation predicts roughly 2.09:1 contrast for
    /// ink graded against the well colour, while the glass measured 9.49:1 in
    /// practice: real vitreous glass supplies its own legibility (the system
    /// compositor's own vibrancy/adaptation), which grading against a flattened
    /// swatch cannot see and actively fights. So the repair chain now applies
    /// to the flat/Reduce-Transparency rendering only; glass paths take the
    /// same ungraded ``theme.barBackground``-judged ink flat always used,
    /// carrying no glass-specific grading at all.
    private var effectiveBarFill: RGB {
        theme.barBackground
    }

    /// The colour a run is drawn in. Tested against `focused` alone in
    /// ``PaneChrome/PaneTheme/color(for:focused:)``: the bar itself no longer
    /// fills for attention, so there is no second surface to judge a run
    /// against.
    private func colour(for emphasis: PaneStatusEmphasis) -> RGB {
        theme.color(for: emphasis, focused: isFocused, on: effectiveBarFill)
    }

    private func draw(_ rendered: Rendered, at x: Double, width: Double, in rect: CGRect) {
        let font = (rendered.string.length > 0
            ? rendered.string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            : nil) ?? Self.font(for: rendered.role, emphatic: false)

        if rendered.role == .pin { drawChip(at: x, width: width, in: rect) }
        if rendered.leadingOrnament > 0, rendered.role == .agent { drawBusyDot(at: x, in: rect) }

        // One baseline for the whole bar rather than each segment centred in the
        // height. Four point sizes centred independently sit a fraction of a point
        // apart, which does not read as a difference. It reads as a mistake.
        let textX = x + rendered.leadingOrnament
        let textWidth = max(0, width - rendered.leadingOrnament - rendered.trailingOrnament)
        let box = NSRect(
            x: textX,
            y: PaneStatusBarMetrics.baselineFromTop - Double(font.ascender),
            width: textWidth,
            height: Double(font.ascender - font.descender)
        )
        rendered.string.draw(with: box, options: [.usesLineFragmentOrigin])
    }

    /// The pin, as an outlined chip rather than a word in a sentence.
    ///
    /// Stroked rather than filled, and stroked in `plank`, so it reads as a
    /// label attached to the name without competing with it. Inset by half a
    /// point so the one-point stroke lands on the pixel rather than straddling
    /// it.
    ///
    /// Unconditionally `plank`: the bar itself no longer fills for attention,
    /// so there is no second backdrop the chip's border needs judging against.
    private func drawChip(at x: Double, width: Double, in rect: CGRect) {
        let box = NSRect(
            x: x + 0.5,
            y: (rect.height - Self.chipHeight) / 2 + 0.5,
            width: max(0, width - 1),
            height: Self.chipHeight - 1
        )
        let path = NSBezierPath(roundedRect: box, xRadius: Self.chipRadius, yRadius: Self.chipRadius)
        path.lineWidth = 1
        nsColor(theme.plank).setStroke()
        path.stroke()
    }

    /// The working-agent dot. No motion: this is the state most panes are in most
    /// of the time, and a spinner in every footer would make a quiet workspace
    /// look like a busy one.
    private func drawBusyDot(at x: Double, in rect: CGRect) {
        let box = NSRect(
            x: x,
            y: (rect.height - Self.dotDiameter) / 2,
            width: Self.dotDiameter,
            height: Self.dotDiameter
        )
        nsColor(theme.ok).setFill()
        NSBezierPath(ovalIn: box).fill()
    }

    // MARK: - The arrival pulse

    /// Fires once, on the transition into an unacknowledged ask.
    ///
    /// Opacity only, on the wash below the text, so nothing moves and nothing
    /// above a terminal grid is asked to animate. It runs once and then holds:
    /// a marker that keeps pulsing while it waits is one the eye learns to
    /// ignore, and this one has to still work an hour later.
    private func runArrivalPulse() {
        guard showsCapsuleFill, let washLayer = attentionWash.layer else { return }
        washLayer.removeAllAnimations()

        // Reduce-motion skips to the final frame rather than to nothing. The
        // signal is the point; the animation is only how it arrives.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            washLayer.opacity = 1
            return
        }

        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0, 1, 1, 0.4, 1]
        pulse.keyTimes = [0, 0.235, 0.422, 0.676, 1].map(NSNumber.init(value:))
        pulse.duration = 0.51
        pulse.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        pulse.repeatCount = 1
        pulse.isRemovedOnCompletion = true
        washLayer.opacity = 1
        washLayer.add(pulse, forKey: "baia.attention.arrival")
    }

    // MARK: - Constants

    private static let chipPadding: Double = 4
    private static let chipHeight: Double = 13
    private static let chipRadius: Double = 2
    private static let dotDiameter: Double = 5
    private static let dotGap: Double = 5

    /// Proportional for the name, monospaced for machine data.
    ///
    /// The font change is the tier boundary, and that is what makes the hierarchy
    /// survive segments vanishing: when the branch disappears and the anchor name
    /// is alone on the bar, the name still looks like a name rather than like
    /// whatever happened to be left.
    private static func font(for role: PaneStatusSegmentRole, emphatic: Bool) -> NSFont {
        switch role {
        case .anchorName: NSFont.systemFont(ofSize: 11, weight: .semibold)
        case .pin: NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        case .agent: NSFont.systemFont(ofSize: 10.5, weight: emphatic ? .bold : .regular)
        case .operation: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .bold)
        case .branch, .indicators: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        case .workingDirectory: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        // Proportional and the same size as the anchor name, because a notice is
        // a sentence to be read rather than machine data to be scanned, and the
        // font change is what carries that distinction on this bar. Not semibold:
        // it already arrives in the alert colour and alone on the bar, and a
        // third emphasis on top of those two is shouting.
        case .notice: NSFont.systemFont(ofSize: 11, weight: .regular)
        }
    }

    /// Built in explicit sRGB. `NSColor(red:green:blue:alpha:)` uses the calibrated
    /// device space, which shifts the terminal's own colours against the same hex
    /// value rendered by ghostty, so the footer and the grid would disagree about
    /// what `#141414` looks like.
    ///
    /// `alpha` defaults to opaque, which is every call site on this bar: this
    /// view draws nothing translucent of its own (Task 2 dropped the glass
    /// backing's tinted fill, its one remaining exception), so every colour
    /// it hands to `setFill()`/`setStroke()` is opaque over the terminal, per
    /// ``PaneChrome/RGB``'s own doc comment.
    private func nsColor(_ rgb: PaneChrome.RGB, alpha: Double = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat(rgb.red),
            green: CGFloat(rgb.green),
            blue: CGFloat(rgb.blue),
            alpha: CGFloat(alpha)
        )
    }
}
