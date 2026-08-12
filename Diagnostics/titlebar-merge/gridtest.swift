import AppKit
import GhosttyTerminal
import WorkspaceLayout

// Route A's unmoved rect, measured as an unmoved GRID.
//
// Arm 5 of `mergetest.swift` measured the pane tree's *rectangle* identical
// between the shipped arrangement and a `.fullSizeContentView` window whose
// sidebar column extends under the titlebar band while the tree's rect is held:
// `dx=0 dy=0 dw=0 dh=0 dtop=0`. That is the precondition for "no grid moves",
// and the README records exactly what it is not:
//
//   > Route A's tree region is a rect, not a grid. [...] the stand-in is an
//   > `NSColor` fill, not a surface with a cell metric, and this probe spawns no
//   > PTY by construction. An unmoved rect cannot produce a different grid — the
//   > grid is a function of the rect and the cell size — but the chain is argued
//   > here rather than measured end to end.
//
// This binary is that follow-up. It puts a REAL ghostty surface on a REAL PTY in
// the pane tree's region under both arrangements and reads
// `terminalDidResize(columns:rows:)` — the same callback the app listens on and
// the same size the shell is told. The claim under test is not "the rect is
// equal" (arm 5 settled that) but **rows and columns are identical**, which is
// the thing a `SIGWINCH` would carry.
//
// **What would be false if this passed and the code were wrong.** The failure
// mode this probe exists to catch is a rect that measures equal in points while
// the grid derived from it differs — which happens if anything between the rect
// and the cell arithmetic differs between the arrangements (a backing scale read
// at a different moment, a padding applied per style mask, a surface laid out
// against `contentLayoutRect` rather than against its own frame). Arm 5 cannot
// see any of those, because an `NSColor` fill has no cell metric to derive. If
// this probe reports equal rows and columns, all of them are excluded on the
// path a real surface takes. If it reports a difference, arm 5's rect equality
// is a true statement about points and a false statement about the terminal, and
// **route A's recommendation reverses** — which is the single most valuable
// result available here and is reported as the headline either way.
//
// Two measurements, because they answer different questions and only one of them
// can be answered by the arrangement `gridtest.swift` in `glass-backdrop` uses:
//
//   1. AT REST. One window per arrangement, built, measured, torn down. This is
//      `glass-backdrop/gridtest.swift`'s shape and its reasoning holds here: the
//      question is what the grid IS for a given geometry, and a window resized
//      between arms reports a transition whose endpoint can be reached by a path
//      the app never takes.
//   2. ACROSS THE FLIP. One live surface, on one PTY, driven from the shipped
//      arrangement into route A's while it runs. This is the arrangement the
//      at-rest measurement cannot produce, and it is the only one that can
//      observe a `SIGWINCH`: a signal is delivered to a child that exists across
//      the change, and two separate windows have two separate children.
//
// Measurement 2 was also meant to observe the `SIGWINCH` itself, by trapping it
// in the surface's shell and counting markers in a file. **It cannot, and the
// probe measured why rather than reporting the zero it wanted.** Under this
// harness — a `swiftc`-linked binary against the Debug build products, outside
// the app bundle — no shell child is spawned: a diagnostic run's `ps` over the
// probe's process group listed only the probe binary, and a trap line sent with
// `sendText` was echoed onto the surface and never executed, before or after a
// resize that provably changed the grid. libghostty draws the prompt; there is no
// zsh behind it here.
//
// The counting is kept, and measurement 3 is what stops it being read as a
// result: a deliberate grid-changing resize produces the same zero. A number a
// known-positive case also produces measures nothing. So the grid equality is
// asserted and the marker count is only printed, and observing the signal itself
// needs the app's own surface-spawning environment — a different probe than this
// one.

// MARK: - the observer

