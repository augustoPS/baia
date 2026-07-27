import AppKit
import PaneChrome
import WorkspaceLayout

// Headless proof that a finished divider drag survives the layout pass it
// triggers. No window is ever made key, no mouse is moved, nothing is captured.
//
// The two classes under test are NOT retyped here. `run.sh` slices
// `Sources/PaneTreeController.swift` from `/// One split node:` to the end of the
// file and compiles that text verbatim beside this one, so the probe cannot pass
// against a copy that has drifted from what ships.
//
// What this exercises for real:
//   B1  the whole of `WorkspaceLayout` (the real package binary)
//   B2  `PaneSplitView.mouseDown` -> `onDragFinished`, in the `drag` mechanism
//   B3  `PaneSplitController.recordDrag`, `applyRatio`, the `isDragging` guard
// What it mirrors rather than runs:
//   B4  `PaneTreeController.makeViewController` / `recordRatio`. That type owns
//       `TerminalPaneController`, which needs libghostty, a Metal device and a
//       spawned shell. `Harness` below is a line-for-line stand-in for the two
//       methods that matter; `renderedTree` has no counterpart because nothing
//       here rebuilds.

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

// MARK: - the B4 stand-in

/// Mirrors `PaneTreeController.makeViewController(for:at:)` and `recordRatio`.
final class Harness {
    var workspace: Workspace
    private(set) var controllers: [SplitPath: PaneSplitController] = [:]
    private(set) var sessionWrites = 0
    let window: NSWindow

