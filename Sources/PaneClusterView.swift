import AppKit
import BaiaSettings
import PaneChrome

/// The pane cluster: a pill in the pane's top-right carrying place, changes,
/// agent and attention, the footer's facts moved up where the eye already is.
///
/// **An overlay that the mouse can find, which is a deliberate departure from
/// ``PaneOverlayView``'s contract.** That class's header names three
/// untouchability guarantees and this view keeps two of them unchanged:
/// `acceptsFirstResponder` stays false and `canBecomeKeyView` stays false, so
/// neither a click nor the key view loop can ever move first responder off the
/// terminal, and every ghostty key binding in the pane keeps working. The third
/// — `hitTest` returning nil — is overridden, because the pill's segments are
/// click targets: a later task anchors a card to the segment the owner
/// clicked, and a view no click can reach anchors nothing. So `hitTest`
/// answers self inside the pill and nil everywhere else, which keeps the rest
/// of the pane exactly as clickable-through as every other overlay leaves it.
/// The keyboard must never move; the mouse, here alone, may land.
final class PaneClusterView: PaneOverlayView {
    /// What the pill says, in ``PaneClusterSegments/build(from:)``'s fixed
    /// order. Re-measured on change, because the text is what the width is.
    /// Empty means no capsule at all: ``PaneClusterLayout/pillWidth(for:)``
    /// answers zero and the view hides rather than wearing an empty pill.
    var segments: [PaneClusterSegment] = [] {
        didSet {
            guard segments != oldValue else { return }
            remeasure()
        }
    }