/// Records every grid size the surface reports, in order.
///
/// Conforms to `TerminalSurfaceResizeDelegate` and deliberately NOT to
/// `TerminalSurfaceGridResizeDelegate`. `TerminalSurfaceCoordinator` dispatches
/// its delegate by `as?` casts and tests the grid variant first in an `else if`
/// (`TerminalSurfaceCoordinator.swift:209-211`), so conforming to both would
/// silence this method with no error at all. `glass-backdrop/gridtest.swift`
/// carries the identical warning and the app target carries it at
/// `Sources/TerminalPaneController.swift`; getting it wrong here would produce a
/// probe that reports "no resize happened" for every arrangement, which is the
/// answer this probe most wants to be true and therefore the one it must be
/// least able to fake.
final class GridObserver: NSObject, TerminalSurfaceResizeDelegate {
    struct Sample: Equatable {
        let columns: Int
        let rows: Int

        var description: String { "\(columns) x \(rows)" }
    }

    private(set) var samples: [Sample] = []

    var latest: Sample? { samples.last }

    func terminalDidResize(columns: Int, rows: Int) {
        samples.append(Sample(columns: columns, rows: rows))
    }

    /// Samples recorded since a mark, which is how the flip measurement separates
    /// "the grid the surface settled at before the flip" from "everything the
    /// flip itself caused".
    func samples(since mark: Int) -> [Sample] {
        guard mark < samples.count else { return [] }
        return Array(samples[mark...])
    }

    var mark: Int { samples.count }
}

