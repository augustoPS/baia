import AppKit
import GitWorkspace
import PaneChrome
import WorkspaceLayout

// The clip-layout probe. One bug shape, four arms, each standing where one of the
// found instances stood.
//
// The shape: something is derived from a view's size, the size changes, and the
// derived thing is never rebuilt. A view whose clip has not been laid out reports a
// width of zero or falls to a floor of one, and whatever was built from that
// reading survives for the life of the surface. Every instance so far was found by
// hand and every one took a trace.
//
// `Sources/ChangesSurface.swift`, `Sources/WorkspaceSurface.swift`,
// `Sources/RowFeedback.swift` and `Sources/DividerGrabView.swift` are compiled
// verbatim by `run.sh`, so the view driven here is the view the app installs.

// MARK: - The host

/// A scroll view in a window, sized, laid out, and never ordered front.
///
/// A real `NSWindow` because the tracking arm needs one: `visibleRect` is computed
/// through the clip view, and an `NSTrackingArea` is meaningless outside a window.
/// Off-screen and `.accessory`, so a run takes no focus and shows nothing.
@MainActor
final class Host {
    let window: NSWindow

    init(width: Double, height: Double = 300) {
        window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }

    /// Puts a scroll view in the window, framed by hand.
    ///
    /// **By hand and not with constraints, because that is what the app does.**
    /// `SidebarHost.viewDidLayout` assigns `section.surface.view.frame` directly,
    /// for the reason it records: a column of stacked rects recomputed on resize is
    /// the case autolayout costs more than it saves. The difference is not
    /// cosmetic. A scroll view pinned by constraints resizes its clip without ever
    /// delivering a layout pass to the document view, so a rows view that follows
    /// its clip correctly reads as one that never resized, and every arm here would
    /// measure nothing while looking green.
    func install(_ scroll: NSScrollView) {
        self.scroll = scroll
        window.contentView?.addSubview(scroll)
        frameScroll()
    }

    /// Narrows the column the way a divider drag does: the surface's frame is
    /// reassigned and the window is laid out.
    func resize(to width: Double) {
        window.setContentSize(NSSize(width: width, height: window.frame.height))
        frameScroll()
        settle()
    }

    private var scroll: NSScrollView?

    private func frameScroll() {
        guard let scroll, let content = window.contentView else { return }
        scroll.frame = content.bounds
    }

    /// **`window.layoutIfNeeded()` and not `contentView.layoutSubtreeIfNeeded()`.**
    ///
    /// Measured, because the difference silently invalidates the whole probe: after
    /// a window resize the content view's subtree pass does not reach a scroll
    /// view's document view at all. It reports `needsLayout == false` and its
    /// `layout()` is never called, so a rows view that follows its clip perfectly
    /// would read as one that never resized. The window's own pass does deliver it,
    /// which is also the pass AppKit runs after a live sidebar drag.
    func settle() {
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }
}

// MARK: - What is being driven

/// The two things an arm needs: a scroll view to install, and the document view to
/// measure.
///
/// A pair of closures rather than a protocol, because the control is not a
/// `ChangesSurface` and never will be. What the two sides have in common is exactly
/// this much.
@MainActor
struct Subject {
    let scroll: NSScrollView
    let document: NSView
    /// Pushes `count` rows in, the way the sidebar poller does.
    let setRows: (Int) -> Void
    /// Switches to the "not a repository" state, whose message is what the
    /// ``reflowArm(subject:)`` measures.
    let setAbsent: () -> Void
}

/// The shipped surface, built the way `SidebarHost` builds it.
@MainActor
func shipped() -> Subject {
    let surface = ChangesSurface()
    guard let scroll = surface.view as? NSScrollView, let document = scroll.documentView else {
        fatalError("ChangesSurface stopped being a scroll view with a document view")
    }
    return Subject(
        scroll: scroll,
        document: document,
        setRows: { count in
            surface.hasRepository = true
            surface.changes = (0 ..< count).map { index in
                RepositoryFileChange(
                    path: "Sources/AVeryLongPathThatWantsMoreColumnThanItHas\(index).swift",
                    index: nil,
                    worktree: .modified,
                    kind: .ordinary
                )
            }
        },
        setAbsent: {
            surface.changes = []
            surface.hasRepository = false
            surface.anchorPath = "/Users/somebody/Projects/a/deep/enough/path/to/truncate"
        }
    )
}

