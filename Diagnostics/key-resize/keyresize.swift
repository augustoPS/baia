import AppKit
import PaneChrome
import WorkspaceLayout

// Headless proof that the keyboard resize cannot bring back the layout loop that
// killed the process, and that it moves the divider without tearing anything
// down. No window is ever made key, no mouse is moved, nothing is captured.
//
// `PaneSplitController` and `PaneSplitView` are NOT retyped here. `run.sh` slices
// `Sources/PaneTreeController.swift` from `/// One split node:` to the end of the
// file and compiles that text verbatim beside this one, so the probe cannot pass
// against a copy that has drifted from what ships. `WorkspaceLayout` is the real
// package binary, so `PaneTree.adjustingRatio`, `Workspace.resizeFocusedPane` and
// `PaneTree.keyboardResizeStep` are the shipping ones too.
//
// The three cases:
//   model  the model side alone, no AppKit: every ratio a held key can write is
//          one `clampedRatio(_:)` already admits, and a held key terminates.
//   starve the crash class: a window too small to seat both minimums, hammered
//          with key-repeat resizes. The assertion is the exit status.
//   push   the positive control: the divider lands where the model says, the
//          session sees it, and no view in the hierarchy is replaced.

// MARK: - leaves and host

final class LeafVC: NSViewController {
    override func loadView() {
        let view = NSView()
        view.wantsLayer = true
        self.view = view
    }
}

final class HostVC: NSViewController {
    let content: NSViewController

    init(_ content: NSViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        view.wantsLayer = true
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.topAnchor.constraint(equalTo: view.topAnchor),
            content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

// MARK: - the PaneTreeController stand-in

/// Mirrors `PaneTreeController.makeViewController(for:at:)`,
/// `resizeFocusedPane(_:)`, `equalizePanes()` and `pushRatios()`.
///
/// The real type owns `TerminalPaneController`, which needs libghostty, a Metal
/// device and a spawned shell. The three lines that matter here are the ones this
/// copies: the workspace mutation, `PaneSplitController.applyRatios(of:to:)`, and
/// the session write. `rebuild()` has no counterpart because the whole point is
/// that this path never calls it.
final class Harness {
    var workspace: Workspace
    private(set) var controllers: [SplitPath: PaneSplitController] = [:]
    private(set) var leaves: [NSView] = []
    private(set) var sessionWrites = 0
    let window: NSWindow
    let root: NSViewController

    init(tree: PaneTree, focused: PaneID, size: NSSize) {
        workspace = Workspace(
            tabs: [Tab(id: UUID(), tree: tree, focusedPane: focused, zoomedPane: nil)],
            focusedTabIndex: 0
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        root = Harness.make(tree, at: SplitPath(), into: &controllers, leaves: &leaves)
        window.contentViewController = HostVC(root)
        window.setContentSize(size)
        settle()
    }

    private static func make(
        _ node: PaneTree,
        at path: SplitPath,
        into controllers: inout [SplitPath: PaneSplitController],
        leaves: inout [NSView]
    ) -> NSViewController {
        switch node {
        case .leaf:
            let leaf = LeafVC()
            leaves.append(leaf.view)
            return leaf
        case let .split(axis, ratio, first, second):
            let split = PaneSplitController(axis: axis, ratio: ratio, path: path, theme: .darkPastel)
            split.setChildren(
                first: make(first, at: path.appending(0), into: &controllers, leaves: &leaves),
                second: make(second, at: path.appending(1), into: &controllers, leaves: &leaves)
            )
            controllers[path] = split
            return split
        }
    }

    /// `PaneTreeController.resizeFocusedPane(_:)`, line for line.
    func resizeFocusedPane(_ direction: FocusDirection) {
        guard workspace.resizeFocusedPane(direction, by: PaneTree.keyboardResizeStep) else { return }
        pushRatios()
    }

    /// A click into another pane, which is all the keys need from focus.
    func focus(_ pane: PaneID) {
        _ = workspace.focusPane(pane)
    }

    /// `PaneTreeController.equalizePanes()`, line for line.
    func equalizePanes() {
        guard workspace.equalizeFocusedTab() else { return }
        pushRatios()
    }

    private func pushRatios() {
        guard let tree = workspace.focusedTab?.tree else { return }
        PaneSplitController.applyRatios(of: tree, to: root)
        sessionWrites += 1
    }

    /// One press worth of run loop. A held key does not suspend AppKit, so the
    /// layout passes that used to never converge get their chance between presses
    /// here exactly as they would on a real keyboard.
    func tick() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.002))
    }