/// Runs the run loop for an interval. Never `Thread.sleep`: the surface's resize
/// callback arrives on the main run loop, and sleeping would mean measuring a
/// grid that had not been told about the new frame yet.
func settle(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

// MARK: - the two arrangements

/// The two window arrangements arm 5 compares, reproduced here with a real
/// surface in the place arm 5 put its `NSColor` stand-in.
///
/// The geometry is arm 5's, restated in one place rather than transcribed twice:
/// both arrangements are held to the same window FRAME, and the style mask
/// decides only how the content view is inset within it. That normalisation is
/// the load-bearing line in `mergetest.swift` (`normalisedFrame`), and the
/// README records the run where its absence produced `dtop=-98.0` — 58 pt of
/// probe bug wearing 40 pt of finding. A grid measurement without it would
/// report a row difference that is the probe's own chrome arithmetic.
enum Arrangement: String, CaseIterable {
    /// Today's style mask, and the tree's rect as the app computes it: the
    /// content view stops below the band, and the surface fills it beside the
    /// column.
    case shipped = "shipped"

    /// `.fullSizeContentView`, the sidebar column's rect extended up under the
    /// band, and the tree's rect held at the row arm 1's content view tops out
    /// at. Arm 5's split, with a PTY behind it.
    case splitRect = "split-rect"

    var wantsFullSizeContentView: Bool { self == .splitRect }

    var label: String {
        switch self {
        case .shipped: "1 shipped"
        case .splitRect: "5 split-rect"
        }
    }
}

// MARK: - the window

/// One arrangement's window, with a real ghostty surface in the pane tree's
/// region.
///
/// Everything not under test is held at `mergetest.swift`'s values and read off
/// the packages at run time where they exist (`SidebarGeometry.default.width`),
/// so an arrangement claiming to reproduce the shipped one cannot grade against
/// a number that has moved.
final class GridProbeWindow: NSWindow {
    private var heldToolbar: NSToolbar?
    private var heldViews: [NSView] = []

    /// The surface itself, held so the flip measurement can re-frame it and so
    /// the teardown can detach it before the window goes.
    private(set) var terminal: AppTerminalView?

    /// The pane tree's region in WINDOW coordinates, read off the surface's live
    /// frame after layout.
    ///
    /// Window coordinates rather than content-view coordinates, for the reason
    /// `mergetest.swift` documents at `treeRegionFrame`: under
    /// `.fullSizeContentView` the content view's own origin moves relative to
    /// the window, so a content-relative read would report "unmoved" for a
    /// region that moved on screen. Reported here beside the grid so the two
    /// halves of the claim — the rect arm 5 measured and the grid this probe
    /// measures — can be read against each other in one table.
    private(set) var treeRegionFrame: NSRect = .zero

    /// The band's height, read off the window rather than written as 40, for the
    /// reason `layoutTitlebarGlass()` gives: it is whatever the window is
    /// currently spending on chrome, so a toolbar metric this probe does not
    /// control cannot leave the surface short of the region it is filling.
    private(set) var bandHeight: CGFloat = 0

    private static func normalisedFrame(for contentRect: NSRect) -> NSRect {
        let shipped: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        return NSWindow.frameRect(forContentRect: contentRect, styleMask: shipped)
    }

    init(arrangement: Arrangement, contentRect: NSRect, observer: GridObserver) {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if arrangement.wantsFullSizeContentView { style.insert(.fullSizeContentView) }

        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: .buffered,
            defer: false
        )

        title = "baia"
        subtitle = "~/Projects/baia"

        // `mergetest.swift`'s window arrangement, which is
        // `WorkspaceWindowController.applyTransparency()`'s: non-opaque, with a
        // background one step off clear rather than `.clear`, because the
        // titlebar material renders as nothing over a clear background.
        isOpaque = false
        backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.005)
        hasShadow = false
        isMovable = true
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]

        // The empty toolbar is what gives the window a titlebar band at all on
        // macOS 26, and `.unifiedCompact` is the metric the app buys with it.
        // Reproduced rather than skipped: without the toolbar the band is a
        // different height, and the surface would be sized against a window baia
        // does not ship — which for a GRID measurement means a row count that is
        // not the app's.
        let toolbar = NSToolbar(identifier: "probe.titlebar-merge.grid.\(arrangement.rawValue)")
        heldToolbar = toolbar
        self.toolbar = toolbar
        toolbarStyle = .unifiedCompact
        titlebarAppearsTransparent = true

        let content = NSView(frame: .zero)
        content.wantsLayer = true
        contentView = content

        // **Both arrangements forced to the SAME WINDOW FRAME.** Without this the
        // two windows differ by the chrome (`mergetest.swift` measured a 380 pt
        // content rect producing a 478 pt frame without the flag and 380 pt with
        // it), and the grid comparison would be reading 98 pt of style-mask
        // bookkeeping as a route A cost.
        setFrame(Self.normalisedFrame(for: contentRect), display: false)

        bandHeight = frame.height - contentLayoutRect.height
        let columnWidth = CGFloat(SidebarGeometry.default.width)

        // Derived from the LIVE content view, never from the `contentRect` this
        // window was asked for: adding a toolbar grows it, and sizing a surface
        // against the requested rect would put the grid arithmetic on a rect the
        // window does not have.
        let bounds = content.bounds
        let width = bounds.width
        let height = bounds.height

        // The content view is UNFLIPPED: y = 0 is its bottom edge.
        //
        // Under `.fullSizeContentView` the content view spans the whole window,
        // so its top edge is the window's top edge and `height` already includes
        // the band; the tree is held back to `height - bandHeight`, which is the
        // same absolute row in window terms that the shipped arrangement's tree
        // reaches. Under the shipped mask the content view already stops below
        // the band, so its full height IS the region below it. That difference is
        // the whole arrangement, and it is computed rather than assumed.
        let treeTop = arrangement.wantsFullSizeContentView ? height - bandHeight : height

        // The sidebar column's glass, which under route A extends up under the
        // band and under the shipped arrangement stops at the content view's top
        // edge. Present in both, because the surface sits beside it and a
        // measurement that omitted it would size the tree region against a
        // window with no sidebar.
        let columnGlass = NSGlassEffectView(frame: NSRect(
            x: 0,
            y: 0,
            width: columnWidth,
            height: arrangement.wantsFullSizeContentView ? height : treeTop
        ))
        columnGlass.style = .regular
        columnGlass.cornerRadius = 0
        content.addSubview(columnGlass, positioned: .below, relativeTo: nil)
        heldViews.append(columnGlass)

        // **The surface, in the pane tree's region.** This is arm 5's stand-in
        // rect, to the point, with a real PTY behind it instead of a fill.
        let terminal = AppTerminalView(frame: NSRect(
            x: columnWidth,
            y: 0,
            width: width - columnWidth,
            height: treeTop
        ))
        terminal.delegate = observer

        let configuration = TerminalConfiguration()
            .windowPaddingX(basePadding)
            .windowPaddingY(basePadding)

        let controller = TerminalController(
            configSource: .none,
            theme: .default,
            terminalConfiguration: configuration
        )

        // `.exec`, never `.inMemory`. The in-memory backend is an emulated
        // sandbox shell with no PTY at all, so its "grid" is a number the library
        // keeps rather than a size a real `SIGWINCH` would carry — and this probe
        // exists precisely because arm 5's stand-in had no PTY. Measuring
        // `.inMemory` would close the gap with a second stand-in.
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: NSHomeDirectory(),
            envVars: ["BAIA_PROBE": "titlebar-merge-grid"]
        )
        terminal.controller = controller
        content.addSubview(terminal)
        self.terminal = terminal

        treeRegionFrame = terminal.convert(terminal.bounds, to: nil)
    }

    /// Re-frames the live surface into the other arrangement's tree rect.
    ///
    /// Used only by the flip measurement. The at-rest measurement builds a
    /// window per arrangement and never calls this, for the reason
    /// `glass-backdrop/gridtest.swift` gives: a resized window reports a
    /// transition, and the at-rest question is what the grid is at rest.
    func reframeSurface(to rect: NSRect) {
        terminal?.frame = rect
        contentView?.layoutSubtreeIfNeeded()
        if let terminal {
            treeRegionFrame = terminal.convert(terminal.bounds, to: nil)
        }
    }

    /// Applies the style-mask half of the flip, which is the part that moves the
    /// content view's origin under the window and is therefore the part that
    /// could move a rect that arithmetic says is held.
    ///
    /// **The frame is re-asserted afterwards, and the first run of this probe
    /// proved why.** Inserting `.fullSizeContentView` on a LIVE window holds the
    /// window's content rect fixed and SHRINKS the frame — measured here at
    /// 412 -> 372 pt — rather than holding the frame and growing the content
    /// view, which is what construction with the flag does. The content view
    /// therefore stayed 372 pt while `contentLayoutRect` dropped to 332, and the
    /// re-frame below then subtracted the band from a height that had already
    /// lost it. The flip reported 19 rows becoming 17: a two-row loss that was
    /// the probe spending the band's 40 pt twice, wearing the shape of route A's
    /// cost.
    ///
    /// `normalisedFrame` is the same correction `init` makes for the same reason,
    /// and the at-rest measurement was never wrong because it makes it. Re-asserting
    /// it here makes the flip a change of style mask within a fixed outer
    /// rectangle, which is what adopting route A on a running window would be.
    func applyFullSizeContentView(_ on: Bool, contentRect: NSRect) {
        if on {
            styleMask.insert(.fullSizeContentView)
        } else {
            styleMask.remove(.fullSizeContentView)
        }
        setFrame(Self.normalisedFrame(for: contentRect), display: false)
        contentView?.layoutSubtreeIfNeeded()
    }

    func teardown() {
        terminal?.removeFromSuperview()
        terminal = nil
        orderOut(nil)
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }
}