/// **The bug, rebuilt.** A rows view that derives everything from the size it
/// happened to see first, and never again.
///
/// The negative control for all four arms, and not a strawman: every line of it is
/// one of the found instances. `derivedWidth` is read in `init`, before any clip
/// view has been laid out, which is where the `1` floor came from. The tracking
/// areas are built once, from `updateTrackingAreas`, which AppKit calls before the
/// clip has a visible rect. `layout()` derives nothing, which is what left a
/// narrowed column drawing its message at the old centring.
@MainActor
final class StaleRowsView: NSView {
    private var derivedWidth: Double
    private var rows = 0
    private var absent = false
    private var builtAreas = false

    override init(frame frameRect: NSRect) {
        // Read now and kept. `superview` is nil at this point, exactly as the clip
        // view's width is zero when a surface is installed before layout.
        derivedWidth = max(frameRect.width, 1)
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }

    func setRows(_ count: Int) {
        rows = count
        // Sized from the width captured at init, which is the whole defect.
        frame = NSRect(x: 0, y: 0, width: derivedWidth, height: Double(count) * Self.rowHeight)
        needsDisplay = true
    }

    func setAbsent() {
        rows = 0
        absent = true
        needsDisplay = true
    }

    /// Derives nothing. `super.layout()` and no more, so a size change reaches
    /// neither the frame, nor the areas, nor the drawing.
    override func layout() {
        super.layout()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard !builtAreas else { return }
        builtAreas = true
        for area in trackingAreas { removeTrackingArea(area) }
        for area in RowFeedback.trackingAreas(
            rows: rows,
            rowHeight: Self.rowHeight,
            in: self,
            owner: self
        ) { addTrackingArea(area) }
    }

    override func draw(_: NSRect) {
        guard absent else { return }
        // Laid out into the width captured at init, which is what put "not a
        // repository" under the divider at the 120 pt floor with nothing to say it
        // had been cut.
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.lineBreakMode = .byWordWrapping
        NSAttributedString(
            string: "not a repository",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.white,
                .paragraphStyle: centred,
            ]
        ).draw(in: NSRect(x: 8, y: 40, width: derivedWidth - 16, height: 60))
    }

    private static let rowHeight: Double = 22
}

/// **The 2026-07-30 instance, which the view above cannot stand in for.**
///
/// That one had nothing wrong with its geometry: the frame followed the clip
/// perfectly and the drawing did not follow the frame. `resize()` only marks a
/// layout pass when the frame actually moves, and a frame change does not repaint
/// on its own, so the message kept the centring it was laid out with.
///
/// A control that is simply one point wide would fail ``reflowArm(subject:)`` by
/// having no width to reflow into, which proves the arm can fail and not that it
/// can catch this. This one is correct everywhere except the one place under test.
@MainActor
final class StaleDrawingView: NSView {
    /// The width the message was laid out for: read when the content arrived and
    /// never again, which is the whole defect.
    ///
    /// Captured here rather than on the first draw, because that is when the
    /// shipped code recomputes: `resize()` runs from the `changes` setter, and what
    /// 2026-07-30 added was the second trigger, a repaint when the frame moves
    /// without the content changing.
    private var paintedWidth: Double = 0
    private var absent = false

    override var isFlipped: Bool { true }

    func setAbsent() {
        absent = true
        paintedWidth = max(superview?.bounds.width ?? bounds.width, 1)
        needsDisplay = true
    }

    /// Follows the clip exactly, the way the shipped view does.
    override func layout() {
        super.layout()
        let width = max(superview?.bounds.width ?? 0, 1)
        let height = max(superview?.bounds.height ?? 0, 1)
        let wanted = NSRect(x: 0, y: 0, width: width, height: height)
        guard frame != wanted else { return }
        frame = wanted
    }

    override func draw(_: NSRect) {
        guard absent else { return }
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.lineBreakMode = .byWordWrapping
        NSAttributedString(
            string: "not a repository",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.white,
                .paragraphStyle: centred,
            ]
        ).draw(in: NSRect(x: 8, y: 40, width: paintedWidth - 16, height: 60))
    }
}

@MainActor
func staleDrawing() -> Subject {
    let scroll = NSScrollView()
    let view = StaleDrawingView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    scroll.documentView = view
    return Subject(
        scroll: scroll,
        document: view,
        setRows: { _ in },
        setAbsent: { view.setAbsent() }
    )
}

@MainActor
func stale() -> Subject {
    let scroll = NSScrollView()
    let view = StaleRowsView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    scroll.documentView = view
    return Subject(
        scroll: scroll,
        document: view,
        setRows: { view.setRows($0) },
        setAbsent: { view.setAbsent() }
    )
}

