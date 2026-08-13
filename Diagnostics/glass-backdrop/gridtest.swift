import AppKit
import GhosttyTerminal

// The SIGWINCH wall, measured rather than reasoned about.
//
// Arm 3 of the backdrop spike ("the surface view extends under the bar while the
// grid keeps its inset via ghostty padding") is only viable if extending the
// surface does not cost the terminal a row. A grid change is a `SIGWINCH` to
// whatever is running in the pane, and in a pane driving a coding agent that
// reflows the agent's output. `PaneChromeMetrics`' own doc comment is built
// entirely around that hazard — and records that the footer's deletion closed
// it, leaving this measurement as the reason the 22 pt is still written down.
//
// So this binary does what the four-arm capture binary cannot. It spawns a real
// ghostty surface on a real PTY and reads `terminalDidResize(columns:rows:)`,
// which is the callback the app itself listens on and the same signal the shell
// receives, across three geometries:
//
//   A. inset      the shipped arrangement. The surface view stops 22 pt above the
//                 window's bottom edge, and the bar occupies that strip.
//   B. extended   the surface view runs to the bottom edge, 22 pt taller, with
//                 the bar floating over its last 22 pt and no padding change.
//   C. compensated  the surface view runs to the bottom edge AND ghostty's
//                 `window-padding-y` is raised so the *grid* keeps the inset the
//                 bar needs.
//
// A equals B in rows is the failure the arm must avoid; what the arm needs is
// C's rows equal to A's rows, because that is "extends under the bar, grid
// unchanged". B is measured too, and is the honest statement of what the arm
// costs if the padding compensation is not applied.
//
// A constraint found while writing this and not visible from the plan:
// `window-padding-y` is a single symmetric value applied to the top and the
// bottom both (`TerminalConfiguration.windowPaddingY(Int)` renders one
// `window-padding-y = n` line, and `Settings.windowPadding` is explicitly one
// value for both axes). There is no bottom-only padding key. So C cannot buy back
// exactly 22 pt at the bottom; it buys back 22 pt at the bottom *and* 22 pt at the
// top, and the top 22 pt is a real loss of drawable area the shipped arrangement
// does not pay. That is a fact the verdict has to carry, and it is measured below
// rather than asserted.

// MARK: - the observer

/// Records every grid size the surface reports, in order.
///
/// Conforms to `TerminalSurfaceResizeDelegate` and deliberately NOT to
/// `TerminalSurfaceGridResizeDelegate`. The surface coordinator dispatches its
/// delegate by `as?` casts and tests the grid variant first in an `else if`, so
/// conforming to both would silence this method with no error at all. The app
/// target carries the identical warning at
/// `Sources/TerminalPaneController.swift:1175`; getting it wrong here would
/// produce a probe that reports "no resize happened" for every arm.
final class GridObserver: NSObject, TerminalSurfaceResizeDelegate {
    struct Sample {
        let columns: Int
        let rows: Int
    }

    private(set) var samples: [Sample] = []

    var latest: Sample? { samples.last }

    func terminalDidResize(columns: Int, rows: Int) {
        samples.append(Sample(columns: columns, rows: rows))
    }