// MARK: - setup

let app = NSApplication.shared
// `.accessory` and never key, the standard `SAFE_PROBES` holds `titlebar-merge`
// to and the standard `glass-backdrop`'s grid arm meets. A real PTY is spawned
// but no window is ever activated and `canBecomeKey` is false on both.
app.setActivationPolicy(.accessory)

guard let screen = NSScreen.main else {
    FileHandle.standardError.write("no screen\n".data(using: .utf8)!)
    exit(1)
}

// The base padding the owner's config ships, read as the arithmetic baseline
// rather than assumed zero. `glass-backdrop`'s grid arm learned that
// `window-padding-y` is symmetric and that a probe assuming 0 computes the wrong
// target; nothing here compensates padding, but both arrangements must carry the
// SAME padding or the grid difference would be the padding's.
let basePadding = 8

// `mergetest.swift`'s probe geometry, so the grid is measured on the window the
// rect was measured on. A different size would answer a true question about a
// window arm 5 never used.
let probeWidth: CGFloat = 900
let probeHeight: CGFloat = 380
let chromeAllowance: CGFloat = 60
let screenFrame = screen.frame
let visible = screen.visibleFrame
let desiredTop = min(
    screenFrame.midY + (screenFrame.height / 4) + probeHeight / 2,
    visible.maxY - chromeAllowance
)
let probeFrame = NSRect(
    x: screenFrame.midX - probeWidth / 2,
    y: desiredTop - probeHeight,
    width: probeWidth,
    height: probeHeight
)

