import AppKit
import PaneChrome
import WorkspaceLayout

/// Common ground for anything drawn *over* a terminal surface.
///
/// Everything here is untouchable by design, in three ways that AppKit keeps
/// separate. `acceptsFirstResponder` covers a click and a programmatic
/// `makeFirstResponder`; `canBecomeKeyView` covers tabbing through the key view
/// loop; `hitTest` covers the mouse finding it at all. Missing any one of them
/// is the failure this whole family exists to avoid:
/// `AppTerminalView.performKeyEquivalent` opens with
/// `guard window?.firstResponder === self`, so a view that takes first responder
/// away from the terminal silently disables *every* ghostty key binding in that
/// pane, with no error and nothing on screen to explain it.
///
/// It is also why none of these is an `NSControl`. A scrim that dimmed on click
/// would be the obvious thing to reach for and it would cost the pane its
/// keyboard.
class PaneOverlayView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("baia does not use nibs")
    }

    override var acceptsFirstResponder: Bool { false }

    override var canBecomeKeyView: Bool { false }

    /// The mouse passes straight through to the terminal underneath. Returning
    /// `super` here would swallow every click in a pane the moment it lost focus,
    /// which is precisely the pane the user is clicking to focus.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    override var isFlipped: Bool { true }

    /// `.onSetNeedsDisplay` above buys the terminal a resize that repaints no
    /// overlay, and charges for it here: an overlay that draws anything short of
    /// a full-bounds fill keeps its old backing store when the pane grows. The
    /// attention frame paid it. Dragging the sidebar in left the frame's right
    /// edge standing at every width the drag passed through, a band of stripes
    /// across the terminal exactly as wide as the drag was long, because each
    /// step drew a new edge and none of them erased the last.
    ///
    /// Invalidating on a size change is the whole fix. The guard keeps a layout
    /// pass that resolves to the same size from queueing a repaint, which is most
    /// of them.
    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized { needsDisplay = true }
    }

    /// Built in explicit sRGB, so chrome and the terminal grid agree about what
    /// a hex value looks like.
    func nsColor(_ rgb: RGB, alpha: Double = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat(rgb.red),
            green: CGFloat(rgb.green),
            blue: CGFloat(rgb.blue),
            alpha: CGFloat(alpha)
        )
    }
}

/// The inactive-window treatment: the pane's own background, laid back over it.
///
/// Every pane in a window that is not key wears this, so the window reads as one
/// recessed object rather than as a window that still has a live pane in it.
/// macOS gives no other honest signal there, because the titlebar is
/// transparent, and the alternative of dimming each pane's own text is undone by
/// the contrast repair chain the moment the result drops under the minimum. A
/// scrim sits *above* the surface, so nothing repairs it away.
///
/// Nothing else scrims a pane. Marking the focused pane by taxing every other
/// one was tried and lost to the footer frame, and the panes it taxed were the
/// ones carrying agent output the owner reads without typing in.
final class PaneScrimView: PaneOverlayView {
    /// The pane's own terminal background. Deliberately not black and not the
    /// system's window background: over a light theme this lightens and over a
    /// dark one it darkens, so a pane recedes either way with no `isDark` branch
    /// anywhere in it.
    var colour: RGB = PaneTheme.darkPastel.background {
        didSet {
            guard colour != oldValue else { return }
            apply(animated: false)
        }
    }

    /// How far the pane is covered. 0 is off, which is what every pane of the key
    /// window sits at.
    var amount: Double = 0 {
        didSet {
            guard amount != oldValue else { return }
            apply(animated: true)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.backgroundColor = .clear
        apply(animated: false)
    }

    /// Fades rather than cuts, because focus moves on every click and a hard
    /// step across four panes reads as the window flashing. Opacity only: nothing
    /// above a terminal grid should move or scale, and a scrim that slid would
    /// be a scrim the eye follows instead of ignores.
    private func apply(animated: Bool) {
        guard let layer else { return }
        let target = nsColor(colour, alpha: amount).cgColor
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        guard animated, !reduceMotion else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.backgroundColor = target
            CATransaction.commit()
            return
        }

        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = layer.backgroundColor
        fade.toValue = target
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        layer.backgroundColor = target
        layer.add(fade, forKey: "baia.scrim")
    }
}

/// A 2 pt stroke just inside a pane's edge, marking the pane that is asking.
///
/// The one place in the design a frame leaves the footer and takes the whole
/// compartment. That is what makes attention rank above focus without either
/// needing to know about the other: focus takes the footer's edges and attention
/// takes the pane's, so a pane can be both at once and still be read correctly,
/// which is the state the owner is in every time he answers an agent.
///
/// Drawing over a terminal surface is only defensible because this is temporary
/// and because the alternative is missing an agent that is waiting.
/// `TerminalPaneController.applyPresentation` is the only caller.
final class PaneEdgeFrameView: PaneOverlayView {
    var colour: RGB = PaneTheme.darkPastel.alert {
        didSet {
            guard colour != oldValue else { return }
            needsDisplay = true
        }
    }

