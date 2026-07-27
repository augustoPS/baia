import AppKit
import PaneChrome
import WorkspaceLayout

// Headless proof that a theme change repaints the dividers that are already on
// screen, without tearing the hierarchy down. No window is ever made key and
// nothing is captured.
//
// The class under test is NOT retyped here. `run.sh` slices
// `Sources/PaneTreeController.swift` from `/// One split node:` to the end of the
// file and compiles that text verbatim beside this one, so the probe cannot pass
// against a copy that has drifted from what ships.
//
// What this exercises for real:
//   `PaneSplitController.applyTheme(_:to:)`, the whole walk `refreshTheme()` runs
//   `PaneSplitController.theme`'s `didSet`, and `PaneSplitView.paneTheme`'s
//   `PaneSplitView.dividerColor`, which is the value `super.drawDivider(in:)`
//   re-reads on every draw
// What it mirrors rather than runs:
//   `PaneTreeController.refreshTheme()`'s one-line loop over `children`, and
//   `rebuild()`. That type owns `TerminalPaneController`, which needs libghostty,
//   a Metal device and a spawned shell, so the leaves here are plain views.
//
// The pixel is not asserted. `bitmapImageRepForCachingDisplay` did not capture
// the one-point divider fill in two separate attempts during the investigation
// that produced this fix. What is asserted is the colour the draw call reads and
// the fact that nothing was reparented to get it there. The last step, that the
// line on screen is that colour, cannot be proven without looking.

// MARK: - leaves and host

/// A stand-in for `TerminalPaneController`. Its `view` is the object whose
/// identity the reparenting assertions are made against: in the app that view
/// hosts a live ghostty surface, and moving it to a new parent resizes the grid
/// and sends `SIGWINCH` to whatever is running in it.
final class LeafVC: NSViewController {
    let name: String

    init(_ name: String) {
        self.name = name
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func loadView() {
        let view = NSView()
        view.wantsLayer = true
        self.view = view
    }
}

final class HostVC: NSViewController {
    var content: NSViewController?

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        view.wantsLayer = true
        self.view = view
    }

    func install(_ controller: NSViewController) {
        content = controller
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// `PaneTreeController.rebuild()`'s teardown, verbatim in shape: every child
    /// removed from the view hierarchy and from the controller, then a fresh
    /// hierarchy built over the same leaf controllers.
    func teardown() {
        for child in children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        content = nil
    }
}

// MARK: - the hierarchy

/// Mirrors `PaneTreeController.makeViewController(for:at:)`, minus the ratio
/// write-back, which the pane-resize probe next door already covers.
final class Harness {
    let window: NSWindow
    let host = HostVC()
    private(set) var splits: [SplitPath: PaneSplitController] = [:]
    private(set) var leaves: [PaneID: LeafVC] = [:]
    let tree: PaneTree
    let paneNames: [PaneID: String]

    init(tree: PaneTree, paneNames: [PaneID: String], theme: PaneTheme) {
        self.tree = tree
        self.paneNames = paneNames
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        build(theme: theme)
    }

    /// Builds a fresh split hierarchy over the existing leaf controllers, which is
    /// what `rebuild()` does: split containers are cheap and are recreated
    /// wholesale, a pane controller never is.
    func build(theme: PaneTheme) {
        splits.removeAll()
        host.install(make(tree, at: SplitPath(), theme: theme))
        window.setContentSize(NSSize(width: 1400, height: 900))
        settle()
    }

    private func make(_ node: PaneTree, at path: SplitPath, theme: PaneTheme) -> NSViewController {
        switch node {
        case let .leaf(id):
            if let existing = leaves[id] { return existing }
            let leaf = LeafVC(paneNames[id] ?? "?")
            leaves[id] = leaf
            return leaf
        case let .split(axis, ratio, first, second):
            let split = PaneSplitController(axis: axis, ratio: ratio, path: path, theme: theme)
            split.setChildren(
                first: make(first, at: path.appending(0), theme: theme),
                second: make(second, at: path.appending(1), theme: theme)
            )
            splits[path] = split
            return split
        }
    }