print("baia titlebar-merge: route A's rect, measured as a GRID")
print("A real ghostty surface in the pane tree's region under both arrangements.")
print("Arm 5 measured the rect on an NSColor fill; this measures the rows and")
print("columns libghostty derives from it — the size a shell would be told.")
print("window \(Int(probeWidth))x\(Int(probeHeight)) pt content, padding \(basePadding), sidebar \(Int(SidebarGeometry.default.width)) pt")
print("")

var failures = 0

func check(_ passed: Bool, _ message: String) {
    print((passed ? "ok    " : "FAIL  ") + message)
    if !passed { failures += 1 }
}

// MARK: - measurement 1: the grid at rest, per arrangement

/// Builds one arrangement, waits for its surface to reach the PTY, and returns
/// the grid it settled at with the tree rect it settled in.
func measureAtRest(_ arrangement: Arrangement) -> (grid: GridObserver.Sample, rect: NSRect, band: CGFloat, reports: Int)? {
    let observer = GridObserver()
    let window = GridProbeWindow(
        arrangement: arrangement,
        contentRect: probeFrame,
        observer: observer
    )
    window.orderFrontRegardless()

    // Long enough for the surface to spawn its shell, lay out, and report. Sized
    // for a cold libghostty runtime initialisation on the first arrangement,
    // which is the same allowance `glass-backdrop`'s grid arm makes.
    settle(3.0)

    let result = observer.latest
    let rect = window.treeRegionFrame
    let band = window.bandHeight
    let count = observer.samples.count
    window.teardown()
    settle(0.4)

    guard let result else {
        print("\(arrangement.label): NO RESIZE REPORTED — the surface never reached the PTY")
        return nil
    }
    print(String(
        format: "  %-14@  %3d cols x %3d rows   tree rect x=%.1f y=%.1f w=%.1f h=%.1f top=%.1f   band %.0f   (%d report(s))",
        arrangement.label as NSString,
        result.columns,
        result.rows,
        rect.origin.x, rect.origin.y, rect.width, rect.height, rect.maxY,
        band,
        count
    ))
    return (result, rect, band, count)
}

print("=== 1. the grid at rest, one window per arrangement ===")
print("Arm 5's comparison with a real surface where the stand-in was. Identical")
print("rows and columns is the claim; anything else is the cost route A was")
print("thought not to have.")
print("")

let shippedRest = measureAtRest(.shipped)
let routeARest = measureAtRest(.splitRect)

print("")

guard let shippedRest, let routeARest else {
    print("FAILED: an arrangement never reported a grid size")
    exit(1)
}

// **The headline.** Rows and columns, both arrangements, equal or not.
check(
    shippedRest.grid.rows == routeARest.grid.rows,
    "ROWS identical across the arrangements "
        + "(shipped \(shippedRest.grid.rows), route A \(routeARest.grid.rows))"
)
check(
    shippedRest.grid.columns == routeARest.grid.columns,
    "COLUMNS identical across the arrangements "
        + "(shipped \(shippedRest.grid.columns), route A \(routeARest.grid.columns))"
)

// The rect, restated on a real surface. Arm 5 measured this on a fill; measuring
// it again here is what ties this probe's grid numbers to arm 5's rect numbers
// rather than leaving two unconnected results. A rect that differed here while
// arm 5's matched would mean the stand-in and the surface lay out differently,
// which would invalidate arm 5 rather than confirm it.
let dx = routeARest.rect.origin.x - shippedRest.rect.origin.x
let dy = routeARest.rect.origin.y - shippedRest.rect.origin.y
let dw = routeARest.rect.width - shippedRest.rect.width
let dh = routeARest.rect.height - shippedRest.rect.height
check(
    abs(dx) < 0.01 && abs(dy) < 0.01 && abs(dw) < 0.01 && abs(dh) < 0.01,
    String(
        format: "the tree rect is held on a REAL surface too "
            + "(dx=%.1f dy=%.1f dw=%.1f dh=%.1f) — arm 5 measured this on a fill",
        dx, dy, dw, dh
    )
)

