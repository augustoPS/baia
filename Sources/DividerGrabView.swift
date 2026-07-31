import AppKit

/// The grab area over a divider.
///
/// **In its own file, and that is what makes the sidebar probeable.** It was the
/// last hundred lines of `SurfaceHosts.swift`, which reaches `PaneTreeController`
/// and therefore libghostty, a Metal device and a spawned shell. `SurfaceTitleView`
/// names `DividerGrabView.Touch`, so `WorkspaceSurface.swift` could not be
/// compiled by anything that was not the whole app, and neither could
/// `ChangesSurface.swift` beside it. `Diagnostics/clip-layout` compiles all three
/// verbatim and needs none of the terminal. Nothing here reaches past AppKit,
/// which is what let it move.
///
/// Transparent and wider than the hairline beneath it, because a 1 pt drag target is
/// one nobody can hit. Refuses first responder like everything else in this window:
/// a drag must not cost the panes their ghostty bindings.
@MainActor
final class DividerGrabView: NSView {
    enum Axis {
        /// The split between two stacked sections. Costs nothing: it moves inside a
        /// column whose width does not change.
        case vertical
        /// The sidebar's own edge. This one takes width from the panes, so every
        /// frame of the drag resizes every ghostty grid and signals every process
        /// running in them. Measured on 2026-07-27 at about thirty signals a second
        /// while the mouse moves, with a coding agent redrawing whole each time.
        case horizontal
    }

    /// How a strip is being touched, which is all it reports: the mark is drawn by
    /// whatever owns the edge, inside its own fixed height.
    ///
    /// Design v3 §4.3. The split between two stacked sections has no mark at rest,
    /// because §1 put the body and the heading on different materials and that
    /// boundary is already visible. What was missing was not a line but a **reply**:
    /// the same three-state vocabulary the divider between two panes uses, so an
    /// undiscoverable control becomes discoverable on approach and the column gains
    /// no permanent chrome for something used once a session.
    enum Touch { case rest, hover, drag }

    private let axis: Axis
    private let onDrag: (Double) -> Void

    /// Raised whenever the strip is approached, pressed or released.
    var onTouch: ((Touch) -> Void)?

    private var touch: Touch = .rest {
        didSet {
            guard touch != oldValue else { return }
            onTouch?(touch)
        }
    }

    init(axis: Axis, onDrag: @escaping (Double) -> Void) {
        self.axis = axis
        self.onDrag = onDrag
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var acceptsFirstResponder: Bool { false }

    /// The cursor comes off the tracking area rather than off a cursor rect.
    ///
    /// **They are two separate books and they were not agreeing.** A cursor rect is
    /// registered once from `resetCursorRects` and is not rebuilt when the view
    /// moves; the strip is laid out after that, so the rect stayed where the strip
    /// used to be and the pointer changed shape about half a strip above where the
    /// strip actually was. Invalidating on every frame change improved it and did
    /// not fix it.
    ///
    /// A tracking area has none of that: AppKit rebuilds it on a frame change,
    /// which `Diagnostics/clip-layout`'s `tracking` arm holds it to, and this view
    /// already keeps one for the hover reply. Putting the cursor on the same area
    /// makes the shape change and the colour change the same event, so they cannot
    /// drift apart again.
    private var resizeCursor: NSCursor {
        axis == .vertical ? .resizeUpDown : .resizeLeftRight
    }

    override func cursorUpdate(with _: NSEvent) {
        resizeCursor.set()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow],
            owner: self
        ))
    }

    override func mouseEntered(with _: NSEvent) {
        touch = .hover
    }

    override func mouseExited(with _: NSEvent) {
        // Not during a drag: the pointer leaves this seven point strip immediately
        // and the drag is still going, so exiting must not say it stopped.
        guard touch != .drag else { return }
        touch = .rest
    }

    /// Tracked here rather than through `mouseDragged`, so the drag keeps following
    /// the pointer when it leaves this seven point strip, which it does immediately.
    override func mouseDown(with event: NSEvent) {
        touch = .drag
        var last = event.locationInWindow
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let delta = axis == .vertical
                ? next.locationInWindow.y - last.y
                : next.locationInWindow.x - last.x
            onDrag(delta)
            last = next.locationInWindow
        }
        // Back to hover rather than to rest when the pointer is still on the strip,
        // which is where a drag that ends without moving away leaves it.
        touch = bounds.contains(convert(
            window?.mouseLocationOutsideOfEventStream ?? .zero,
            from: nil
        )) ? .hover : .rest
    }
}