    func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    /// `PaneTreeController.refreshTheme()`, whose whole body is this loop.
    func refreshTheme(_ theme: PaneTheme) {
        for child in host.children { PaneSplitController.applyTheme(theme, to: child) }
    }
}

// MARK: - what a state of the hierarchy looks like

struct Reading {
    var dividers: [String: String] = [:]
    var leafViews: [String: ObjectIdentifier] = [:]
    var leafParents: [String: ObjectIdentifier] = [:]
    var splitViews: [String: ObjectIdentifier] = [:]
}

@MainActor func hex(_ colour: NSColor) -> String {
    guard let srgb = colour.usingColorSpace(.sRGB) else { return "??????" }
    return String(
        format: "#%02X%02X%02X",
        Int((srgb.redComponent * 255).rounded()),
        Int((srgb.greenComponent * 255).rounded()),
        Int((srgb.blueComponent * 255).rounded())
    )
}

func label(_ path: SplitPath) -> String {
    path.indices.isEmpty ? "root" : path.indices.map(String.init).joined(separator: ".")
}

@MainActor func read(_ harness: Harness) -> Reading {
    var reading = Reading()
    for (path, controller) in harness.splits {
        guard let split = controller.splitView as? PaneSplitView else { continue }
        reading.dividers[label(path)] = hex(split.dividerColor)
        reading.splitViews[label(path)] = ObjectIdentifier(split)
    }
    for leaf in harness.leaves.values {
        reading.leafViews[leaf.name] = ObjectIdentifier(leaf.view)
        // The superview is the assertion that matters. `rebuild()` keeps the pane
        // controller and therefore the view, and still moves that view to a new
        // parent, which is what resizes the ghostty grid.
        reading.leafParents[leaf.name] = leaf.view.superview.map(ObjectIdentifier.init)
            ?? ObjectIdentifier(leaf)
    }
    return reading
}

@MainActor func report(_ title: String, _ before: Reading, _ after: Reading) {
    print("=== \(title) ===")
    for key in before.dividers.keys.sorted() {
        let old = before.dividers[key] ?? "?"
        let new = after.dividers[key] ?? "?"
        print("  divider \(key.padding(toLength: 6, withPad: " ", startingAt: 0)) \(old) -> \(new)  \(old == new ? "UNCHANGED" : "repainted")")
    }
    let movedViews = before.leafViews.keys.sorted().filter { before.leafViews[$0] != after.leafViews[$0] }
    let movedParents = before.leafParents.keys.sorted().filter { before.leafParents[$0] != after.leafParents[$0] }
    let movedSplits = before.splitViews.keys.sorted().filter { before.splitViews[$0] != after.splitViews[$0] }
    print("  terminal views rebuilt:   \(movedViews.isEmpty ? "none" : movedViews.joined(separator: ", "))")
    print("  terminal views reparented: \(movedParents.isEmpty ? "none" : movedParents.joined(separator: ", "))")
    print("  split views rebuilt:      \(movedSplits.isEmpty ? "none" : movedSplits.joined(separator: ", "))")
}

// MARK: - the run

/// Two side-by-side columns, the left one split in two rows, so the walk has to
/// reach depth 2 and has to cross both axes.
@MainActor func makeHarness(theme: PaneTheme) -> Harness {
    let ids = [PaneID(), PaneID(), PaneID()]
    let names = [ids[0]: "A", ids[1]: "B", ids[2]: "C"]
    let tree = PaneTree.split(
        axis: .horizontal,
        ratio: 0.5,
        first: .split(axis: .vertical, ratio: 0.5, first: .leaf(ids[0]), second: .leaf(ids[1])),
        second: .leaf(ids[2])
    )
    return Harness(tree: tree, paneNames: names, theme: theme)
}

/// A light theme, so the divider it derives is nowhere near Dark Pastel's.
let paper = PaneTheme(
    background: .eightBit(0xFA, 0xF7, 0xF0),
    foreground: .eightBit(0x2B, 0x2B, 0x2B),
    focusedAccent: .eightBit(0x2A, 0x60, 0xC0),
    ansi: PaneTheme.darkPastel.ansi
)

@main
enum Probe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        switch CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "push" {
        case "noop": noop()
        case "rebuild": rebuildArm()
        default: push()
        }
    }

    /// The code as it stood: `refreshTheme()` called `rebuild()`, whose first
    /// statement is `guard renderedTree != current || renderedZoom != zoomedPane`.
    /// A theme change moves neither, so it returned before touching anything.
    @MainActor static func noop() {
        let harness = makeHarness(theme: .darkPastel)
        let before = read(harness)
        // What `rebuild()` did with an unchanged tree, which is nothing at all.
        harness.settle()
        report("pre-fix: refreshTheme() -> rebuild() -> early return", before, read(harness))
        print("  the dividers still carry Dark Pastel while every pane is on the new theme")
    }

    /// The rejected fix: force the rebuild past its guard. The colour lands, and
    /// the cost is every live terminal view moved to a new parent.
    @MainActor static func rebuildArm() {
        let harness = makeHarness(theme: .darkPastel)
        let before = read(harness)
        harness.host.teardown()
        harness.build(theme: paper)
        report("rejected fix: rebuild() forced past the guard", before, read(harness))
        print("  right colour, and every pane's surface reparented for it: a SIGWINCH each")
    }

    /// The shipped fix: push the theme into the views that are already there.
    @MainActor static func push() {
        let harness = makeHarness(theme: .darkPastel)
        let before = read(harness)
        harness.refreshTheme(paper)
        harness.settle()
        let after = read(harness)
        report("shipped fix: refreshTheme() pushes into the live views", before, after)

        var failures: [String] = []
        for key in before.dividers.keys.sorted() where before.dividers[key] == after.dividers[key] {
            failures.append("divider \(key) kept the old colour")
        }
        let expected = hex(NSColor(
            srgbRed: CGFloat(paper.divider.red),
            green: CGFloat(paper.divider.green),
            blue: CGFloat(paper.divider.blue),
            alpha: 1
        ))
        for key in after.dividers.keys.sorted() where after.dividers[key] != expected {
            failures.append("divider \(key) is \(after.dividers[key] ?? "?"), not the new theme's \(expected)")
        }
        if before.leafViews != after.leafViews { failures.append("a terminal view was rebuilt") }
        if before.leafParents != after.leafParents { failures.append("a terminal view was reparented") }
        if before.splitViews != after.splitViews { failures.append("a split view was rebuilt") }

        print("  every divider is the new theme's \(expected), nothing was torn down")
        guard failures.isEmpty else {
            for failure in failures { print("  FAILED: \(failure)") }
            exit(1)
        }
    }
}