    init(tree: PaneTree, panes: [PaneID], writeBack: Bool, size: NSSize = NSSize(width: 1400, height: 900)) {
        workspace = Workspace(
            tabs: [Tab(id: UUID(), tree: tree, focusedPane: panes[0], zoomedPane: nil)],
            focusedTabIndex: 0
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let root = make(tree, at: SplitPath())
        window.contentViewController = HostVC(root)
        window.setContentSize(size)
        if !writeBack {
            // The pre-fix code path exactly: a ratio nothing can ever write to,
            // enforced on every layout pass. `loadView` is what installs the
            // callback, so the view is forced first and the callback cleared.
            for controller in controllers.values {
                _ = controller.view
                (controller.splitView as? PaneSplitView)?.onDragFinished = nil
            }
        }
        settle()
    }

    private func make(_ node: PaneTree, at path: SplitPath) -> NSViewController {
        switch node {
        case .leaf:
            return LeafVC()
        case let .split(axis, ratio, first, second):
            let split = PaneSplitController(axis: axis, ratio: ratio, path: path, theme: .darkPastel)
            split.onRatioChange = { [weak self] path, ratio in self?.recordRatio(at: path, ratio) }
            split.setChildren(
                first: make(first, at: path.appending(0)),
                second: make(second, at: path.appending(1))
            )
            controllers[path] = split
            return split
        }
    }

    private func recordRatio(at path: SplitPath, _ ratio: Double) {
        guard workspace.setRatio(at: path, to: ratio) else { return }
        sessionWrites += 1
    }

    /// One AppKit-scheduled layout pass, which is the thing that used to undo
    /// every drag.
    func settle() {
        drain()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        drain()
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

@MainActor func dividerGap(_ split: NSSplitView) -> NSRect {
    let first = split.subviews[0].frame
    let second = split.subviews[1].frame
    if split.isVertical {
        return NSRect(x: first.maxX, y: 0, width: max(second.minX - first.maxX, 1), height: split.bounds.height)
    }
    return NSRect(x: 0, y: first.maxY, width: split.bounds.width, height: max(second.minY - first.maxY, 1))
}

// MARK: - event plumbing

let app = NSApplication.shared

var stamp = ProcessInfo.processInfo.systemUptime

@MainActor func mouse(_ type: NSEvent.EventType, _ window: NSWindow, _ point: NSPoint) -> NSEvent {
    stamp += 0.016
    return NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: stamp,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: Int.random(in: 1 ... 1_000_000),
        clickCount: 1,
        pressure: type == .leftMouseUp ? 0 : 1
    )!
}

@MainActor func drain() {
    while let event = app.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) { _ = event }
}

/// A real drag: posted events consumed by `NSSplitView`'s own tracking loop,
/// entered through `PaneSplitView.mouseDown`. Exercises every line of B2.
@MainActor func synthesizedDrag(_ harness: Harness, _ controller: PaneSplitController, to target: CGFloat) {
    let split = controller.splitView
    let gap = dividerGap(split)
    let startLocal = split.isVertical
        ? NSPoint(x: gap.midX, y: split.bounds.midY)
        : NSPoint(x: split.bounds.midX, y: gap.midY)
    let start = split.convert(startLocal, to: nil)
    let shrink = position(controller) - target
    // Window coordinates are bottom-left while the split view is flipped, so a
    // stacked divider moves up the window to shrink the pane above it.
    let delta = split.isVertical ? NSPoint(x: -shrink, y: 0) : NSPoint(x: 0, y: shrink)

    drain()
    for step in 1 ... 8 {
        let fraction = CGFloat(step) / 8
        app.postEvent(
            mouse(.leftMouseDragged, harness.window, NSPoint(x: start.x + delta.x * fraction, y: start.y + delta.y * fraction)),
            atStart: false
        )
    }
    app.postEvent(mouse(.leftMouseUp, harness.window, NSPoint(x: start.x + delta.x, y: start.y + delta.y)), atStart: false)
    let hit = harness.window.contentView?.hitTest(start)
    hit?.mouseDown(with: mouse(.leftMouseDown, harness.window, start))
    drain()
}

/// The same landing point without a mouse: move the divider the way the tracking
/// loop would have, between the two callbacks `mouseDown` raises around it.
///
/// Both ends, in order. The controller notes where the divider was on the way in,
/// because whether it moved is the only thing that separates a drag from a click,
/// and raising only the mouse-up half would test a gesture that cannot happen.
@MainActor func seamDrag(_ controller: PaneSplitController, to target: CGFloat) {
    let split = controller.splitView as? PaneSplitView
    split?.onDragWillBegin?()
    controller.splitView.setPosition(target, ofDividerAt: 0)
    split?.onDragFinished?()
}

/// A click: `mouseDown` with nothing queued behind it, straight into the view
/// AppKit's own hit testing finds.
@MainActor func synthesizedClick(_ harness: Harness, _ controller: PaneSplitController) {
    let split = controller.splitView
    let gap = dividerGap(split)
    let local = split.isVertical
        ? NSPoint(x: gap.midX, y: split.bounds.midY)
        : NSPoint(x: split.bounds.midX, y: gap.midY)
    let point = split.convert(local, to: nil)
    drain()
    // The mouse-up goes in first and nothing else does. `super.mouseDown` runs its
    // own tracking loop and blocks until it sees one, so a queue with no up event
    // in it is not a click, it is a hang.
    app.postEvent(mouse(.leftMouseUp, harness.window, point), atStart: false)
    harness.window.contentView?.hitTest(point)?.mouseDown(with: mouse(.leftMouseDown, harness.window, point))
    drain()
}

// MARK: - the run

func makeTree(axis: SplitAxis, panes: [PaneID]) -> PaneTree {
    // Three splits on one spine, nesting into the second child, which is the
    // shape repeated ⌘D produces.
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

@main
enum Probe {
    @MainActor static func main() {
        app.setActivationPolicy(.accessory)
        switch CommandLine.arguments[1] {
        case "starve": starve()
        case "click": click()
        default: run()
        }
    }

    /// A stored ratio the split view will never grant must not be chased.
    ///
    /// `NSSplitViewItem.minimumThickness` refuses any position inside its margin,
    /// so once a window is small enough that `thickness * ratio` lands there, a
    /// `setPosition` asking for it never arrives, `current` never equals `target`,
    /// and the next layout pass asks again. Each refused request dirties layout,
    /// and a nested split is re-laid out by its parent every pass anyway, so it
    /// never converges: AppKit raises `NSGenericException` about the update
    /// constraints pass count and the process aborts. Not a divider in the wrong
    /// place, a dead app, reachable by dragging a nested divider near its stop
    /// and then making the window smaller.
    ///
    /// Nothing is asserted by comparing numbers here. The proof is that the
    /// process is still running to print, so `run.sh` runs this under `set -e`.
    @MainActor static func starve() {
        let panes = [PaneID(), PaneID(), PaneID()]
        let stop = PaneSplitController.minimumPaneThickness
        // Three stacked panes, which is what two presses of the split key make.
        let tree = PaneTree.split(
            axis: .vertical, ratio: 0.5, first: .leaf(panes[0]),
            second: .split(axis: .vertical, ratio: 0.5, first: .leaf(panes[1]), second: .leaf(panes[2]))
        )
        let harness = Harness(
            tree: tree, panes: panes, writeBack: true, size: NSSize(width: 1200, height: 800)
        )
        guard let nested = harness.controllers[SplitPath([1])] else { return }

        print("=== a nested divider dragged to its stop, then a window that keeps shrinking ===")
        synthesizedDrag(harness, nested, to: stop)
        harness.settle()
        let dragged = harness.modelRatio(at: SplitPath([1])) ?? -1
        print(String(
            format: "drag to the %.0fpt stop: %.1f of %.1f, model %.4f, writes %d",
            stop, position(nested), thickness(nested), dragged, harness.sessionWrites
        ))

        for height in [640.0, 520.0, 400.0] as [CGFloat] {
            harness.window.setContentSize(NSSize(width: 1200, height: height))
            harness.settle()
            print(String(
                format: "  1200x%.0f  survived  divider %.1f of %.1f  model still %.4f",
                height, position(nested), thickness(nested),
                harness.modelRatio(at: SplitPath([1])) ?? -1
            ))
        }

        // The other half of clamping the applied position rather than the stored
        // ratio: what the user asked for is still in the tree, so growing the
        // window back gives the arrangement back instead of a value bent to fit
        // the smallest the window ever got.
        harness.window.setContentSize(NSSize(width: 1200, height: 800))
        harness.settle()
        let back = Double(position(nested) / thickness(nested))
        print(String(
            format: "back at 1200x800: fraction %.4f against a dragged %.4f  %@",
            back, dragged, abs(back - dragged) < 0.01 ? "the arrangement came back" : "LOST IT"
        ))

        // The relaunch case, which is the same loop with no drag in it and no way
        // out: the fraction arrives from session.json, the window comes back at
        // the frame it was saved at, and the abort lands during construction
        // before anything is on screen. 0.152 is 96 of the 630pt content height
        // of a real session file.
        print("=== the same fraction arriving from a session file, no drag at all ===")
        let restored = [PaneID(), PaneID(), PaneID()]
        let saved = PaneTree.split(
            axis: .vertical, ratio: 0.5, first: .leaf(restored[0]),
            second: .split(axis: .vertical, ratio: 0.152, first: .leaf(restored[1]), second: .leaf(restored[2]))
        )
        for height in [800.0, 600.0, 500.0] as [CGFloat] {
            let relaunch = Harness(
                tree: saved, panes: restored, writeBack: true, size: NSSize(width: 1200, height: height)
            )
            relaunch.settle()
            guard let inner = relaunch.controllers[SplitPath([1])] else { continue }
            print(String(
                format: "  restored 0.152 into 1200x%.0f  survived  divider %.1f of %.1f",
                height, position(inner), thickness(inner)
            ))
        }
    }

    /// A click on a divider is not a resize.
    ///
    /// Whenever the minimum holds the divider off the stored ratio, and any
    /// window shrunk after a drag is in that state, the measured fraction and the
    /// stored one differ permanently. A mouse-up test written against the stored
    /// ratio therefore fires on a bare `mouseDown`, and one click writes the
    /// constraint-clamped position into the tree and the session file. The
    /// arrangement is gone, and re-widening the window cannot bring it back
    /// because the number it was made of has been overwritten.
    @MainActor static func click() {
        let panes = [PaneID(), PaneID()]
        let harness = Harness(
            tree: .split(axis: .horizontal, ratio: 0.2, first: .leaf(panes[0]), second: .leaf(panes[1])),
            panes: panes, writeBack: true, size: NSSize(width: 1400, height: 600)
        )
        guard let root = harness.controllers[SplitPath()] else { return }

        print("=== one click, no drag, on a divider the minimum has parked ===")
        harness.window.setContentSize(NSSize(width: 220, height: 600))
        harness.settle()
        print(String(
            format: "narrow window: divider %.1f of %.1f (0.2 would be %.1f, the stop is %.0f), model %.4f, writes %d",
            position(root), thickness(root), thickness(root) * 0.2,
            PaneSplitController.minimumPaneThickness,
            harness.modelRatio(at: SplitPath()) ?? -1, harness.sessionWrites
        ))

        synthesizedClick(harness, root)
        harness.settle()
        let after = harness.modelRatio(at: SplitPath()) ?? -1
        print(String(
            format: "after the click: divider %.1f, model %.4f, writes %d  %@",
            position(root), after, harness.sessionWrites,
            abs(after - 0.2) < 0.0001 && harness.sessionWrites == 0 ? "nothing was written" : "THE CLICK WROTE"
        ))

        harness.window.setContentSize(NSSize(width: 1400, height: 600))
        harness.settle()
        print(String(
            format: "re-widened: divider %.1f of %.1f, where 0.2 is %.1f  %@",
            position(root), thickness(root), thickness(root) * 0.2,
            abs(position(root) - thickness(root) * 0.2) < 1 ? "the arrangement came back" : "LOST IT"
        ))
    }

    @MainActor static func run() {
    let arguments = CommandLine.arguments

    let axis: SplitAxis = arguments[1] == "stacked" ? .vertical : .horizontal
    let writeBack = arguments[2] == "fixed"
    let mechanism = arguments.count > 3 ? arguments[3] : "drag"

    let panes = [PaneID(), PaneID(), PaneID(), PaneID()]
    let harness = Harness(tree: makeTree(axis: axis, panes: panes), panes: panes, writeBack: writeBack)

    let label = axis == .horizontal ? "side by side" : "stacked"
    print("=== \(label), \(writeBack ? "with write-back (fixed)" : "no write-back (pre-fix)"), \(mechanism) ===")

    let depths: [(String, SplitPath)] = [
        ("depth 0 root ", SplitPath()),
        ("depth 1      ", SplitPath([1])),
        ("depth 2      ", SplitPath([1, 1])),
    ]

    for (name, path) in depths {
        guard let controller = harness.controllers[path] else { continue }
        let span = thickness(controller)
        let before = position(controller)
        let target = (span * 0.3).rounded()

        if mechanism == "drag" {
            synthesizedDrag(harness, controller, to: target)
        } else {
            seamDrag(controller, to: target)
        }
        let dropped = position(controller)
        harness.settle()
        let after = position(controller)

        let model = harness.modelRatio(at: path).map { String(format: "%.4f", $0) } ?? "nil"
        print(String(
            format: "%@ thickness %7.1f  before %7.1f  target %7.1f  at mouse-up %7.1f  after layout %7.1f  model %@  (half would be %7.1f)",
            name, span, before, target, dropped, after, model, span * 0.5
        ))
    }

    print("session writes: \(harness.sessionWrites)")

    // The half the "the root works" story hides: a window resize has to keep the
    // fraction, not restore 0.5.
    let fractions = depths.compactMap { _, path -> (SplitPath, Double)? in
        guard let controller = harness.controllers[path], thickness(controller) > 0 else { return nil }
        return (path, Double(position(controller) / thickness(controller)))
    }
    harness.window.setContentSize(NSSize(width: 1300, height: 800))
    harness.settle()
    for (path, fraction) in fractions {
        guard let controller = harness.controllers[path] else { continue }
        let now = Double(position(controller) / thickness(controller))
        print(String(
            format: "resize -100pt  path %@  fraction %.4f -> %.4f  %@",
            path.indices.isEmpty ? "[]" : "\(path.indices)", fraction, now,
            abs(now - fraction) < 0.01 ? "held" : "MOVED"
        ))
    }
    }
}
