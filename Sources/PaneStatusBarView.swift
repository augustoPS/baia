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
        }
    }

    private let attentionWash = PaneStatusContentView(frame: .zero)
    private let contentView = PaneStatusContentView(frame: .zero)
    /// Above the text rather than below it, so a filled bar cannot swallow the
    /// frame. Its own view because the fade is on `opacity`, and animating a
    /// value that `draw(_:)` paints would mean redrawing the text for 160 ms.
    private let barFrame = PaneStatusContentView(frame: .zero)

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
        attentionWash.render = { [weak self] bounds in self?.drawAttentionWash(in: bounds) }
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

    /// Raised when the footer is clicked, so the pane can focus itself.
    var onClick: (() -> Void)?

    /// The footer is 22 pt of opaque view over the pane, and the child content
    /// view returns nil from `hitTest` while this one did not, so a click landing
    /// on the strip resolved here and stopped: the pane stayed scrimmed and the
    /// keyboard stayed where it was. Handled as `mouseDown` rather than by
    /// returning nil from `hitTest`, because the container underneath does
    /// nothing with the click either.
    ///
    /// Safe against the rule above: `acceptsFirstResponder` stays false, and
    /// AppKit does not make a view first responder for implementing `mouseDown`.
    override func mouseDown(with _: NSEvent) {
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
            attentionWash.layer?.opacity = fillsBarForAttention ? 1 : 0
        }
        attentionWash.needsDisplay = true
        contentView.needsDisplay = true
        barFrame.needsDisplay = true
        applyBarFrameOpacity()
    }

    // MARK: - State

    private var attention: PaneStatus.Attention { status?.attention ?? .none }

    /// True when the bar itself is filled with the alert colour, which is the
    /// only reason a bar fills.
    ///
    /// Both terms matter: only the unacknowledged level fills anything, and only
    /// at the loud volume. `quiet` spends an edge instead, so that an asking pane
    /// can be read without the bar's background being spent on it.
    private var fillsBarForAttention: Bool {
        attention == .asking && attentionStyle == .loud
    }

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
    /// would flash the frame grey on its way out. ``fillsBarForAttention`` is
    /// safe, since it reads the attention level and not the focus state.
    private func drawBarFrame(in rect: NSRect) {
        let width = PaneStatusBarMetrics.focusFrameWidth
        // Judged against the surface the frame is actually on, the way the chip
        // below already is. `inkFocus` is repaired against `barBackground` and
        // scores 2.08:1 on `alert`, so a focused pane that is also asking, which
        // is the default pairing and the state the owner is in every time he
        // answers an agent, would wear a frame nobody can see. `ink(on:)` is the
        // same colour the anchor name takes on that fill, at 5.86:1, so the two
        // stay one signal rather than two.
        let ink = fillsBarForAttention ? theme.ink(on: inkBackground) : theme.inkFocus
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

    /// The colour every attention mark on this bar is drawn in: the wash, the
    /// quiet line, and the acknowledged square.
    ///
    /// One property feeding all three, and the pane frame is derived from the same
    /// call in ``TerminalPaneController``. The three marks are one signal at three
    /// volumes, so a value spelled per site is a footer whose quiet line and whose
    /// fill can disagree about what attention looks like.
    ///
    /// `PaneTheme.alert` is deliberately still reached directly by the git
    /// segments, through `PaneStatusSegments` and the `.alert` emphasis. Red means
    /// conflict whatever this resolves to.
    private var attentionColour: RGB {
        theme.attentionColour(attentionAccent, behavior: alertBehavior)
    }

    /// The surface the text is judged against: the attention wash when there is
    /// one, and the bar's own background otherwise.
    ///
    /// The wash is a layer above what ``draw(_:)`` paints, so that it can fade in
    /// without taking the text with it, which is why the two are named separately
    /// here rather than the fill simply being drawn.
    private var inkBackground: RGB {
        fillsBarForAttention ? attentionColour : theme.barBackground
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
        nsColor(theme.barBackground).setFill()
        bounds.fill()
        drawHairline()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The attention fill, on the same outline as the bar under it.
    private func drawAttentionWash(in rect: NSRect) {
        nsColor(attentionColour).setFill()
        cornerPath(in: rect).fill()
    }

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
        // The quiet attention treatment: a line along the top edge instead of a
        // filled band. It spends an edge rather than the bar's background, which
        // is what keeps the footer legible while someone is working in the pane.
        if attention == .asking, !fillsBarForAttention {
            nsColor(attentionColour).setFill()
            // Pushed inside the focus frame rather than under it. Both land on
            // the same two points of the top edge and the frame is drawn above
            // this view, so at y 0 the attention mark on a focused pane is not
            // merely covered, it is gone: `quiet` has no arrival pulse either,
            // by construction, so nothing else would have said the pane asked.
            let y = framesForFocus ? PaneStatusBarMetrics.focusFrameWidth : 0
            NSRect(x: 0, y: y, width: rect.width, height: PaneStatusBarMetrics.attentionLine).fill()
        }

        // The acknowledged mark. The smallest thing on the bar that is not grey,
        // which is what lets it survive a glance across six panes without pulling
        // at the eye of someone working in the pane beside it.
        if attention == .acknowledged {
            nsColor(attentionColour).setFill()
            NSRect(
                x: PaneStatusBarMetrics.horizontalInset,
                y: (rect.height - Self.markSize) / 2,
                width: Self.markSize,
                height: Self.markSize
            ).fill()
        }

        // The acknowledged line, along the bottom edge.
        //
        // The square above is what the level looks like on the bar it sits in;
        // this is what carries it across a window. Added 2026-07-31, after a live
        // look at three panes could not tell an acknowledged one from a pane
        // asking nothing, which is the distance the level exists to survive.
        //
        // The bottom edge rather than the top, because the quiet treatment already
        // spends the top one. Two lines on the same edge would read as one signal
        // at two volumes rather than as the two different questions they answer,
        // "how loudly is this pane asking" and "have I been here since it asked".
        //
        // Clipped, unlike everything else in this method. `drawContent` renders
        // into its own view with no clip of its own, which costs nothing while the
        // marks sit inside the bar, and this is the first thing here to reach the
        // corner the pane shares with the window.
        if attention == .acknowledged {
            NSGraphicsContext.saveGraphicsState()
            cornerPath(in: rect).addClip()
            nsColor(attentionColour).setFill()
            // Inside the focus frame, for the reason the quiet line is pushed
            // inside it: the frame is stroked over this view, so a line on the
            // extreme edge is not covered on a focused pane, it is gone.
            let inset = framesForFocus ? PaneStatusBarMetrics.focusFrameWidth : 0
            NSRect(
                x: 0,
                y: rect.maxY - inset - PaneStatusBarMetrics.attentionLine,
                width: rect.width,
                height: PaneStatusBarMetrics.attentionLine
            ).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        guard let status else { return }
        let segments = PaneStatusSegments.build(from: status)
        guard !segments.isEmpty else { return }

        let rendered = segments.map { render($0) }
        let offset = attention == .acknowledged ? Self.markSize + Self.markGap : 0
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

    /// The colour a run is drawn in. The fill collapse itself lives in
    /// ``PaneChrome/PaneTheme/color(for:focused:filled:on:)``, tested there.
    private func colour(for emphasis: PaneStatusEmphasis) -> RGB {
        theme.color(for: emphasis, focused: isFocused, filled: fillsBarForAttention, on: inkBackground)
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
    private func drawChip(at x: Double, width: Double, in rect: CGRect) {
        let box = NSRect(
            x: x + 0.5,
            y: (rect.height - Self.chipHeight) / 2 + 0.5,
            width: max(0, width - 1),
            height: Self.chipHeight - 1
        )
        let path = NSBezierPath(roundedRect: box, xRadius: Self.chipRadius, yRadius: Self.chipRadius)
        path.lineWidth = 1
        // Blended against the surface the chip is actually drawn on, not against
        // `barBackground`. When the bar is filled for attention the real backdrop
        // is ``attentionColour``, and judging the stroke against the unfilled
        // colour dropped it to 1.85:1 on exactly the pane that most wanted
        // reading. `plank` on an ordinary bar, because the chip's border and the
        // icon's dividers are one derivation. Everything on a filled bar is
        // relative to `inkBackground` for this reason, which is also what carries
        // the chip through a fill the config moved.
        let stroke = fillsBarForAttention
            ? colour(for: .context).blended(with: inkBackground, fraction: 0.45)
            : theme.plank
        nsColor(stroke).setStroke()
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
        guard fillsBarForAttention, let washLayer = attentionWash.layer else { return }
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
    private static let markSize: Double = 6
    private static let markGap: Double = 6

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
        }
    }

    /// Built in explicit sRGB. `NSColor(red:green:blue:alpha:)` uses the calibrated
    /// device space, which shifts the terminal's own colours against the same hex
    /// value rendered by ghostty, so the footer and the grid would disagree about
    /// what `#141414` looks like.
    private func nsColor(_ rgb: PaneChrome.RGB) -> NSColor {
        NSColor(
            srgbRed: CGFloat(rgb.red),
            green: CGFloat(rgb.green),
            blue: CGFloat(rgb.blue),
            alpha: 1
        )
    }
}