// MARK: - measurement 2: the flip, on one live surface

// **The measurement two windows cannot make.** Whatever a `SIGWINCH` would be
// delivered to has to exist across the change, and two windows have two
// children, each of which only ever saw the size it was born at. So the flip is
// performed on ONE surface: the shipped arrangement is built, and then the style
// mask and both rects are changed underneath it exactly as adopting route A
// would change them.
//
// **What this probe can and cannot see, established by measurement rather than
// assumed, and the answer is the reason section 3 exists.** The intent was to
// trap `SIGWINCH` in the surface's shell and count markers. Under this
// harness — a `swiftc`-linked binary against the Debug build products, outside
// the app bundle — no shell child is spawned at all: `ps` against the probe's
// process group during a diagnostic run listed only the probe binary itself,
// and a trap line sent with `sendText` was echoed onto the surface and never
// executed, before OR after a resize that provably changed the grid. libghostty
// draws the prompt; there is no zsh behind it here.
//
// So the marker count is kept and reported, and section 3 is what stops it being
// read as a result: a deliberate grid-changing resize produces the same zero. A
// zero that a known-positive case also produces measures nothing, and the probe
// says so rather than banking it. **The row and column equality below is
// measured; the SIGWINCH count is not, and the two are reported separately for
// that reason.**
print("")
print("=== 2. the flip, on ONE live surface ===")
print("Whatever a SIGWINCH reaches has to exist across the change, and two windows")
print("have two children. So this builds the shipped arrangement and flips the")
print("style mask and both rects underneath a surface that keeps running.")
print("")

let markerPath = NSTemporaryDirectory()
    + "baia-titlebar-merge-winch-\(ProcessInfo.processInfo.processIdentifier).count"
try? FileManager.default.removeItem(atPath: markerPath)

func markerCount() -> Int {
    guard let data = FileManager.default.contents(atPath: markerPath) else { return 0 }
    return data.count
}

let flipObserver = GridObserver()
let flipWindow = GridProbeWindow(
    arrangement: .shipped,
    contentRect: probeFrame,
    observer: flipObserver
)
flipWindow.orderFrontRegardless()
settle(3.0)

let beforeGrid = flipObserver.latest
let beforeRect = flipWindow.treeRegionFrame

// The trap. `printf` appends one byte per signal, and the file is read rather
// than the terminal's own text: reading the grid's text would depend on the
// prompt, the shell's echo and the row the output landed on, all of which the
// flip is allowed to disturb. A file is the one channel the arrangement cannot
// reflow.
//
// Sent only after the surface has settled, so the shell is at a prompt and the
// line is not swallowed by the startup output.
flipWindow.terminal?.sendText(
    // `\r`, not `\n`: a Return key over a PTY sends a carriage return, and a line
    // feed leaves the line sitting on the prompt unsubmitted. Measured during the
    // diagnosis above — with `\n` the trap text was visible on the surface and
    // plainly never run. Fixed so the zero this reports is attributable to the
    // missing child rather than to the probe's own line ending.
    "trap 'printf x >> \(markerPath)' WINCH\r"
)
settle(1.5)

let winchBeforeFlip = markerCount()
let gridMark = flipObserver.mark

// **The flip.** Both halves of what adopting route A does to a running window:
// the style mask gains `.fullSizeContentView` (which moves the content view's
// origin under the window), and the surface is re-framed to the held rect while
// the column beside it is allowed to grow. Performed in that order because that
// is the order the app would perform it: the mask changes, and then the layout
// pass runs against the new bounds.
flipWindow.applyFullSizeContentView(true, contentRect: probeFrame)
if let content = flipWindow.contentView {
    let columnWidth = CGFloat(SidebarGeometry.default.width)
    let height = content.bounds.height
    flipWindow.reframeSurface(to: NSRect(
        x: columnWidth,
        y: 0,
        width: content.bounds.width - columnWidth,
        height: height - flipWindow.bandHeight
    ))
}
settle(2.5)

