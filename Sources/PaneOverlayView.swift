import AppKit
import BaiaSettings
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
/// The one place in the design a frame leaves the pane's chrome and takes the
/// whole compartment. That is what makes attention rank above focus without
/// either needing to know about the other: focus takes the chrome's edges (the
/// footer's until 2026-08-13, the capsule's since) and attention takes the
/// pane's, so a pane can be both at once and still be read correctly,
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
    /// Pushed from ``TerminalPaneController``, for the reason the footer also had
    /// a copy while it existed: anything drawn at that corner meets the window's
    /// own mask there, so a frame that kept its own shape is a disagreement in
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

/// Everything ``PaneLiftView`` draws with, resolved: the constants in
/// `ChromeMaterials.Lift`/`Motion`, or whatever the debug design panel has
/// dialled in front of them.
///
/// **``shipped`` is exactly the constants, and it is the default.** A lift view
/// that is never handed one of these renders precisely what it rendered before
/// this type existed, which is what makes the whole wire a no-op with the
/// overrides nil. ``from(_:)`` builds a dialled one; nil per field there falls
/// back to the constant, never to zero and never to off.
///
/// **Resolved once, into non-optionals, rather than eight `??` at the draw
/// sites.** `draw(_:)` and `updateShadowPath()` both need the ring and the
/// shadow reach, and a fallback spelled twice is a fallback that can be spelled
/// two ways. It is also what keeps ``PaneLiftView`` free of any import beyond
/// what it already has — `Diagnostics/footer-corners` compiles this file
/// verbatim against `PaneChrome`, `BaiaSettings` and `WorkspaceLayout` alone,
/// and a `DesignOverrides` read inside the view would be a fourth edge that
/// probe cannot link.
///
/// Colours are deliberately absent. The ring and the highlight are white at an
/// alpha, per the plan's Task 6 text, and the panel dials the alphas rather than
/// the hue: a coloured lift is a different effect, not this one turned up.
struct PaneLiftParameters: Equatable {
    var enabled: Bool
    var ringSpread: Double
    var ringAlpha: Double
    var innerHighlightOffsetY: Double
    var innerHighlightAlpha: Double
    var shadowDropOffsetY: Double
    var shadowDropBlur: Double
    var shadowDropAlpha: Double
    var duration: Double

    /// The constants, unmoved: what every pane draws until something is dialled.
    ///
    /// `duration` takes the long end of the 140-220 ms band, which is the value
    /// ``PaneLiftView/apply(animated:)`` picked before this type existed and for
    /// the reason recorded there: the lift crosses two panes on a click, and the
    /// short end was tuned for a single-layer fade.
    static let shipped = PaneLiftParameters(
        enabled: true,
        ringSpread: ChromeMaterials.Lift.ringSpread,
        ringAlpha: ChromeMaterials.Lift.ringAlpha,
        innerHighlightOffsetY: ChromeMaterials.Lift.innerHighlightOffsetY,
        innerHighlightAlpha: ChromeMaterials.Lift.innerHighlightAlpha,
        shadowDropOffsetY: ChromeMaterials.Lift.shadow.dropOffsetY,
        shadowDropBlur: ChromeMaterials.Lift.shadow.dropBlur,
        shadowDropAlpha: ChromeMaterials.Lift.shadow.dropAlpha,
        duration: ChromeMaterials.Motion.liftDurationLong
    )

    /// ``shipped``, with each dialled field standing in front of its constant.
    ///
    /// Field by field rather than "rebuild from the overrides", the same shape
    /// `Settings.applying(_:)` takes and for the same reason: a field this
    /// function has never heard of keeps its constant instead of arriving as a
    /// zero.
    static func from(_ lift: DesignOverrides.Chrome.Lift) -> PaneLiftParameters {
        var resolved = shipped
        if let value = lift.enabled { resolved.enabled = value }
        if let value = lift.ringSpread { resolved.ringSpread = value }
        if let value = lift.ringAlpha { resolved.ringAlpha = value }
        if let value = lift.innerHighlightOffsetY { resolved.innerHighlightOffsetY = value }
        if let value = lift.innerHighlightAlpha { resolved.innerHighlightAlpha = value }
        if let value = lift.shadowDropOffsetY { resolved.shadowDropOffsetY = value }
        if let value = lift.shadowDropBlur { resolved.shadowDropBlur = value }
        if let value = lift.shadowDropAlpha { resolved.shadowDropAlpha = value }
        if let value = lift.duration { resolved.duration = value }
        return resolved
    }
}