    var isVisible: Bool = false {
        didSet {
            guard isVisible != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Which of the window's bottom corners this pane sits in.
    ///
    /// Pushed from ``TerminalPaneController`` alongside the footer's copy, and for
    /// the same reason the footer has one: the frame and the footer meet at that
    /// corner, so a frame that kept its own shape there is the two disagreeing in
    /// the one place both are visible at once. Square-cornered by default, which
    /// is every pane away from the window's edge.
    var bottomCorners: BottomCorners = [] {
        didSet {
            guard bottomCorners != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Square wherever the pane is not against the window. A rounded frame inside
    /// a square pane leaves visible gaps at the corners where the terminal shows
    /// through, so only the corners the window's own mask cuts are curved and
    /// ``WindowCorner/path(in:corners:inset:)`` draws the other two as it always
    /// did, with straight lines meeting at a point.
    private static let thickness: Double = 2

    override func draw(_: NSRect) {
        guard isVisible else { return }
        // Inset by half the stroke width, and the radius comes down with it, so
        // the stroke's outer edge lands on the window's outline instead of
        // crossing it through the corner. The same concentric rule the footer's
        // focus frame is drawn under, and `WindowCorner` already applies it.
        let path = WindowCorner.path(
            in: bounds,
            corners: bottomCorners,
            inset: Self.thickness / 2
        )
        path.lineWidth = Self.thickness
        nsColor(colour).setStroke()
        path.stroke()
    }
}

/// The focused pane's lift, under glass: the hairline ring, inner highlight
/// and drop shadow design v5's Task 6 adds around the whole pane, replacing
/// the footer-only stroke for exactly the states glass is on.
///
/// Under flat, and under Reduce Transparency (which forces flat regardless of
/// the configured `chromeStyle`), this view stays invisible and the shipped
/// 1.5-2 pt `FocusAccent` stroke inside the footer (``PaneStatusBarView/drawBarFrame(in:)``)
/// remains the whole expression of focus, unchanged. `TerminalPaneController`
/// never sets ``isVisible`` under those conditions, and this view's own
/// nothing-drawn default (`isVisible = false`) is the same "no view drawn,
/// not merely hidden" guarantee ``PaneStatusBarView/glassBacking`` makes: a
/// lift that never shows keeps zero cost on a flat pane rather than an
/// invisible layer macOS still composites.
///
/// The ring and the inner highlight are drawn as strokes, the same
/// `draw(_:)` shape ``PaneEdgeFrameView`` uses; the drop shadow is a
/// `CALayer` shadow, because a shadow soft enough to read at 34 pt of blur is
/// not a shape `NSBezierPath.stroke()` can produce inside `draw(_:)` without
/// building a second, larger backing store to blur into.
final class PaneLiftView: PaneOverlayView {
    /// Whether the lift shows at all. Only the focused pane of the key window
    /// under a `glass`-resolved chrome ever sets this true;
    /// `TerminalPaneController.applyPresentation` is the only caller and the
    /// same three conditions (`isPaneFocused`, `isWindowActive`,
    /// `resolvedChrome` is `.glass`) that gate the thick footer fill gate
    /// this too, so the ring and the fill step never appear one without the
    /// other.
    var isVisible: Bool = false {
        didSet {
            guard isVisible != oldValue else { return }
            apply(animated: true)
        }
    }

    /// Which of the window's bottom corners this pane sits in, the same value
    /// pushed to ``PaneEdgeFrameView`` and the footer, so the lift's outline
    /// curves exactly where the window's own mask does and nowhere else.
    var bottomCorners: BottomCorners = [] {
        didSet {
            guard bottomCorners != oldValue else { return }
            needsDisplay = true
            updateShadowPath()
        }
    }

    /// The drop shadow, on a sublayer of its own, masked to the pane's
    /// *exterior*. A `CALayer` shadow given an explicit `shadowPath` renders
    /// the path's whole blurred silhouette, and on a transparent overlay
    /// nothing covers the interior of that silhouette, so the "shadow" read
    /// as a black veil over the focused pane's terminal (seen live
    /// 2026-08-06, the first glass launch). The even-odd mask cuts the
    /// interior out, leaving only the halo past the pane's edge, which is
    /// the only part a drop shadow honestly is.
    private let shadowLayer = CALayer()
    private let shadowMask = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOffset = CGSize(width: 0, height: ChromeMaterials.Lift.shadow.dropOffsetY)
        shadowLayer.shadowRadius = ChromeMaterials.Lift.shadow.dropBlur / 2
        shadowLayer.shadowOpacity = 0
        shadowMask.fillRule = .evenOdd
        shadowLayer.mask = shadowMask
        // Below the view's own content, so the ring and highlight stroke over
        // whatever sliver of halo lands inside the curve at the corners.
        layer?.insertSublayer(shadowLayer, at: 0)
        layer?.opacity = 0
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("baia does not use nibs")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateShadowPath()
    }

    /// A `CGPath`, not a rectangle: an unclipped rectangular shadow would
    /// square off the two corners the window itself rounds, the same
    /// mismatch ``PaneStatusBarView/updateGlassMask()`` exists to avoid on
    /// the footer's own glass backing.
    private func updateShadowPath() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let pane = WindowCorner.cgPath(in: bounds, corners: bottomCorners)
        shadowLayer.frame = bounds
        shadowLayer.shadowPath = pane
        // The mask's outer bound reaches past every point the blur and offset
        // can push the halo to, and the pane's own path is the even-odd
        // cutout. Both paths are in this layer's coordinate space; a shape
        // layer fills its path regardless of its frame, so the outer rect
        // extending beyond the bounds costs nothing.
        let reach = ChromeMaterials.Lift.shadow.dropBlur
            + abs(ChromeMaterials.Lift.shadow.dropOffsetY)
        let mask = CGMutablePath()
        mask.addRect(bounds.insetBy(dx: -reach, dy: -reach))
        mask.addPath(pane)
        shadowMask.frame = bounds
        shadowMask.path = mask
    }

    /// Crossfades the whole lift (ring, highlight and shadow together) to its
    /// target opacity. Reduce Motion snaps, the same guard every other
    /// overlay fade in this file makes.
    ///
    /// `--dur-2`/`--dur-3` name a 140-220 ms band rather than one number;
    /// this picks the long end, because the lift crosses two panes on a
    /// click (fading out on the one losing focus while fading in on the one
    /// gaining it) and the short end was tuned for a single-layer fade, not
    /// two running at once.
    private func apply(animated: Bool) {
        guard let layer else { return }
        let targetOpacity: Float = isVisible ? 1 : 0
        // The spec's 0.6, not 1: the token's alpha is the shadow's whole
        // strength, and the layer fade on top of it is only the transition.
        let targetShadow: Float = isVisible ? Float(ChromeMaterials.Lift.shadow.dropAlpha) : 0
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        updateShadowPath()
        needsDisplay = true

        guard animated, !reduceMotion else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = targetOpacity
            shadowLayer.shadowOpacity = targetShadow
            CATransaction.commit()
            return
        }

        let curve = CAMediaTimingFunction(controlPoints:
            Float(ChromeMaterials.Motion.standardEase.0),
            Float(ChromeMaterials.Motion.standardEase.1),
            Float(ChromeMaterials.Motion.standardEase.2),
            Float(ChromeMaterials.Motion.standardEase.3))
        let duration = ChromeMaterials.Motion.liftDurationLong

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = targetOpacity
        fade.duration = duration
        fade.timingFunction = curve

        let shadowFade = CABasicAnimation(keyPath: "shadowOpacity")
        shadowFade.fromValue = shadowLayer.presentation()?.shadowOpacity ?? shadowLayer.shadowOpacity
        shadowFade.toValue = targetShadow
        shadowFade.duration = duration
        shadowFade.timingFunction = curve

        layer.opacity = targetOpacity
        shadowLayer.shadowOpacity = targetShadow
        layer.add(fade, forKey: "baia.lift.opacity")
        shadowLayer.add(shadowFade, forKey: "baia.lift.shadowOpacity")
    }

    /// The ring and the inner highlight. The drop shadow is not drawn here:
    /// it is ``CALayer/shadowColor``/``shadowPath``/``shadowRadius`` on this
    /// view's own layer, set up once in `init` and faded by ``apply(animated:)``.
    override func draw(_: NSRect) {
        // Painted unconditionally (`isVisible` gates the layer's `opacity`
        // instead, the same split `PaneScrimView` and `PaneEdgeFrameView`'s
        // `barFrame` sibling make): a `draw(_:)` that skipped painting while
        // invisible would leave the fade animating an empty layer on the way
        // in, one frame of nothing before the strokes exist to fade.
        let ringWidth = ChromeMaterials.Lift.ringSpread
        let ringPath = WindowCorner.path(
            in: bounds,
            corners: bottomCorners,
            inset: ringWidth / 2
        )
        ringPath.lineWidth = ringWidth
        nsColor(RGB.eightBit(255, 255, 255), alpha: ChromeMaterials.Lift.ringAlpha).setStroke()
        ringPath.stroke()

        // `inset 0 1px 0`: a highlight along the top edge only, not the full
        // perimeter the ring takes. Clipped to the outline first so the
        // highlight's own corners still follow the window's curve rather
        // than squaring off where the pane meets it. This view is flipped
        // (``PaneOverlayView/isFlipped``), so `y: 0` is the pane's top edge,
        // the same convention ``PaneStatusBarView`` and ``PaneEdgeFrameView``
        // draw under.
        NSGraphicsContext.saveGraphicsState()
        WindowCorner.path(in: bounds, corners: bottomCorners).addClip()
        let highlight = NSRect(
            x: bounds.minX,
            y: 0,
            width: bounds.width,
            height: ChromeMaterials.Lift.innerHighlightOffsetY
        )
        nsColor(RGB.eightBit(255, 255, 255), alpha: ChromeMaterials.Lift.innerHighlightAlpha).setFill()
        highlight.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