let afterGrid = flipObserver.latest
let afterRect = flipWindow.treeRegionFrame
let gridReportsDuringFlip = flipObserver.samples(since: gridMark)
let winchAfterFlip = markerCount()

flipWindow.teardown()
settle(0.4)

if let beforeGrid, let afterGrid {
    print(String(
        format: "  before flip     %3d cols x %3d rows   tree rect y=%.1f h=%.1f top=%.1f",
        beforeGrid.columns, beforeGrid.rows,
        beforeRect.origin.y, beforeRect.height, beforeRect.maxY
    ))
    print(String(
        format: "  after flip      %3d cols x %3d rows   tree rect y=%.1f h=%.1f top=%.1f",
        afterGrid.columns, afterGrid.rows,
        afterRect.origin.y, afterRect.height, afterRect.maxY
    ))
    print("  grid reports during the flip: \(gridReportsDuringFlip.count)"
        + (gridReportsDuringFlip.isEmpty
            ? ""
            : "  " + gridReportsDuringFlip.map(\.description).joined(separator: ", ")))
    print("  SIGWINCH markers: \(winchBeforeFlip) before the flip, \(winchAfterFlip) after")
    print("")

    // **This is the assertion, and it is the one measurement 2 can actually
    // make.** The grid is read from `terminalDidResize(columns:rows:)`, which
    // libghostty computes from the surface's real frame and cell metric whether
    // or not a child is attached, so it is a true statement about the size a
    // shell WOULD be told. The marker count below is not, and is not asserted.
    check(
        afterGrid.rows == beforeGrid.rows && afterGrid.columns == beforeGrid.columns,
        "the live grid is unchanged across the flip "
            + "(\(beforeGrid.description) -> \(afterGrid.description))"
    )

    // **The closest this probe gets to the signal, and it is closer than the
    // marker count.** A `SIGWINCH` reaches a child because the terminal called
    // `TIOCSWINSZ` with a new size, and libghostty only does that when the grid
    // it computed differs from the one it holds — the same computation that
    // produces this callback. So ZERO resize reports across the flip is the state
    // in which there is nothing to signal ABOUT: not "the signal was sent and
    // nobody heard", but "no new size was ever computed".
    //
    // That is an inference from libghostty's behaviour rather than an observation
    // of the signal, and it is asserted as what it is. The marker count cannot
    // upgrade it here, for section 3's reason.
    check(
        gridReportsDuringFlip.isEmpty,
        "the flip produced NO grid report at all (\(gridReportsDuringFlip.count)) — "
            + "no new size was computed, so there is nothing for a SIGWINCH to carry"
    )
    print("  (the marker count is reported, not asserted — see section 3)")
} else {
    print("  NOT MEASURED — the live surface never reported a grid size")
    failures += 1
}

// **The positive control, and it is what turns section 2's zero from a result
// into a known blind spot.**
//
// A trap that never armed, a `sendText` that went nowhere, a surface with no
// child behind it: every one of those produces "0 markers", which is exactly the
// number the probe would most like to report. So a deliberate grid-changing
// resize is made on a fresh surface — a change the app would never make, whose
// only job is to show what a REAL grid change does to the counter.
//
// **Measured: it does nothing.** The grid changes (the resize is large enough to
// cross several cell boundaries in both axes and the delegate reports the new
// size), and the marker count stays at zero, because under this harness there is
// no child to signal. That is the finding this section publishes, and it is why
// section 2's zero is reported rather than asserted.
//
// The two halves are therefore graded differently and on purpose: the grid change
// IS asserted, because it proves the measurement path this probe's headline rests
// on is live and can see a difference when there is one to see. The marker count
// is only printed.
print("")
print("=== 3. the control: is a grid change observable, and is a signal? ===")
print("A deliberate grid-changing resize on a fresh surface. The grid change is")
print("asserted — it proves this probe can SEE a difference, so the headline's")
print("equality is not a blind instrument reporting silence. The marker count is")
print("printed only, and what it does here is what makes section 2's zero unusable.")
print("")

let controlPath = NSTemporaryDirectory()
    + "baia-titlebar-merge-winch-control-\(ProcessInfo.processInfo.processIdentifier).count"
try? FileManager.default.removeItem(atPath: controlPath)