/// The lens rim: the bright top edge `--rim-top` names, drawn inside a pane's
/// own outline.
///
/// **Off by default, and off is exactly today's rendering.** The rim constants
/// have been transcribed and tested in ``ChromeMaterials`` since v5 and no
/// drawing site has ever read them; this is their first consumer, and it draws
/// nothing at all unless ``enabled`` is set. So the wire adds a knob without
/// adding a pixel, which is the acceptance the whole override layer is held to.
///
/// Top edge only, per the constants' own doc (`inset 0 0.5px 0`, a bright top
/// rim). `--rim-bottom` is transcribed beside it in ``ChromeMaterials`` and is
/// deliberately not drawn here: `DesignOverrides.Chrome.Rim` offers one alpha,
/// and a bottom edge nothing can dial would be an effect the owner cannot
/// switch off independently of the one he asked for.
struct PaneRimParameters: Equatable {
    var enabled: Bool

    /// The bright edge's alpha. Defaults to the *dark* appearance's constant,
    /// which is the one the app draws under today (`ChromeAppearance`'s material
    /// set follows the theme, and the shipped theme is dark).
    ///
    /// One value rather than one per appearance, matching
    /// `DesignOverrides.Chrome.Rim`'s own reasoning: the panel is dialled on the
    /// machine in front of the owner and that machine is in one appearance at a
    /// time.
    var topAlpha: Double

    /// The edge's thickness, in points: `inset 0 0.5px 0`. Not dialable, and
    /// deliberately so — it is a hairline the token names, and the override
    /// offers an alpha alone.
    static let thickness: Double = 0.5

    /// Absent: what every pane draws today and what a nil override leaves it
    /// drawing.
    static let off = PaneRimParameters(
        enabled: false,
        topAlpha: ChromeMaterials.Dark.rimTopAlpha
    )

    static func from(_ rim: DesignOverrides.Chrome.Rim) -> PaneRimParameters {
        var resolved = off
        if let value = rim.enabled { resolved.enabled = value }
        if let value = rim.topAlpha { resolved.topAlpha = value }
        return resolved
    }
}