// MARK: - Measuring

/// Everything an arm compares, read off the view as it stands.
@MainActor
func reading(_ subject: Subject) -> (width: Double, areas: [NSRect]) {
    (subject.document.frame.width, subject.document.trackingAreas.map(\.rect))
}

typealias Render = (pixels: [UInt8], width: Int, height: Int, bytesPerRow: Int)

/// The document view's pixels, at the width it currently has.
@MainActor
func render(_ view: NSView) -> Render? {
    guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.bitmapData else { return nil }
    return (
        pixels: Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh)),
        width: rep.pixelsWide,
        height: rep.pixelsHigh,
        bytesPerRow: rep.bytesPerRow
    )
}

/// The top-left `columns` x `rows` pixels of a render, so two bitmaps that differ
/// in size can be compared over the part they share.
///
/// Both dimensions are clipped, not just the width. A column that changes width
/// also changes the height of a document view sized to its clip, and a comparison
/// that let the row count vary would report "different" for two identical drawings
/// with a different number of blank rows under them.
func corner(_ render: Render, columns: Int, rows: Int) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(columns * rows * 4)
    for row in 0 ..< min(rows, render.height) {
        let start = row * render.bytesPerRow
        out.append(contentsOf: render.pixels[start ..< start + min(columns, render.width) * 4])
    }
    return out
}

