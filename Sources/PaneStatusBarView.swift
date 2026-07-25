import AppKit
import PaneChrome

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
/// view loop and be reachable by tab.
final class PaneStatusBarView: NSView {
    /// Set by the pane controller whenever the anchor, git state, or agent state
    /// moves. Redraws only on a real change, because the anchor tracker polls
    /// once a second and an unconditional `needsDisplay` would repaint the footer
    /// of every pane every second for nothing.
    var status: PaneStatus? {
        didSet {
            guard status != oldValue else { return }
            needsDisplay = true
        }
    }

    var theme: PaneTheme = .darkPastel {
        didSet {
            guard theme != oldValue else { return }
            needsDisplay = true
        }
    }

    var isFocused: Bool = false {
        didSet {
            guard isFocused != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The footer changes only when the status does, so AppKit must not
        // repaint it as a side effect of the terminal above it resizing.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        focusRingType = .none
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

    /// Height only. The width comes from the pane, and claiming a width here
    /// would fight the terminal for horizontal space.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: PaneStatusBarMetrics.height)
    }

    /// The bar sits below the terminal, so a click near the boundary must not be
    /// read as a click in the grid. Returning nil for everything except the bar's
    /// own bounds is the default, but `isFlipped` matters for the drawing maths
    /// below and is easy to get silently wrong.
    override var isFlipped: Bool { true }

    private static let font = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.smallSystemFontSize,
        weight: .regular
    )

    override func draw(_: NSRect) {
        let background = isFocused ? theme.focusedBarBackground : theme.barBackground
        nsColor(background).setFill()
        bounds.fill()

        drawHairline()
        if isFocused { drawAccentStripe() }

        guard let status else { return }
        let segments = PaneStatusSegments.build(from: status)
        guard !segments.isEmpty else { return }

        let attributed = segments.map { attributedString(for: $0, on: background) }
        let widths = attributed.map { Double($0.size().width) }
        let available = Double(bounds.width) - 2 * PaneStatusBarMetrics.horizontalInset
        let solved = PaneStatusLayout.solve(
            segments: segments,
            widths: widths,
            availableWidth: available
        )

        for placed in solved.placed {
            guard let index = segments.firstIndex(of: placed.segment) else { continue }
            draw(attributed[index], at: placed.x, width: placed.width)
        }
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
        nsColor(theme.background.blended(with: theme.foreground, fraction: 0.18)).setFill()
        hairline.fill()
    }

    /// The focused pane is marked with a stripe drawn *inside* the fixed height,
    /// never by making the bar taller. A footer that grew on focus would shrink
    /// the terminal above it, which resizes the ghostty grid and sends SIGWINCH
    /// to whatever is running in the pane, so moving focus would reflow a running
    /// agent's output.
    private func drawAccentStripe() {
        let stripe = NSRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: PaneStatusBarMetrics.accentStripeHeight
        )
        nsColor(theme.focusedAccent).setFill()
        stripe.fill()
    }

    private func draw(_ string: NSAttributedString, at x: Double, width: Double) {
        let height = string.size().height
        let rect = NSRect(
            x: x + PaneStatusBarMetrics.horizontalInset,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )
        string.draw(with: rect, options: [.usesLineFragmentOrigin])
    }

    private func attributedString(
        for segment: PaneStatusSegment,
        on background: PaneChrome.RGB
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        // The path is informative at its tail and the names at their head, which
        // is why truncation is per-segment rather than one style for the bar.
        switch segment.truncation {
        case .head: paragraph.lineBreakMode = .byTruncatingHead
        case .tail: paragraph.lineBreakMode = .byTruncatingTail
        case .none: paragraph.lineBreakMode = .byClipping
        }
        let colour = theme.readable(
            theme.color(for: segment.emphasis, focused: isFocused),
            on: background,
            minimumRatio: PaneTheme.minimumTextContrast
        )
        return NSAttributedString(
            string: segment.text,
            attributes: [
                .font: Self.font,
                .foregroundColor: nsColor(colour),
                .paragraphStyle: paragraph,
            ]
        )
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