/// The focused pane's lift, under glass: the hairline ring, inner highlight
/// and drop shadow design v5's Task 6 adds around the whole pane, replacing
/// the footer-only stroke for exactly the states glass is on.
///
/// Under flat, and under Reduce Transparency (which forces flat regardless of
/// the configured `chromeStyle`), this view stays invisible and the shipped
/// 1.5-2 pt `FocusAccent` stroke inside the footer (`PaneStatusBarView.drawBarFrame(in:)`)
/// remains the whole expression of focus, unchanged. `TerminalPaneController`
/// never sets ``isVisible`` under those conditions, and this view's own
/// nothing-drawn default (`isVisible = false`) is the same "no view drawn,
/// not merely hidden" guarantee ``PaneGlassPlaneView`` gets from
/// `TerminalPaneController.installGlassPlane()`, which builds the plane only
/// under glass and removes it outright under flat: a lift that never shows
/// keeps zero cost on a flat pane rather than an invisible layer macOS still
/// composites.
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
    /// `resolvedChrome` is `.glass`) that gated the footer's thick fill gate
    /// this too, so the ring and the fill step never appear one without the
    /// other.
    var isVisible: Bool = false {
        didSet {
            guard isVisible != oldValue else { return }
            apply(animated: true)
        }
    }

    /// Which of the window's bottom corners this pane sits in, the same value
    /// pushed to ``PaneEdgeFrameView``, so the lift's outline
    /// curves exactly where the window's own mask does and nowhere else.
    var bottomCorners: BottomCorners = [] {
        didSet {
            guard bottomCorners != oldValue else { return }
            needsDisplay = true
            updateShadowPath()
        }
    }

    /// The eight numbers and the duration this lift is drawn with.
    /// ``PaneLiftParameters/shipped`` — the default, and everything a Release
    /// build can ever hold — is the constants unmoved.
    ///
    /// Reapplied rather than merely repainted, and both halves are needed: the
    /// ring and the highlight are strokes `draw(_:)` lays down, while the shadow
    /// offset, radius and its mask's reach live on ``shadowLayer`` and are
    /// written outside any draw pass. A `needsDisplay` alone would move the ring
    /// and leave the shadow on the numbers it was built with.
    ///
    /// Guarded on a change like every other property here, for the reason
    /// `ConfigurationCenter.designOverrides`' own doc comment records: a panel
    /// writes a whole value per control event, and an unguarded setter turns
    /// every unmoved write into a repaint of every pane.
    var parameters: PaneLiftParameters = .shipped {
        didSet {
            guard parameters != oldValue else { return }
            shadowLayer.shadowOffset = CGSize(width: 0, height: parameters.shadowDropOffsetY)
            shadowLayer.shadowRadius = parameters.shadowDropBlur / 2
            apply(animated: false)
        }
    }

    /// The lens rim drawn inside this pane's outline, or
    /// ``PaneRimParameters/off`` — the default — which draws nothing.
    ///
    /// Repaint only: unlike ``parameters`` the rim is entirely a `draw(_:)`
    /// stroke and touches no layer property.
    ///
    /// **Its visibility is the lift's, not its own.** The rim rides this view's
    /// layer opacity, so it appears and fades exactly where the focused pane's
    /// lift does. That is the honest arrangement for a first consumer: the rim
    /// is a lensing cue for the surface that is raised, and a rim standing on
    /// every pane would be a second, unrequested effect reached by the same
    /// switch.
    var rim: PaneRimParameters = .off {
        didSet {
            guard rim != oldValue else { return }
            needsDisplay = true
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
        // From ``parameters``, whose default is the constants this line named
        // directly before the design panel existed. ``parameters``' own `didSet`
        // rewrites both of these when a dial moves them.
        shadowLayer.shadowOffset = CGSize(width: 0, height: parameters.shadowDropOffsetY)
        shadowLayer.shadowRadius = parameters.shadowDropBlur / 2
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
    /// mismatch `TerminalPaneController.updateGlassPlaneMasks()` exists to
    /// avoid on the pane's glass plane and wash.
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
        let reach = parameters.shadowDropBlur
            + abs(parameters.shadowDropOffsetY)
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
        // ``PaneLiftParameters/enabled`` reads as "not visible", which puts it
        // through the one path that already knows how to take the lift away:
        // the layer fades to nothing, ring, highlight, rim and shadow together,
        // and switching it back on fades them back. Skipping the strokes in
        // `draw(_:)` instead would leave the shadow standing, since the shadow
        // is a layer property no draw pass touches.
        let shows = isVisible && parameters.enabled
        let targetOpacity: Float = shows ? 1 : 0
        // The spec's 0.6, not 1: the token's alpha is the shadow's whole
        // strength, and the layer fade on top of it is only the transition.
        let targetShadow: Float = shows ? Float(parameters.shadowDropAlpha) : 0
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
        // The curve stays a constant: `--ease-standard` is the motion system's
        // one curve and `DesignOverrides.Chrome.Lift` offers no field for it,
        // deliberately — a dialable bezier is four numbers nobody can read off a
        // panel. The duration is the one thing dialled, and Reduce Motion above
        // still wins over whatever it says.
        let duration = parameters.duration

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
        let ringWidth = parameters.ringSpread
        let ringPath = WindowCorner.path(
            in: bounds,
            corners: bottomCorners,
            inset: ringWidth / 2
        )
        ringPath.lineWidth = ringWidth
        nsColor(RGB.eightBit(255, 255, 255), alpha: parameters.ringAlpha).setStroke()
        ringPath.stroke()

        // `inset 0 1px 0`: a highlight along the top edge only, not the full
        // perimeter the ring takes. Clipped to the outline first so the
        // highlight's own corners still follow the window's curve rather
        // than squaring off where the pane meets it. This view is flipped
        // (``PaneOverlayView/isFlipped``), so `y: 0` is the pane's top edge,
        // the same convention `PaneStatusBarView` and ``PaneEdgeFrameView``
        // draw under.
        NSGraphicsContext.saveGraphicsState()
        WindowCorner.path(in: bounds, corners: bottomCorners).addClip()
        let highlight = NSRect(
            x: bounds.minX,
            y: 0,
            width: bounds.width,
            height: parameters.innerHighlightOffsetY
        )
        nsColor(RGB.eightBit(255, 255, 255), alpha: parameters.innerHighlightAlpha).setFill()
        highlight.fill()

        // The lens rim, and the rim constants' first consumer ever. Nothing is
        // painted unless the panel has switched it on, so the whole block is
        // absent from every rendering that ships — `rim` defaults to
        // ``PaneRimParameters/off``, and in Release it can hold nothing else.
        //
        // Inside the same clip the highlight uses, and above it: the two are
        // stacked bright edges on the same 0.5-1 pt of the pane's top, and
        // drawing the rim second is what lets the owner see what it adds over
        // the highlight already there rather than under it.
        if rim.enabled {
            let edge = NSRect(
                x: bounds.minX,
                y: 0,
                width: bounds.width,
                height: PaneRimParameters.thickness
            )
            nsColor(RGB.eightBit(255, 255, 255), alpha: rim.topAlpha).setFill()
            edge.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