    func reset() { samples = [] }
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

// MARK: - main

let app = NSApplication.shared
// `.accessory` and never key, the same standard the capture binary meets. A real
// PTY is spawned but no window is ever activated.
app.setActivationPolicy(.accessory)

let barHeight: CGFloat = 22
let windowWidth: CGFloat = 720
let windowHeight: CGFloat = 480

// The base padding the owner's config ships. Read as the arithmetic baseline for
// arm C rather than assumed zero: compensation has to be *added to* whatever is
// already set, and a probe that assumed 0 would compute the wrong target.
let basePadding = 8

guard let screen = NSScreen.main else {
    FileHandle.standardError.write("no screen\n".data(using: .utf8)!)
    exit(1)
}

/// Builds a window with a real ghostty surface at a given surface height and
/// padding, waits for the grid to settle, and returns what the PTY reported.
///
/// One window per arm, torn down after. A single window resized between arms
/// would be the cheaper shape and the wrong one: the arm is about what the grid
/// is at rest for a given geometry, and a resized window reports a *transition*
/// whose endpoint can be reached by a path that the shipped app never takes.
func measure(
    label: String,
    surfaceHeight: CGFloat,
    paddingY: Int
) -> GridObserver.Sample? {
    let frame = NSRect(
        x: screen.frame.midX - windowWidth / 2,
        y: screen.frame.midY - windowHeight / 2,
        width: windowWidth,
        height: windowHeight
    )
    let window = NSWindow(
        contentRect: frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.isMovable = true
    window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]

    let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
    content.wantsLayer = true
    window.contentView = content

    let configuration = TerminalConfiguration()
        .windowPaddingX(basePadding)
        .windowPaddingY(paddingY)

    let controller = TerminalController(
        configSource: .none,
        theme: .default,
        terminalConfiguration: configuration
    )

    let observer = GridObserver()
    let terminal = AppTerminalView(frame: NSRect(
        x: 0,
        // Bottom-aligned in both arms. Under "inset" the surface starts 22 pt up
        // and the bar sits below it; under "extended" it starts at 0 and the bar
        // overlaps its last 22 pt.
        y: surfaceHeight == windowHeight ? 0 : barHeight,
        width: windowWidth,
        height: surfaceHeight
    ))
    terminal.delegate = observer
    // `.exec`, never `.inMemory`. The in-memory backend is an emulated sandbox
    // shell with no PTY at all, so its "grid" is a number the library keeps
    // rather than a size a real `SIGWINCH` would carry. Measuring it would answer
    // a question about libghostty's bookkeeping, not about the terminal.
    terminal.configuration = TerminalSurfaceOptions(
        backend: .exec,
        workingDirectory: NSHomeDirectory()
    )
    terminal.controller = controller
    content.addSubview(terminal)

    // The bar, over or beside the surface as the arm dictates. Present in every
    // arm, because a glass view above the surface is itself a compositing change
    // and leaving it out of the measurement would test a geometry the app never
    // ships.
    let bar = NSGlassEffectView(frame: NSRect(
        x: 0, y: 0, width: windowWidth, height: barHeight
    ))
    bar.style = .regular
    bar.cornerRadius = 0
    content.addSubview(bar, positioned: .above, relativeTo: terminal)

    window.orderFrontRegardless()

    // Long enough for the surface to spawn its shell, lay out, and report. The
    // first report arrives well inside this; the wait is sized for a cold
    // libghostty runtime initialisation on the first arm.
    settle(3.0)

    let result = observer.latest
    let reportCount = observer.samples.count
    if let result {
        print(String(
            format: "%-14s surface %4.0f pt  padding-y %2d  ->  %3d cols x %3d rows   (%d report(s))",
            (label as NSString).utf8String!,
            surfaceHeight,
            paddingY,
            result.columns,
            result.rows,
            reportCount
        ))
    } else {
        print("\(label): NO RESIZE REPORTED — the surface never reached the PTY")
    }

    window.orderOut(nil)
    terminal.removeFromSuperview()
    settle(0.4)
    return result
}

print("baia glass-backdrop: the grid measurement for arm 3")
print("window \(Int(windowWidth))x\(Int(windowHeight)) pt, bar \(Int(barHeight)) pt, base padding \(basePadding)")
print("")

// A. the shipped arrangement.
let inset = measure(
    label: "A inset",
    surfaceHeight: windowHeight - barHeight,
    paddingY: basePadding
)

// B. extended, uncompensated. This is what "content extends under the bar" costs
// if nothing gives the grid its inset back.
let extended = measure(
    label: "B extended",
    surfaceHeight: windowHeight,
    paddingY: basePadding
)

// C. extended, compensated by HALF the bar height.
//
// The arithmetic that is easy to get wrong, and that the first run of this probe
// did get wrong. `window-padding-y` is applied to the top edge and the bottom
// edge both, so raising it by n removes 2n points of drawable height. The bar
// costs 22 pt at one edge, so the compensation that restores the shipped row
// count is +11, not +22. The first version added the full 22 and measured 22
// rows against the shipped 23: it overshot by a row, because it had spent 44 pt
// buying back 22.
//
// Both are measured. C is the arithmetic that works; D below is the naive
// compensation, kept because "add the bar height to the padding" is the obvious
// move and the probe should show what it costs rather than leave the next reader
// to rediscover it.
let compensated = measure(
    label: "C half-comp",
    surfaceHeight: windowHeight,
    paddingY: basePadding + Int(barHeight / 2)
)

// D. the naive compensation, as a negative control.
let naive = measure(
    label: "D naive-comp",
    surfaceHeight: windowHeight,
    paddingY: basePadding + Int(barHeight)
)

print("")

guard let inset, let extended, let compensated, let naive else {
    print("FAILED: at least one arm never reported a grid size")
    exit(1)
}

var failures = 0

func check(_ passed: Bool, _ message: String) {
    print((passed ? "ok    " : "FAIL  ") + message)
    if !passed { failures += 1 }
}

// The arm's premise, stated as an assertion rather than left to the reader: if
// extending the surface did not change the grid at all, the whole compensation
// question is moot and the plan's SIGWINCH worry was unfounded.
check(
    extended.rows != inset.rows,
    "extending the surface under the bar changes the grid "
        + "(A \(inset.rows) rows vs B \(extended.rows) rows) — "
        + "this is the SIGWINCH the arm has to buy back"
)

// What arm 3 needs to be true: extending the surface under the bar and raising
// the padding by half the bar height leaves the grid exactly where it shipped.
// This is the assertion the whole (B) resolution rests on.
check(
    compensated.rows == inset.rows,
    "half-height padding compensation restores the shipped row count "
        + "(A \(inset.rows) rows vs C \(compensated.rows) rows)"
)

// The negative control. If the naive compensation happened to land on the same
// row count, the arithmetic above would be unfalsified by this run and the
// distinction between +11 and +22 would be untested rather than proven.
check(
    naive.rows != inset.rows,
    "the naive +\(Int(barHeight)) compensation does NOT restore it "
        + "(A \(inset.rows) rows vs D \(naive.rows) rows) — "
        + "padding is symmetric, so it spends twice what the bar costs"
)

// Columns must not move in any arm. `window-padding-y` reaches the vertical edges
// only, so a column change would mean the compensation had leaked onto the
// horizontal axis and the arm costs width as well as height.
check(
    inset.columns == extended.columns
        && inset.columns == compensated.columns
        && inset.columns == naive.columns,
    "columns unchanged across all four arms "
        + "(\(inset.columns) / \(extended.columns) / \(compensated.columns) / \(naive.columns))"
)

print("")
print("A inset        \(inset.columns) x \(inset.rows)")
print("B extended     \(extended.columns) x \(extended.rows)   delta \(extended.rows - inset.rows) rows")
print("C half-comp    \(compensated.columns) x \(compensated.rows)   delta \(compensated.rows - inset.rows) rows")
print("D naive-comp   \(naive.columns) x \(naive.rows)   delta \(naive.rows - inset.rows) rows")
print("")
print("`window-padding-y` is applied to the top edge AND the bottom edge, so")
print("raising it by n removes 2n points of drawable height. A \(Int(barHeight)) pt bar at one")
print("edge is bought back with +\(Int(barHeight / 2)), not +\(Int(barHeight)). Arm D is what the obvious")
print("arithmetic costs: a row, silently, on every pane.")
print("")
print("The residual cost of arm 3 is still real and is NOT zero: arm C spends")
print("\(Int(barHeight / 2)) pt of padding at the TOP that the shipped arrangement does not, so the")
print("first text row sits \(Int(barHeight / 2)) pt lower. The row COUNT is preserved, which is what")
print("closes the SIGWINCH hazard; the top inset is a visual change to weigh.")

if failures > 0 {
    print("")
    print("FAILED \(failures)")
    exit(1)
}
print("PASS")