    /// A full AppKit-scheduled layout pass.
    func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func modelRatio(at path: SplitPath) -> Double? {
        workspace.focusedTab?.tree.ratio(at: path)
    }
}

// MARK: - measurement, in the same expression the controller uses

@MainActor func position(_ controller: PaneSplitController) -> CGFloat {
    guard let first = controller.splitViewItems.first?.viewController.view else { return -1 }
    return controller.splitView.isVertical ? first.frame.width : first.frame.height
}

@MainActor func thickness(_ controller: PaneSplitController) -> CGFloat {
    let split = controller.splitView
    return split.isVertical ? split.bounds.width : split.bounds.height
}

// MARK: - failure

var failures = 0

func check(_ passed: Bool, _ what: String) {
    if passed {
        print("  ok    \(what)")
    } else {
        failures += 1
        print("  FAIL  \(what)")
    }
}

// MARK: - trees

/// Reproducible, so a failure names a seed rather than a mood.
struct Seeded: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func randomTree(depth: Int, panes: inout [PaneID], using rng: inout Seeded) -> PaneTree {
    if depth == 0 || Int.random(in: 0 ... 4, using: &rng) == 0 {
        let id = PaneID()
        panes.append(id)
        return .leaf(id)
    }
    return .split(
        axis: Bool.random(using: &rng) ? .horizontal : .vertical,
        // Only values the model's own constructors can produce. Everything that
        // writes a ratio clamps, so a real tree never holds anything else, and
        // seeding one that does would be testing the seed rather than the keys.
        ratio: Double.random(in: 0.05 ... 0.95, using: &rng),
        first: randomTree(depth: depth - 1, panes: &panes, using: &rng),
        second: randomTree(depth: depth - 1, panes: &panes, using: &rng)
    )
}

/// Every ratio stored anywhere in the tree, in no particular order.
func storedRatios(_ tree: PaneTree) -> [Double] {
    guard case let .split(_, ratio, first, second) = tree else { return [] }
    return [ratio] + storedRatios(first) + storedRatios(second)
}

/// Three splits on one spine nesting into the second child, which is the shape
/// repeated ⌘D produces and the one that starves first.
func spine(axis: SplitAxis, panes: [PaneID]) -> PaneTree {
    .split(
        axis: axis,
        ratio: 0.5,
        first: .leaf(panes[0]),
        second: .split(
            axis: axis,
            ratio: 0.5,
            first: .leaf(panes[1]),
            second: .split(axis: axis, ratio: 0.5, first: .leaf(panes[2]), second: .leaf(panes[3]))
        )
    )
}

let app = NSApplication.shared

let directions: [FocusDirection] = [.left, .right, .up, .down]

