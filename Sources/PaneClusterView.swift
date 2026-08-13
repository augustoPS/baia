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
            // Before the measure, so the re-measure the observation may trigger
            // cannot land on a stale placement, and after the guard, so a
            // repeated identical status does not churn an observer.
            updatePaneWidthObservation()
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

    /// The segment whose card is up, wearing the hot wash while it is: a
    /// rounded rect behind the segment, brighter than the pill fill, the
    /// design mockup's active treatment (owner ruling, 2026-08-12). Set by the
    /// controller beside its own `clusterCardRole` and cleared in the same
    /// `onDismiss`, so the wash on screen and the toggle's memory cannot
    /// disagree about which card is open. Nil is no card and no wash.
    var activeRole: PaneClusterSegmentRole? {
        didSet {
            guard activeRole != oldValue else { return }
            needsDisplay = true
        }
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

    /// Raised with the roles that were on the pill a moment ago and are not on
    /// it now, whatever took them off.
    ///
    /// **"A segment stopped existing" is one concept and this is its one
    /// signal.** A card is anchored to a segment, so a segment that goes away
    /// while its card is up leaves the card hanging beside a pill that no longer
    /// says what it is about — with no active wash behind it, since
    /// ``segmentRect(for:)`` answers nil for a role that is not placed, and no
    /// way to click the segment to dismiss it, since there is nothing left to
    /// click. ``TerminalPaneController/showNotice(_:)`` knew that rule and
    /// dismissed the card itself, but it knew it for the *notice* path only, and
    /// the fitting pass then introduced a second way for a segment to vanish —
    /// a divider dragged narrow enough to drop the role
    /// (``PaneChrome/PaneClusterLayout/fitting(segments:widths:budget:)``) — which
    /// did not go anywhere near `showNotice` and so left the card up.
    ///
    /// Raised from ``remeasure()``, which is the single funnel every placement
    /// change runs through: a status edit, a notice arriving or clearing, a
    /// divider drag, a `cornerInset` dial. So a third way to lose a segment
    /// invented later reaches the same handler without having to remember to.
    /// The controller's response is one line — dismiss the card if it belonged to
    /// a vanished role — and it lives in one place for the same reason.
    ///
    /// Reports roles rather than "something changed" so the handler can ignore a
    /// placement change that has nothing to do with the card that is up: a
    /// branch name growing does not take the changes card down.
    var onSegmentsVanished: (([PaneClusterSegmentRole]) -> Void)?

    /// The pane inset the pill is pinned at, written by the controller from
    /// its own ``TerminalPaneController/resolvedClusterInset`` whenever that
    /// moves (install, and every `chrome.cluster.cornerInset` edit).
    ///
    /// Held rather than read from ``PaneClusterMetrics/cornerInset``, because
    /// the constant is only the *default* the dial falls back to. Both budgets
    /// care: each reserves the inset at both ends of the pane, and reserving 6
    /// while the constraints hold 40 over-allows by 68 pt and runs the pill off
    /// the pane's leading edge. Re-measures on change for the same reason the
    /// pane width does — the budget moved, so what the pill may wear moved with
    /// it.
    ///
    /// Guarded on a non-empty capsule rather than on a notice, since
    /// ``PaneChrome/PaneClusterLayout/pillWidthBudget(paneWidth:cornerInset:)``
    /// subtracts this for the resting pill too.
    var cornerInset: Double = PaneClusterMetrics.cornerInset {
        didSet {
            guard cornerInset != oldValue, !segments.isEmpty else { return }
            remeasure()
        }
    }

    /// The solved placement, cached at measure time rather than re-solved per
    /// draw or per click, so what is drawn and what is hit cannot disagree.
    private var placed: [PaneClusterLayout.Placed] = []

    /// Where the attention dot sat in the last placement that had one, as a
    /// distance from the pill's **trailing** edge rather than as a rect.
    ///
    /// **This is what a notice does not take away.** A notice takes the pill
    /// alone (``PaneChrome/PaneClusterSegments/build(from:)``), so for its three
    /// seconds `placed` holds no attention segment and
    /// ``segmentRect(for:)`` would answer nil — which the approval popover's
    /// anchor turns into the whole pill, and during a notice the whole pill is
    /// a full-width sentence. Anchoring a popover to that lands it visibly
    /// displaced, and three seconds later the pill shrinks out from under it.
    ///
    /// The dot is displaced by the notice, not deleted by it: it comes back
    /// where it was as soon as the sentence clears. So the honest answer to
    /// "where is the attention dot" during a notice is where it *will* be, and
    /// that is what this reserves. Both orderings are covered by the one fact —
    /// a request arriving mid-notice anchors to the returning dot, and a notice
    /// firing under an already-anchored popover leaves that popover over the
    /// place the dot comes back to.
    ///
    /// Measured from the trailing edge because that edge is the one the pill is
    /// pinned by: the view's leading edge moves when the width changes (a
    /// notice makes it hundreds of points wider) while the trailing edge does
    /// not, so a leading-relative x would point somewhere else entirely the
    /// moment the notice arrives. Nil until attention has been placed once,
    /// which is the genuinely unknown case the fallback below is for.
    private var reservedAttentionTrailingOffset: Double?

    /// The notice's text as it was cut and measured, so ``draw(_:)`` paints the
    /// string the pill's width was solved from rather than re-deriving it. Nil
    /// whenever the segments carry no notice.
    private var noticeCut: String?

    /// The pane-frame observation, live only while a notice is up. See
    /// ``updatePaneWidthObservation()``.
    private var paneWidthObserver: (any NSObjectProtocol)?

    /// The pane width the current placement was measured against, so a resize
    /// that changes what a notice may claim can re-measure and one that does
    /// not can stay quiet.
    ///
    /// **Every segment's presence depends on the pane now, not only the
    /// notice's width.** This said the opposite until 2026-08-13, and it was
    /// true then: the notice was budgeted
    /// (``PaneChrome/PaneClusterLayout/noticeTextBudget(paneWidth:cornerInset:)``)
    /// and every resting segment measured the same at every pane width, so a
    /// pane dragged narrower with a branch name on its pill re-measured nothing.
    /// That is what let an oversized resting pill run off the pane.
    /// ``PaneChrome/PaneClusterLayout/fitting(segments:widths:budget:)`` now
    /// drops resting segments against the pane's width, so the answer moves with
    /// the pane and a resize has to re-fit.
    ///
    /// It is still consulted before re-measuring, so a resize that does not
    /// change the width costs nothing.
    private var measuredPaneWidth: Double?

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
    ///
    /// **An oversized pill never took the neighbour's clicks, and a pane-bounds
    /// guard here was dead code.** An earlier version of this function tested
    /// `point` against the superview's bounds as well as this view's, on the
    /// claim that `bounds.contains` alone "is what let an oversized pill swallow
    /// the neighbour's clicks". That claim is false, and it was measured false
    /// on the real arrangement — `NSSplitViewController`, two pane containers,
    /// a pill in the right pane overhanging 156 pt past its pane's leading edge,
    /// laid out:
    ///
    ///     guard OFF   click in LEFT pane under overhang -> LEFT PANE  [pill.hitTest 0x]
    ///     guard ON    click in LEFT pane under overhang -> LEFT PANE  [pill.hitTest 0x]
    ///     (control)   click on the pill inside its own pane -> PILL   [pill.hitTest 1x]
    ///
    /// `pill.hitTest` is never *called* for a point outside its pane, with or
    /// without the guard: `NSView.hitTest` rejects the point against each
    /// subview's frame before descending into it, so a point beyond the pane's
    /// leading edge never reaches a child of that pane at all. Asking the right
    /// pane directly about the same point also answers nil. The guard rejected
    /// nothing that would otherwise have been accepted, and the control proves
    /// the experiment could see an accepted click.
    ///
    /// The real defect of an oversized pill is **visual** — it is drawn over the
    /// neighbour, because drawing is not clipped by a frame the way hit-testing
    /// is — and
    /// ``PaneChrome/PaneClusterLayout/fitting(segments:widths:budget:)`` is what
    /// fixes it. Nothing here has to defend against a cross-pane click, so
    /// nothing here does; the guard is gone rather than kept with an honest
    /// comment, because dead code that looks load-bearing is what cost this
    /// review a false premise repeated in three files.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, !placed.isEmpty else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    /// Resolves the click to a segment and hands it up. Consuming the event
    /// here (no call to super) is what keeps it from the terminal beneath,
    /// and `acceptsFirstResponder` staying false is what keeps it from moving
    /// the keyboard: AppKit does not make a view first responder for merely
    /// implementing `mouseDown`.
    ///
    /// A click on the notice resolves to a segment and then stops, on
    /// ``PaneChrome/PaneClusterSegmentRole/opensCard``: the sentence is already
    /// the whole answer, and a card would take the keyboard off the terminal to
    /// say it again for three seconds. The event is still consumed, which is
    /// what keeps a click aimed at a pill that has briefly become a notice from
    /// landing in the terminal underneath it.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let segment = PaneClusterLayout.segment(at: Double(point.x), in: placed),
              segment.role.opensCard,
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

    /// Where the approval popover should anchor: the attention dot's rect if it
    /// is placed, otherwise the rect it will occupy when the notice covering it
    /// clears, otherwise nil.
    ///
    /// Separate from ``segmentRect(for:)`` rather than folded into it, because
    /// the two answer different questions and only one of them may lie. A click
    /// resolving to a segment, and the wash drawn behind an active one, must see
    /// exactly what is on screen right now — `segmentRect` is the cache `draw`
    /// paints from and answering a rect for a segment that is not there would
    /// wash empty pill. An anchor is a promise about where a thing is *for the
    /// life of the popover*, which outlives a three-second notice, so it is
    /// allowed to name the returning dot. Two callers, two contracts, two
    /// functions.
    ///
    /// Nil only when attention has never been placed on this pill — a request
    /// arriving before the first status poll adds the segment. That is the case
    /// the caller's whole-capsule fallback was written for, and it is a fine
    /// stand-in there: with no notice up the pill is its resting width, a few
    /// dozen points, so a popover under it lands where the dot is about to
    /// appear anyway.
    func approvalAnchorRect() -> NSRect? {
        if let live = segmentRect(for: .attention) { return live }
        guard let offset = reservedAttentionTrailingOffset else { return nil }
        // The offset was taken from the trailing edge of the pill it was
        // measured on and is applied to the trailing edge of the pill there is
        // now, and those are the same point of the pane even though the pill
        // changed width under them.
        //
        // **`bounds.maxX` is not itself fixed — it is the view's width, 60-odd
        // points at rest and up to 500 under a notice.** What is fixed is where
        // that edge lands in the window, and it is fixed by cancellation rather
        // than by nothing moving. The capsule is pinned trailing
        // (`TerminalPaneController` constrains `view.trailingAnchor` to
        // `clusterView.trailingAnchor` plus the resolved inset), so a pill that
        // grows by Δ moves `frame.origin.x` by exactly −Δ; converting out with
        // `convert(_:to: nil)` adds `frame.origin` back, so the two deltas
        // cancel and the trailing edge converts to the same window point at
        // every width. The leading edge is the one that moves, which is why the
        // reserve is stored trailing-relative in the first place.
        //
        // **The offset is invariant, not merely stable, and that is stronger
        // than this reserve needs.** `PaneClusterSegments.build` always appends
        // `.attention` last, and `pillWidth` is `last.x + last.width +
        // horizontalInset`, so for the placement that has a dot
        // `pillWidth - dot.x` is `dotDiameter + horizontalInset` — 14 at the
        // shipped metrics, whatever resting segments are present and however
        // long the branch name is. Stored anyway rather than written as that
        // constant: the stored value stays correct if the dot ever stops being
        // the last segment, and a constant here would silently point at
        // whatever took its place. `theReservedDotOffsetIsTheSameWhicheverRestingSegmentsArePresent`
        // in `PaneClusterLayoutTests` pins the invariance so the claim above is
        // checkable.
        return NSRect(
            x: bounds.maxX - offset,
            y: 0,
            width: PaneClusterMetrics.dotDiameter,
            height: bounds.height
        )
    }

    /// Measures every segment with the drawing font, solves the placement,
    /// and republishes the intrinsic size. The attention segment's text is
    /// empty by contract (``PaneClusterSegment/text``'s own doc); its width
    /// is the dot's.
    ///
    /// The notice is the one segment measured against a budget rather than
    /// measured freely — see ``noticeText`` — because it is the one segment
    /// that is a sentence. Everything else is a label the pane was always wide
    /// enough for.
    private func remeasure() {
        var widths: [PaneClusterSegmentRole: Double] = [:]
        var noticeCut: String?
        for segment in segments {
            switch segment.role {
            case .attention:
                widths[segment.role] = PaneClusterMetrics.dotDiameter
            case .notice:
                // Cut once, here, and kept for `draw` to paint. The old shape
                // re-cut inside `draw` "so the drawn string and the measured
                // one are the same string"; they are the same string because
                // they are now literally one value, and the cut no longer runs
                // on every `needsDisplay` — a theme edit, a focus change or a
                // window activation used to pay for the whole loop.
                let cut = noticeText(segment.text)
                noticeCut = cut
                widths[segment.role] = Double(
                    attributed(cut, ink: theme.foreground).size().width
                )
            default:
                widths[segment.role] = Double(
                    attributed(segment.text, ink: theme.foreground).size().width
                )
            }
        }
        self.noticeCut = noticeCut

        // The pill is fitted to the pane before it is placed. Without this the
        // width came straight off `intrinsicContentSize` with no leading
        // constraint and no clip to stop it: an oversized pill ran past the
        // pane's leading edge and drew over the neighbouring pane.
        //
        // Drawing over it is the whole defect, and it is worth being exact,
        // because this comment claimed a second one that does not exist: the
        // overhang never took the neighbour's *clicks*. AppKit's `hitTest`
        // clips to each subview's frame before descending, so a point past the
        // pane's leading edge never reaches this view — measured, see
        // ``hitTest(_:)``. Drawing has no such clip (the pane does not
        // `clipsToBounds`), which is why the visual half was real and the
        // interaction half was imagined.
        //
        // `superview` and not `window`, and unbudgeted with no superview, for
        // ``noticeText(_:)``'s reason: the budget is about the pane this view is
        // installed in, and before installation there is nothing on screen to
        // overflow.
        let fitted = superview.map { pane in
            PaneClusterLayout.fitting(
                segments: segments,
                widths: widths,
                budget: PaneClusterLayout.pillWidthBudget(
                    paneWidth: Double(pane.bounds.width),
                    cornerInset: cornerInset
                )
            )
        } ?? segments

        // What was on the pill before this measure, so the roles that leave it
        // can be named below. Read before `placed` is replaced, obviously, and
        // cheap: at most five roles.
        let before = Set(placed.map(\.segment.role))

        placed = PaneClusterLayout.solve(segments: fitted, widths: widths)
        measuredPaneWidth = superview.map { Double($0.bounds.width) }

        // The one announcement that a segment stopped existing, whatever took
        // it off — a status change, a notice taking the pill alone, or the fit
        // dropping it because the pane narrowed. See ``onSegmentsVanished``.
        // Raised after `placed` is installed so a handler that asks this view
        // anything sees the new placement, and before `needsDisplay`, so a card
        // dismissed here clears its wash in the same draw rather than one later.
        let vanished = before.subtracting(placed.map(\.segment.role))
        if !vanished.isEmpty { onSegmentsVanished?(Array(vanished)) }

        // The attention dot's distance from the pill's trailing edge, kept for
        // ``approvalAnchorRect()`` to hand back while a notice has taken the
        // pill. Written only when attention is actually placed, so a notice —
        // which places nothing else — leaves the last resting value standing,
        // which is the whole point: it is the offset the dot returns to.
        if let dot = placed.first(where: { $0.segment.role == .attention }) {
            reservedAttentionTrailingOffset =
                PaneClusterLayout.pillWidth(for: placed) - dot.x
        }

        isHidden = placed.isEmpty
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// Re-measures a pill whose pane has changed width under it.
    ///
    /// A notice lives three seconds and a divider drag takes longer than that,
    /// so a pane narrowed mid-notice is reachable: without this the pill keeps
    /// the width it was measured at and runs off the pane it belongs to, which
    /// is the exact failure the budget exists to prevent. Widening has the
    /// milder version — a sentence stays cut shorter than it needed to be —
    /// and the same call fixes it.
    ///
    /// **The resting pill needs the same call, which it did not get until
    /// 2026-08-13.** A pill is now fitted to its pane
    /// (``PaneChrome/PaneClusterLayout/fitting(segments:widths:budget:)``), so
    /// dragging a divider narrower has to drop a segment and dragging it wider
    /// has to bring one back. Keyed off a non-empty placement rather than off a
    /// notice for that reason. A resize to the same width still re-measures
    /// nothing, on ``measuredPaneWidth``.
    ///
    /// **Driven off the superview's frame, and it has to be, because this view
    /// has no reason of its own to lay out when the pane resizes.** The capsule
    /// is pinned top and trailing with its width coming from
    /// ``intrinsicContentSize``: dragging the divider narrower moves the
    /// superview's width and this view's own bounds do not follow, so AppKit
    /// calls `layout()` on the pane, not on the pill. The previous version of
    /// this re-measure hung off `layout()` and could not fire on the one path
    /// it was written for — and it was circular besides, since the intrinsic
    /// size only moves when `remeasure()` runs and `remeasure()` only ran from
    /// `layout()`.
    ///
    /// `NSView.frameDidChangeNotification` on the superview is what actually
    /// observes the resize: AppKit posts it whenever the pane's frame is set,
    /// which is exactly what a divider drag does on every mouse-moved event,
    /// and `postsFrameChangedNotifications` defaults to true (nothing in this
    /// app turns it off on a pane's container, which is a plain `NSView` from
    /// `TerminalPaneController.loadView()`).
    ///
    /// Both halves measured rather than assumed, on this exact arrangement — a
    /// child pinned top and trailing, width from `intrinsicContentSize`, inside
    /// a superview narrowed from 800 to 300 and laid out: the child's `layout()`
    /// fired **zero** times, and the superview posted **one** frame
    /// notification. The old mechanism could not fire on the path it was written
    /// for; this one does.
    ///
    /// The observation is registered whenever the capsule has anything on it
    /// (``updatePaneWidthObservation()``, from ``segments``' setter) and torn
    /// down when it does not. It was notice-only until the fitting pass existed,
    /// which is what kept a resting pill from ever noticing its pane had
    /// narrowed under it. The cost is one notification per pane per resize,
    /// discarded on the width check above when the width did not actually move.
    private func paneWidthChanged() {
        guard !segments.isEmpty,
              let paneWidth = superview.map({ Double($0.bounds.width) }),
              paneWidth != measuredPaneWidth
        else { return }
        remeasure()
    }

    /// Starts or stops watching the pane's frame, keyed off whether a notice is
    /// up. Called from ``segments``' setter, which is the one place a notice
    /// arrives and the one place it leaves.
    ///
    /// Also re-registered when the superview changes (``viewDidMoveToSuperview``),
    /// because an observation is against a specific object and a capsule
    /// reinstalled by the `chrome.cluster.mode` dial gets a different pane view
    /// — or none.
    private func updatePaneWidthObservation() {
        if let paneWidthObserver {
            NotificationCenter.default.removeObserver(paneWidthObserver)
            self.paneWidthObserver = nil
        }
        guard !segments.isEmpty, let pane = superview else { return }
        paneWidthObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: pane,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.paneWidthChanged() }
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updatePaneWidthObservation()
    }

    // No `deinit` removing `paneWidthObserver`, and the reason is the one
    // `PaneGitStatus.stopPolling()` states for its own missing deinit: a
    // nonisolated deinit may not touch main-actor state, and this view is
    // `@MainActor` with everything it holds. The teardown lives on the
    // lifecycle path instead, which reaches every way this observation can end.
    // `viewDidMoveToSuperview` fires on removal as well as on install
    // (`applyClusterMode()` removes the capsule at `.footer`, and a closing pane
    // takes its whole hierarchy down), and `updatePaneWidthObservation()` finds
    // no superview there and unregisters. The block captures `self` weakly
    // besides, so the worst an unregistered observer could do is a no-op.

    /// The notice as it will be drawn: the sentence, tail-cut to whatever
    /// ``PaneChrome/PaneClusterLayout/noticeTextBudget(paneWidth:cornerInset:)``
    /// says this pane can hold.
    ///
    /// The AppKit half of the decision only. Where the sentence stops is
    /// ``PaneChrome/PaneClusterLayout/noticeCut(_:budget:measure:)``'s, in the
    /// package where the tests can reach it; what remains here is the one thing
    /// that genuinely needs a window's frameworks, measuring a string in a font.
    ///
    /// `superview` and not `window`: the budget is about the pane the pill
    /// floats over, which is the view this one is installed in
    /// (`TerminalPaneController.installClusterView()`). With no superview there
    /// is no pane to fit and the text passes through unbudgeted, which only
    /// happens before installation, when nothing is on screen to overflow.
    private func noticeText(_ text: String) -> String {
        guard let paneWidth = superview?.bounds.width else { return text }
        return PaneClusterLayout.noticeCut(
            text,
            budget: PaneClusterLayout.noticeTextBudget(
                paneWidth: Double(paneWidth),
                cornerInset: cornerInset
            ),
            measure: { Double(self.attributed($0, ink: self.theme.foreground).size().width) }
        )
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
            // The backing under the material, before the fill: the pill's own
            // shape in `theme.background` at the `PaneWash` floor, so what is
            // beneath — prompt text, whatever the terminal is showing — never
            // reads through into the segment ink (owner ruling, 2026-08-12:
            // the fills alone are 0.44/0.52 alpha and text beneath collided
            // with the segments). The construction and the 0.5 are
            // ``ChromeMaterials/PaneWash``'s, cited rather than re-derived:
            // its doc carries the measured bound (`alpha >= (B - 75) / (B - 20)`,
            // 0.4712 on the brightest backdrop this repo has measured) that
            // makes 0.5 a legibility floor and not a taste. A floor and never
            // a ceiling, per the same contract: the `chrome.cluster.opacity`
            // dial thins the material fill above, never this backing, so
            // dialling the pill toward the backdrop cannot dial the text into
            // it. Flat is untouched — its `barBackground` fill is already
            // opaque undialled.
            nsColor(theme.background, alpha: ChromeMaterials.PaneWash.floor).setFill()
            pill.fill()

            let fill = framesForFocus ? set.fillThick : set.fillChrome
            nsColor(fill.rgb, alpha: fill.alpha * fillAlpha).setFill()
        } else {
            nsColor(theme.barBackground, alpha: fillAlpha).setFill()
        }
        pill.fill()

        // The hot wash behind the segment whose card is up, over the fill and
        // under the ink — the design mockup's active treatment. Half a gap
        // wider than the segment on each side, so the glyphs get breathing
        // room without touching a neighbour, and always inside the pill's
        // ends because `horizontalInset` (8) exceeds the outset (4). White at
        // 0.14 is a starting value chosen to read brighter than both fills
        // (chrome and thick are dark paint); the exact alpha and the 4 pt
        // radius are dial-in fodder, not tokens. Off the same cached `placed`
        // the segments draw from, via `segmentRect(for:)`, so the wash cannot
        // land beside the segment it highlights; a role no longer placed
        // (the status moved while its card was up) washes nothing.
        if let activeRole, let active = segmentRect(for: activeRole) {
            let wash = active.insetBy(dx: -PaneClusterMetrics.segmentGap / 2, dy: 3)
            NSColor(white: 1, alpha: 0.14).setFill()
            NSBezierPath(roundedRect: wash, xRadius: 4, yRadius: 4).fill()
        }

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
            switch placement.segment.role {
            case .attention:
                let dot = NSRect(
                    x: placement.x,
                    y: (bounds.height - PaneClusterMetrics.dotDiameter) / 2,
                    width: PaneClusterMetrics.dotDiameter,
                    height: PaneClusterMetrics.dotDiameter
                )
                nsColor(attentionColour).setFill()
                NSBezierPath(ovalIn: dot).fill()
            case .notice:
                // The one segment whose ink is graded rather than taken
                // ungraded from the theme, and the exception has a reason the
                // paragraph above states in the other direction. The resting
                // segments are theme foreground on a surface the footer already
                // judges its own ink against, so grading them would be repairing
                // a colour that measures 9.62:1 (`cluster-legibility`'s resting
                // arm). The notice is `theme.alert` — a hue, not a luminance
                // tier — and nothing has measured *it* on this pill, so it goes
                // through the package's own chain. See
                // ``PaneChrome/PaneClusterInk/noticeInk(theme:chrome:)``.
                //
                // The cut string cached at measure time, not re-cut here. It
                // was re-cut per draw until the fifth review, on the reasoning
                // that calling the same function again keeps the drawn string
                // and the pill's width the same string — which is true, and
                // cheaper as one stored value: `needsDisplay` is raised by a
                // theme edit, a focus change and a window activation, none of
                // which move the cut, and each was paying for the whole loop.
                // `?? text` cannot be reached (the cut is written in the same
                // pass that places this segment) and draws the uncut sentence
                // rather than nothing if it ever is.
                let string = attributed(
                    noticeCut ?? placement.segment.text,
                    ink: PaneClusterInk.noticeInk(theme: theme, chrome: resolvedChrome)
                )
                string.draw(at: NSPoint(
                    x: placement.x,
                    y: (bounds.height - string.size().height) / 2
                ))
            case .operation:
                // Graded rather than taken raw, the notice's exception for the
                // notice's reason: `theme.warn` is a hue-bearing blend and not a
                // luminance tier, so nothing guarantees it clears the floor on
                // the pill's face the way `theme.foreground` provably does. It
                // needs the chain more than the notice does — `warn` is blended
                // three-quarters of the way *toward* the background, so it
                // starts nearer the surface it is drawn on than `alert` ever
                // does. See ``PaneChrome/PaneClusterInk/operationInk(theme:chrome:)``,
                // which also carries why this tier is warn and not the notice's
                // alert.
                let string = attributed(
                    placement.segment.text,
                    ink: PaneClusterInk.operationInk(theme: theme, chrome: resolvedChrome)
                )
                string.draw(at: NSPoint(
                    x: placement.x,
                    y: (bounds.height - string.size().height) / 2
                ))
            default:
                let string = attributed(placement.segment.text, ink: theme.foreground)
                string.draw(at: NSPoint(
                    x: placement.x,
                    y: (bounds.height - string.size().height) / 2
                ))
            }
        }
    }
}
