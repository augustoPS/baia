import AppKit
import PaneChrome

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

/// A 2 pt stroked rectangle inside a pane's edge, marking the pane that is
/// asking.
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

    /// Radius zero. A rounded frame inside a square pane leaves four visible
    /// gaps at the corners where the terminal shows through.
    private static let thickness: Double = 2

    override func draw(_: NSRect) {
        guard isVisible else { return }
        let inset = Self.thickness / 2
        let path = NSBezierPath(rect: bounds.insetBy(dx: inset, dy: inset))
        path.lineWidth = Self.thickness
        nsColor(colour).setStroke()
        path.stroke()
    }
}