@main
enum Probe {
    @MainActor static func main() {
        app.setActivationPolicy(.accessory)
        switch CommandLine.arguments[1] {
        case "model": model()
        case "starve": starve()
        case "push": push()
        default: print("unknown case"); exit(2)
        }
        print(failures == 0 ? "PASS" : "FAILED \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - the model side

    /// The claim the whole crash class rests on: a keyboard resize can write no
    /// ratio a mouse drag could not.
    ///
    /// `reachablePosition(in:)` guards the view side, but it only ever sees what
    /// the model hands it, and a held key writes many ratios a second where a
    /// mouse writes one per gesture. So this hammers random trees with random keys
    /// and asserts that every stored ratio anywhere in the tree, after every
    /// press, is a value `clampedRatio(_:)` admits. If that holds, the set of
    /// arrangements the keyboard can reach is a subset of the ones the drag path
    /// already survives, which the pane-resize probe covers.
    @MainActor static func model() {
        print("=== every ratio a held key can write is one the clamp admits ===")

        var worst = (low: 1.0, high: 0.0)
        var presses = 0
        for seed in 0 ..< 400 {
            var rng = Seeded(state: UInt64(seed) &* 2_654_435_761 &+ 12345)
            var panes: [PaneID] = []
            let tree = randomTree(depth: 4, panes: &panes, using: &rng)
            guard let focused = panes.randomElement(using: &rng) else { continue }
            var workspace = Workspace(
                tabs: [Tab(id: UUID(), tree: tree, focusedPane: focused, zoomedPane: nil)],
                focusedTabIndex: 0
            )

            for step in 0 ..< 300 {
                // Focus moves the way it does in use: the user grows a pane, then
                // walks to another one and grows that.
                if step % 25 == 0, let next = panes.randomElement(using: &rng) {
                    _ = workspace.focusPane(next)
                }
                if step % 60 == 59 {
                    _ = workspace.equalizeFocusedTab()
                } else {
                    _ = workspace.resizeFocusedPane(
                        directions.randomElement(using: &rng)!,
                        by: PaneTree.keyboardResizeStep
                    )
                }
                presses += 1

                guard let current = workspace.focusedTab?.tree else { continue }
                for ratio in storedRatios(current) {
                    worst.low = min(worst.low, ratio)
                    worst.high = max(worst.high, ratio)
                    if ratio != PaneTree.clampedRatio(ratio) {
                        failures += 1
                        print("  FAIL  seed \(seed) step \(step) stored \(ratio)")
                        return
                    }
                }
            }
        }
        print(String(format: "  %d presses over 400 trees, ratios stayed in [%.4f, %.4f]",
                     presses, worst.low, worst.high))
        check(worst.low >= 0.05 && worst.high <= 0.95, "no ratio left the clamp range")
        check(worst.low <= 0.05001, "the low stop was actually reached, so this was not vacuous")
        check(worst.high >= 0.94999, "the high stop was actually reached")

        // A held key has to stop, and stop *on* the stop. A walk that converged
        // asymptotically would keep reporting a change forever, and every one of
        // those is a session write and a divider push per keystroke.
        print("=== a held key terminates ===")
        let a = PaneID()
        let b = PaneID()
        var tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        var held = 0
        while held < 1000,
              let grown = tree.adjustingRatio(forPane: b, direction: .left, by: PaneTree.keyboardResizeStep) {
            tree = grown
            held += 1
        }
        let expected = Int(((0.5 - PaneTree.clampedRatio(0)) / PaneTree.keyboardResizeStep).rounded())
        print("  \(held) presses to cross from the middle, arithmetic says \(expected)")
        check(held <= expected + 1, "it stopped in the number of presses the step implies")
        check(tree.ratio(at: SplitPath()) == PaneTree.clampedRatio(0), "it stopped exactly on the stop")

        // And the refusal is a refusal, not a tree that is equal but freshly
        // allocated: the caller reads nil to skip the session write and the push.
        check(
            tree.adjustingRatio(forPane: b, direction: .left, by: PaneTree.keyboardResizeStep) == nil,
            "pressing again at the stop reports nothing to do"
        )

        // A ratio from a session file written before the clamp existed is
        // normalised by the first key rather than carried forward.
        print("=== a bad stored ratio is normalised, not propagated ===")
        for stored in [-3.0, 0.0, 0.99, 9.0, Double.nan] {
            let c = PaneID()
            let d = PaneID()
            let decoded = PaneTree.split(axis: .horizontal, ratio: stored, first: .leaf(c), second: .leaf(d))
            let grown = decoded.adjustingRatio(forPane: c, direction: .right, by: PaneTree.keyboardResizeStep)
            let after = grown.flatMap { $0.ratio(at: SplitPath()) } ?? -1
            check(after == PaneTree.clampedRatio(after), "stored \(stored) came back as \(after)")
        }
    }

    // MARK: - the crash class

    /// A window too small to seat both minimums, hammered with key repeat.
    ///
    /// This is the shape that killed the process: `NSSplitViewItem.minimumThickness`
    /// refuses any position inside its margin, so once `thickness * ratio` lands
    /// there, `setPosition` never arrives, `current` never equals `target`, and
    /// every layout pass asks again. A nested split is re-laid out by its parent
    /// on every pass anyway, so it never converges, AppKit raises
    /// `NSGenericException` about the update constraints pass count, and the
    /// process aborts. A keyboard resize writes ratios far faster than a mouse
    /// can, so it gets its own case.
    ///
    /// Nothing here is asserted by comparing numbers. The proof is that the
    /// process is still running to print, so `run.sh` runs this under `set -e`.
    @MainActor static func starve() {
        let stop = PaneSplitController.minimumPaneThickness
        for axis in [SplitAxis.vertical, SplitAxis.horizontal] {
            let panes = [PaneID(), PaneID(), PaneID(), PaneID()]
            // Focus on the deepest pane, so the keys move the innermost divider,
            // which is the one with the least room and the one whose parent
            // re-lays it out every pass.
            let harness = Harness(
                tree: spine(axis: axis, panes: panes),
                focused: panes[3],
                size: NSSize(width: 1200, height: 800)
            )
            let label = axis == .horizontal ? "side by side" : "stacked"
            print("=== \(label): key repeat into a window that keeps shrinking ===")

            // Small enough that three panes on one spine cannot all have their
            // 96pt minimum: 96*3 + 2 dividers is 290, and the innermost split is
            // handed a quarter of the window at best.
            let sizes: [NSSize] = axis == .horizontal
                ? [NSSize(width: 1200, height: 800), NSSize(width: 600, height: 800),
                   NSSize(width: 380, height: 800), NSSize(width: 240, height: 800)]
                : [NSSize(width: 1200, height: 800), NSSize(width: 1200, height: 500),
                   NSSize(width: 1200, height: 340), NSSize(width: 1200, height: 220)]

            for size in sizes {
                harness.window.setContentSize(size)
                harness.settle()

                // Held, not alternated. Four presses of left and four of right
                // cancel and leave every divider near the middle, which is the
                // one place this cannot crash: the loop needs a ratio the
                // minimum refuses. So each direction is held for 40, four past
                // the 36 it takes to cross from one stop to the other, which
                // parks the divider on the far stop and keeps pressing into it.
                // Equalize goes in between the holds rather than last, so the
                // burst ends at an extreme rather than tidying up after itself.
                //
                // The pane is switched between the two sides of the innermost
                // divider rather than the direction being flipped: the pane below
                // that divider can only push it up and the pane above it can only
                // push it down, so one pane alone reaches one stop and never the
                // other.
                let towardsSecond: FocusDirection = axis == .vertical ? .up : .left
                let towardsFirst: FocusDirection = axis == .vertical ? .down : .right
                var extremes = (low: 1.0, high: 0.0)
                var presses = 0
                for round in 0 ..< 2 {
                    if round == 1 { harness.equalizePanes() }
                    for (pane, direction) in [(panes[3], towardsSecond), (panes[2], towardsFirst)] {
                        harness.focus(pane)
                        for _ in 0 ..< 40 {
                            harness.resizeFocusedPane(direction)
                            harness.tick()
                            presses += 1
                            guard let ratio = harness.modelRatio(at: SplitPath([1, 1])) else { continue }
                            extremes.low = min(extremes.low, ratio)
                            extremes.high = max(extremes.high, ratio)
                        }
                    }
                }
                harness.settle()
                let inner = harness.controllers[SplitPath([1, 1])]
                print(String(
                    format: "  %.0fx%.0f  survived %d presses  innermost divider %.1f of %.1f (the stop is %.0f)  model %.4f, and was driven to [%.4f, %.4f]",
                    size.width, size.height, presses,
                    inner.map { position($0) } ?? -1, inner.map { thickness($0) } ?? -1, stop,
                    harness.modelRatio(at: SplitPath([1, 1])) ?? -1, extremes.low, extremes.high
                ))
                // Vacuous otherwise: a burst that left every divider near the
                // middle never asks for a position the minimum refuses, and
                // surviving it proves nothing at all.
                check(
                    extremes.low <= 0.05001 && extremes.high >= 0.94999,
                    String(format: "%.0fx%.0f pinned the innermost divider on both stops",
                           size.width, size.height)
                )
            }

            // Every divider ends inside the band the minimum allows, which is the
            // condition whose violation *is* the crash: a position outside it is
            // refused, `current` never reaches `target`, and the layout pass asks
            // again forever.
            //
            // Asserted against the reachable position rather than against the
            // model's fraction, because the two legitimately differ. The tree
            // keeps what the keys asked for so that widening the window gives the
            // arrangement back, while the drawn position is held inside the band;
            // a split too small to seat both minimums has no legal position at
            // all and is left where it is.
            harness.window.setContentSize(NSSize(width: 1200, height: 800))
            harness.settle()
            for path in [SplitPath(), SplitPath([1]), SplitPath([1, 1])] {
                guard let controller = harness.controllers[path],
                      let ratio = harness.modelRatio(at: path) else { continue }
                let span = thickness(controller)
                let highest = span - stop - controller.splitView.dividerThickness
                guard highest >= stop else {
                    print(String(format: "  skip  %@ is %.1f thick, too small to seat two %.0fpt panes",
                                 path.indices.isEmpty ? "[]" : "\(path.indices)", span, stop))
                    continue
                }
                let target = min(max(span * ratio, stop), highest)
                check(
                    abs(position(controller) - target) < 1,
                    String(format: "%@ sits at %.1f, the reachable position for %.4f of %.1f in [%.0f, %.1f]",
                           path.indices.isEmpty ? "[]" : "\(path.indices)",
                           position(controller), ratio, span, stop, highest)
                )
            }
        }
    }

    // MARK: - the positive control

    /// The divider moves, the session sees it, and nothing is torn down.
    ///
    /// Without this the starve case passes vacuously: a resize that did nothing
    /// at all would also fail to crash.
    @MainActor static func push() {
        let panes = [PaneID(), PaneID(), PaneID(), PaneID()]
        let harness = Harness(
            tree: spine(axis: .horizontal, panes: panes),
            focused: panes[1],
            size: NSSize(width: 1400, height: 900)
        )
        guard let inner = harness.controllers[SplitPath([1])] else { return }
        print("=== one press moves the divider the pane touches, and only that one ===")

        let before = position(inner)
        let rootBefore = harness.controllers[SplitPath()].map { position($0) } ?? -1
        let identities = harness.leaves.map { ObjectIdentifier($0) }
        let responder = harness.window.firstResponder

        harness.resizeFocusedPane(.right)
        harness.settle()

        let after = position(inner)
        let expected = thickness(inner) * (0.5 + PaneTree.keyboardResizeStep)
        print(String(format: "  divider %.1f -> %.1f, the model's %.4f of %.1f is %.1f",
                     before, after, harness.modelRatio(at: SplitPath([1])) ?? -1,
                     thickness(inner), expected))
        check(abs(after - expected) < 1, "the divider landed where the model says")
        check(harness.modelRatio(at: SplitPath([1])) == 0.5 + PaneTree.keyboardResizeStep,
              "the session snapshot carries the new ratio")
        check(abs((harness.controllers[SplitPath()].map { position($0) } ?? -1) - rootBefore) < 0.5,
              "the divider the pane does not touch did not move")

        // The constraint this whole path exists for. `rebuild()` would drop every
        // child view and put a fresh set in, which leaves the window with no first
        // responder: `AppTerminalView.performKeyEquivalent` opens by checking that
        // it is one, so a pane that lost it answers no ghostty binding at all,
        // with nothing on screen to explain it. 200 presses is a held key.
        print("=== a held key replaces no view and moves no first responder ===")
        for press in 0 ..< 200 {
            harness.resizeFocusedPane(directions[press % 4])
            harness.tick()
        }
        harness.settle()
        check(harness.leaves.map { ObjectIdentifier($0) } == identities,
              "the same leaf views are still there after 200 presses")
        check(harness.leaves.allSatisfy { $0.window === harness.window },
              "every leaf view is still in the window")
        check(harness.window.firstResponder === responder, "the first responder never moved")
        check(harness.sessionWrites > 0, "presses actually reached the model")

        // Equalize puts every divider back at once, which is the one command that
        // has to reach more than a single split.
        print("=== equalize reaches every divider ===")
        harness.equalizePanes()
        harness.settle()
        for path in [SplitPath(), SplitPath([1]), SplitPath([1, 1])] {
            guard let controller = harness.controllers[path] else { continue }
            let drawn = Double(position(controller) / thickness(controller))
            check(harness.modelRatio(at: path) == 0.5 && abs(drawn - 0.5) < 0.01,
                  String(format: "%@ is back at the middle, drawn %.4f",
                         path.indices.isEmpty ? "[]" : "\(path.indices)", drawn))
        }
    }
}