    /// The focus expression that used to live in the footer: the fill steps
    /// from the chrome material to the thick one and the inset stroke appears.
    /// Fill and stroke only, never a dimension — ``PaneClusterMetrics``' own
    /// header carries the rule, so looking at a pane cannot resize its pill.
    var isPaneFocused: Bool = false {
        didSet {
            guard isPaneFocused != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Whether this pane's window is the key window, the footer's second half
    /// of the focus gate. Two properties rather than one pre-gated feed, the
    /// same shape ``PaneStatusBarView`` keeps: the conjunction is computed
    /// here, in ``framesForFocus``, so a call site that forgets one half
    /// cannot hand the pill a focus expression the footer would refuse to
    /// draw.
    var isWindowActive: Bool = true {
        didSet {
            guard isWindowActive != oldValue else { return }
            needsDisplay = true
        }
    }

    /// `PaneStatusBarView.framesForFocus`, verbatim: focus is a statement
    /// about a window that has the keyboard, so a deactivated window drops
    /// the thick fill and the stroke with the footer's own, and the pill
    /// recedes under the scrim like everything else in the pane.
    private var framesForFocus: Bool {
        isPaneFocused && isWindowActive
    }

    var theme: PaneTheme = .darkPastel {
        didSet {
            guard theme != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Flat or glass with a material set, the same resolved value the footer
    /// holds. The pill's fills come off the carried ``MaterialSet``; under
    /// flat there is no material and the fill falls back to
    /// ``PaneChrome/PaneTheme/barBackground``, the footer's own flat fill.
    var resolvedChrome: ResolvedChrome = .flat {
        didSet {
            guard resolvedChrome != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Which derivation the attention dot is drawn from, and what to do when
    /// it lands on the focus colour. Received exactly as ``PaneStatusBarView``
    /// receives its pair: stored, and resolved against ``theme`` on every
    /// draw, so a live theme edit moves the dot with everything else.
    var attentionAccent: AttentionAccent = .alert {
        didSet {
            guard attentionAccent != oldValue else { return }
            needsDisplay = true
        }
    }

    var alertBehavior: AlertBehavior = .stock {
        didSet {
            guard alertBehavior != oldValue else { return }
            needsDisplay = true
        }
    }

    /// `chrome.cluster.opacity`: a multiplier on the pill fill's alpha, nil
    /// for the shipped 1.0. Fill only — the stroke, the segments and the dot
    /// keep their own inks — per the dial's own doc on
    /// ``BaiaSettings/DesignOverrides/Chrome/Cluster/opacity``: it exists to
    /// let the backdrop show through the pill, not to fade the facts on it.
    var fillOpacity: Double? {
        didSet {
            guard fillOpacity != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Raised on a click inside a segment, with the segment's rect in this
    /// view's own coordinates: the one value a later task's card needs to
    /// anchor to what was clicked. Clicks in the gaps between segments raise
    /// nothing — ``PaneClusterLayout/segment(at:in:)`` resolves them to nil
    /// on purpose, so a miss opens nothing rather than whichever card is
    /// nearer.
    var onSegmentClick: ((PaneClusterSegmentRole, NSRect) -> Void)?

    /// The solved placement, cached at measure time rather than re-solved per
    /// draw or per click, so what is drawn and what is hit cannot disagree.
    private var placed: [PaneClusterLayout.Placed] = []

    /// One font for measuring and drawing both, because a width measured in
    /// any other font is a pill the text does not fit.
    private static let segmentFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    /// Width from the cached placement, height from the metrics. The pill
    /// sizes itself; the controller only pins its top-right corner.
    override var intrinsicContentSize: NSSize {
        NSSize(
            width: PaneClusterLayout.pillWidth(for: placed),
            height: PaneClusterMetrics.height
        )
    }

    /// First mouse is accepted. While a card is up, its panel holds key, so
    /// the next click on this capsule reaches a non-key window and AppKit
    /// would by default spend it on re-activation and deliver nothing: the
    /// same-segment toggle would need two clicks and switching segments
    /// would too. A view whose entire purpose is the click cannot afford a
    /// click that only knocks. Task 8's live-window probe verifies the full
    /// card-up interaction; this override is what it verifies.
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    /// The departure: self inside the pill, nil outside. See the class header
    /// for why this view alone leaves the overlay family's hitTest-nil
    /// contract, and what it keeps instead.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, !placed.isEmpty else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    /// Resolves the click to a segment and hands it up. Consuming the event
    /// here (no call to super) is what keeps it from the terminal beneath,
    /// and `acceptsFirstResponder` staying false is what keeps it from moving
    /// the keyboard: AppKit does not make a view first responder for merely
    /// implementing `mouseDown`.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let segment = PaneClusterLayout.segment(at: Double(point.x), in: placed),
              let rect = segmentRect(for: segment.role)
        else { return }
        onSegmentClick?(segment.role, rect)
    }

    /// The named segment's rect in this view's own coordinates, or nil while
    /// the segment is not in the cached placement — a role only enters
    /// `placed` when the status carries its fact. The same derivation
    /// `mouseDown` hands ``onSegmentClick`` (it calls through here), off the
    /// same cache `draw` paints from, so a rect asked for by name — the
    /// approval popover anchoring to the attention dot without a click to
    /// resolve — cannot disagree with what is on screen.
    func segmentRect(for role: PaneClusterSegmentRole) -> NSRect? {
        guard let hit = placed.first(where: { $0.segment.role == role }) else { return nil }
        return NSRect(x: hit.x, y: 0, width: hit.width, height: bounds.height)
    }

    /// Measures every segment with the drawing font, solves the placement,
    /// and republishes the intrinsic size. The attention segment's text is
    /// empty by contract (``PaneClusterSegment/text``'s own doc); its width
    /// is the dot's.
    private func remeasure() {
        var widths: [PaneClusterSegmentRole: Double] = [:]
        for segment in segments {
            widths[segment.role] = segment.role == .attention
                ? PaneClusterMetrics.dotDiameter
                : Double(attributed(segment.text, ink: theme.foreground).size().width)
        }
        placed = PaneClusterLayout.solve(segments: segments, widths: widths)
        isHidden = placed.isEmpty
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private func attributed(_ text: String, ink: RGB) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: Self.segmentFont,
            .foregroundColor: nsColor(ink),
        ])
    }

    /// The material set glass resolves to, or nil under flat — the same
    /// one-place unwrap ``PaneStatusBarView`` keeps for its own readers.
    private var materialSet: MaterialSet? {
        switch resolvedChrome {
        case .flat: nil
        case let .glass(set): set
        }
    }

    override func draw(_: NSRect) {
        guard !placed.isEmpty else { return }

        // The pill: corner radius of half the height, so the ends are full
        // semicircles at every width.
        let radius = bounds.height / 2
        let pill = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)

        // Unfocused wears the chrome material, focused steps to the thick
        // one — the same two tiers `materials.css` names, off the resolved
        // set so the pill stays correct when the appearance flips. Flat has
        // no material and takes the footer's own flat fill for both states;
        // there the stroke below is the whole step.
        // The `chrome.cluster.opacity` dial, multiplied in rather than
        // substituted, so a dialled 0.85 scales whatever alpha the material
        // carries instead of overwriting it. nil is exactly 1.0 and leaves
        // both branches drawing the bytes they always drew.
        let fillAlpha = fillOpacity ?? 1
        if let set = materialSet {
            let fill = framesForFocus ? set.fillThick : set.fillChrome
            nsColor(fill.rgb, alpha: fill.alpha * fillAlpha).setFill()
        } else {
            nsColor(theme.barBackground, alpha: fillAlpha).setFill()
        }
        pill.fill()

        // The inset stroke, in the same ink as the footer's focus frame and
        // at its width, inset by half so the stroke lands inside the pill's
        // edge rather than straddling it — the radius comes down with it,
        // keeping the stroke concentric.
        //
        // Full alpha in both chrome modes, unlike the footer, and the
        // difference is the surface. `PaneStatusBarView.glassFrameAlpha`
        // (0.55) exists because the footer's glass path paints no fill, so
        // an opaque stroke there was ink laid straight onto naked glass,
        // reading as a sticker on the window. This stroke never touches
        // naked glass: it lands inside the pill's own thick fill, the
        // tinted surface the step above just painted, which is exactly the
        // kind of composited backing the footer's flat case keeps its full
        // alpha for.
        if framesForFocus {
            let width = PaneStatusBarMetrics.focusFrameWidth
            let inner = NSBezierPath(
                roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2),
                xRadius: (bounds.height - width) / 2,
                yRadius: (bounds.height - width) / 2
            )
            inner.lineWidth = width
            nsColor(theme.inkFocus).setStroke()
            inner.stroke()
        }

        // Segments, at the cached placement. Theme ink ungraded, per the
        // glass-backdrop ruling the footer records: real glass supplies its
        // own legibility, and flat's fill is the same surface the footer
        // judges its own ink against.
        let attentionColour = theme.attentionColour(attentionAccent, behavior: alertBehavior)
        for placement in placed {
            if placement.segment.role == .attention {
                let dot = NSRect(
                    x: placement.x,
                    y: (bounds.height - PaneClusterMetrics.dotDiameter) / 2,
                    width: PaneClusterMetrics.dotDiameter,
                    height: PaneClusterMetrics.dotDiameter
                )
                nsColor(attentionColour).setFill()
                NSBezierPath(ovalIn: dot).fill()
            } else {
                let string = attributed(placement.segment.text, ink: theme.foreground)
                string.draw(at: NSPoint(
                    x: placement.x,
                    y: (bounds.height - string.size().height) / 2
                ))
            }
        }
    }
}