func controlCount() -> Int {
    guard let data = FileManager.default.contents(atPath: controlPath) else { return 0 }
    return data.count
}

let controlObserver = GridObserver()
let controlWindow = GridProbeWindow(
    arrangement: .shipped,
    contentRect: probeFrame,
    observer: controlObserver
)
controlWindow.orderFrontRegardless()
settle(3.0)

controlWindow.terminal?.sendText("trap 'printf x >> \(controlPath)' WINCH\r")
settle(1.5)

let controlBefore = controlCount()
let controlGridBefore = controlObserver.latest

// A resize large enough to cross at least one cell boundary in both axes, which
// is what makes it a grid change rather than a sub-cell frame nudge. 120 pt is
// several rows and several columns at any font size this app ships.
if let terminal = controlWindow.terminal {
    var shrunk = terminal.frame
    shrunk.size.height -= 120
    shrunk.size.width -= 120
    controlWindow.reframeSurface(to: shrunk)
}
settle(2.5)

let controlAfter = controlCount()
let controlGridAfter = controlObserver.latest
controlWindow.teardown()
settle(0.4)

if let controlGridBefore, let controlGridAfter {
    print("  deliberate resize  \(controlGridBefore.description) -> \(controlGridAfter.description)")
    print("  SIGWINCH markers: \(controlBefore) before, \(controlAfter) after")
    print("")
    // Asserted: the instrument works. A probe whose headline is an EQUALITY has
    // to prove it can see inequality, or "identical" is indistinguishable from
    // "nothing was measured".
    check(
        controlGridAfter != controlGridBefore,
        "the deliberate resize DID change the grid "
            + "(\(controlGridBefore.description) -> \(controlGridAfter.description)) — "
            + "so this probe can see a grid difference when there is one"
    )

    // Printed, not asserted. This is the blind spot itself.
    if controlAfter > controlBefore {
        print("  note: markers moved on a known grid change (\(controlBefore) -> \(controlAfter)),")
        print("        so the trap IS live here and section 2's zero is a real observation.")
    } else {
        print("  NOT OBSERVABLE: a known grid change moved the counter \(controlBefore) -> \(controlAfter).")
        print("  There is no child process behind the surface under this harness — a")
        print("  diagnostic run's `ps` over the probe's process group listed only the")
        print("  probe binary, and a trap line sent with sendText was echoed and never")
        print("  executed. libghostty draws the prompt; no shell is behind it.")
        print("  So SIGWINCH delivery is NOT measured by this probe, section 2's zero")
        print("  means nothing, and the grid equality above is what carries the result.")
        print("  Measuring the signal needs the app's own surface-spawning environment")
        print("  (a bundled build), which is a different probe than this one.")
    }
} else {
    print("  NOT MEASURED — the control surface never reported a grid size")
    failures += 1
}

try? FileManager.default.removeItem(atPath: markerPath)
try? FileManager.default.removeItem(atPath: controlPath)

// MARK: - the verdict

print("")
print("=== route A, measured as a grid ===")
print("")
print("  shipped        \(shippedRest.grid.description)")
print("  route A        \(routeARest.grid.description)")
print("")

let identical = shippedRest.grid == routeARest.grid
if identical {
    print("  ROUTE A HOLDS THE GRID. The rows and columns libghostty derives from a")
    print("  real surface are identical between the shipped arrangement and route A's")
    print("  split rect, so arm 5's unmoved rect is an unmoved GRID and not only an")
    print("  unmoved rectangle. The chain the README recorded as argued is measured,")
    print("  and the flip produced no grid report at all: the surface was never told")
    print("  anything changed, which is the state in which no SIGWINCH can be sent.")
} else {
    print("  ROUTE A MOVES THE GRID. Arm 5's rect equality does NOT imply grid")
    print("  equality: the numbers above are rows and columns a real shell is told,")
    print("  and they differ. This reverses route A's recommendation — the merge")
    print("  costs a SIGWINCH in every pane, which is the cost the whole line of")
    print("  work exists to avoid.")
}

if failures > 0 {
    print("")
    print("FAILED \(failures)")
    exit(1)
}
print("")
print("PASS")