@discardableResult
func check(_ passed: Bool, _ label: String, _ detail: String = "") -> Bool {
    print("  \(passed ? "ok  " : "FAIL") \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    return passed
}

// MARK: - The arms

/// **The instance that cost the most, 2026-07-29.** A surface installed and
/// populated before its clip view has a size must not keep the width it read then.
///
/// `resize()` reads the clip view's width, the clip view has not been laid out when
/// a surface is first installed, so the width fell to the `1` floor and every row
/// drew into a document view one point wide. Any command afterwards made the poller
/// re-assign `changes`, by which time the clip had a real width, which is why it
/// looked like the sidebar needed a command to wake up.
///
/// The order below is the order that produced it: build, install, push rows, and
/// only then lay out.
@MainActor
func floorArm(subject: Subject) -> Bool {
    let host = Host(width: 220)
    host.install(subject.scroll)
    // Before any layout pass, which is the whole point.
    subject.setRows(13)
    host.settle()

    let after = reading(subject)
    var ok = check(
        after.width > 1,
        "the document view is not stuck on the 1 pt floor",
        String(format: "%.1f pt", after.width)
    )
    ok = check(
        abs(after.width - 220) < 1,
        "it is the clip view's width",
        String(format: "%.1f pt against 220", after.width)
    ) && ok
    return ok
}

/// A resize after the surface has settled: the document view follows the clip.
@MainActor
func widthArm(subject: Subject) -> Bool {
    let host = Host(width: 220)
    host.install(subject.scroll)
    host.settle()
    subject.setRows(13)
    host.settle()

    let wide = reading(subject)
    host.resize(to: 120)
    let narrow = reading(subject)

    // The clip is printed beside the document on purpose. If the two disagree the
    // rows view is at fault; if the clip itself never moved, the host is, and the
    // arm is measuring nothing rather than measuring something that passed.
    print(String(
        format: "  clip now %.1f pt, document %.1f -> %.1f pt",
        subject.scroll.contentView.bounds.width, wide.width, narrow.width
    ))

    var ok = check(abs(wide.width - 220) < 1, "wide reads 220", String(format: "%.1f", wide.width))
    ok = check(
        abs(narrow.width - 120) < 1,
        "narrow reads 120",
        String(format: "%.1f", narrow.width)
    ) && ok
    ok = check(wide.width != narrow.width, "the width moved at all") && ok
    return ok
}

/// **The instance that left a surface unhoverable for its whole life, 2026-07-29.**
///
/// The areas cover the rows the clip can show, so they have to follow both the size
/// and the scroll. A surface whose clip had not been laid out built them against an
/// empty visible rect, which is zero areas, and nothing rebuilt them: design v3
/// §2.3's four row states had nothing to fire them.
@MainActor
func trackingArm(subject: Subject) -> Bool {
    let host = Host(width: 220)
    host.install(subject.scroll)
    subject.setRows(40)
    host.settle()

    let initial = reading(subject)
    var ok = check(
        !initial.areas.isEmpty,
        "areas exist after the first layout",
        "\(initial.areas.count)"
    )

    host.resize(to: 120)
    let narrow = reading(subject)
    ok = check(!narrow.areas.isEmpty, "areas survive a resize", "\(narrow.areas.count)") && ok
    let widest = narrow.areas.map(\.width).max() ?? 0
    ok = check(
        widest <= 121,
        "every area is inside the new width",
        String(format: "widest %.1f pt against 120", widest)
    ) && ok
    ok = check(
        widest > 100,
        "and covers it rather than collapsing",
        String(format: "widest %.1f pt", widest)
    ) && ok

    // Scrolling changes which rows the clip can show without changing this view's
    // frame, and a frame change is the only thing AppKit calls `updateTrackingAreas`
    // for by itself.
    let before = narrow.areas.map(\.minY).min() ?? 0
    subject.scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
    subject.scroll.reflectScrolledClipView(subject.scroll.contentView)
    host.settle()
    let after = reading(subject).areas.map(\.minY).min() ?? 0
    ok = check(
        after > before,
        "and they follow a scroll",
        String(format: "top area moved from %.0f to %.0f pt", before, after)
    ) && ok
    return ok
}

/// **The 2026-07-30 instance.** What is drawn has to be laid out for the width the
/// view has now.
///
/// The empty and absent states are centred in the visible rect rather than at a row
/// origin, so a column the owner narrowed kept the centring it had before and the
/// message ran on under the divider: at the 120 pt floor "not a repository" showed
/// as "not a r". The rows themselves never exposed it, because a row draws from a
/// left inset that does not move, which is why this arm uses the absent state.
///
/// Measured as the leftmost 120 pt of two renders, one at each width. A view that
/// re-lays its text out draws something different there. A view drawing from a
/// captured width draws the same pixels and loses only the part that no longer
/// fits, which is a crop rather than a reflow, and the shared band gives it away.
@MainActor
func reflowArm(subject: Subject) -> Bool {
    let host = Host(width: 220)
    host.install(subject.scroll)
    // Settled first, so the content arrives into a column that already has its
    // width. That is the real sequence: the poller pushes state into a sidebar the
    // owner has been looking at, and only then is the divider dragged. Pushing
    // before the first layout is ``floorArm(subject:)``'s question, not this one.
    host.settle()
    subject.setAbsent()
    host.settle()

    guard let wide = render(subject.document) else {
        return check(false, "the wide column rendered nothing")
    }
    host.resize(to: 120)
    guard let narrow = render(subject.document) else {
        return check(false, "the narrow column rendered nothing")
    }

    let columns = min(wide.width, narrow.width)
    let rows = min(wide.height, narrow.height)
    print("  wide \(wide.width)x\(wide.height) px, narrow \(narrow.width)x\(narrow.height) px, "
        + "compared over \(columns)x\(rows)")
    let changed = corner(wide, columns: columns, rows: rows)
        != corner(narrow, columns: columns, rows: rows)
    return check(
        changed,
        "the message is laid out for the width it has now",
        changed
            ? "the shared corner differs"
            : "identical over the shared corner, so it was cropped rather than reflowed"
    )
}

// MARK: - Entry

@main
enum Probe {
    @MainActor static func main() {
        let app = NSApplication.shared
        // Never takes the screen. The window is built off-screen and is never
        // ordered front, so a run is invisible.
        app.setActivationPolicy(.accessory)

        let arm = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
        let breakIt = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "break"
        print("== \(arm)\(breakIt ? " (negative control: the bug as it was)" : "")")

        // Two controls, because the shape has two halves and one stand-in cannot
        // carry both. `stale()` never re-derives its geometry, which is where the
        // 2026-07-29 instances lived. `staleDrawing()` has perfect geometry and
        // paints from a width it captured once, which is where the 2026-07-30 one
        // lived, and a control that was simply one point wide would fail `reflow`
        // by having nothing to reflow into rather than by failing to reflow.
        let control = arm == "reflow" ? staleDrawing() : stale()
        let subject = breakIt ? control : shipped()

        let ok: Bool
        switch arm {
        case "floor": ok = floorArm(subject: subject)
        case "width": ok = widthArm(subject: subject)
        case "tracking": ok = trackingArm(subject: subject)
        case "reflow": ok = reflowArm(subject: subject)
        default:
            print("usage: cliptest floor|width|tracking|reflow [break]")
            ok = false
        }

        print(ok ? "PASS" : "FAIL")
        fflush(stdout)
        exit(ok ? 0 : 1)
    }
}
