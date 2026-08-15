import AppKit
import PaneChrome
import PaneSearch

// Headless proof of the two things the find panel is not allowed to get wrong.
//
// `FindPanelController`, `PalettePanel` and the three palette views are NOT
// retyped here. `run.sh` compiles `Sources/FindPanelController.swift` and
// `Sources/CommandPaletteView.swift` verbatim beside this file and slices
// `PalettePanel` out of `Sources/CommandPaletteController.swift`, so the probe
// cannot pass against a copy that has drifted from what the app builds.
// `PaneSearch` and `PaneChrome` are the real package binaries.
//
// The two cases:
//   responder  invariant 1: nothing the panel does may leave a responder inside
//              a pane's window, and closing it hands the keyboard back to that
//              window. A failure here disables every ghostty binding in the
//              pane, silently and with nothing on screen to explain it.
//   retention  a pane closed while the panel still holds a result for it must
//              still deallocate. libghostty cannot close a surface, so a pane's
//              pty dies only when its controller does: a leaked reference is a
//              leaked live shell.
//
// No screenshot is taken and no mouse is moved. The app is never activated
// either, which is why this asserts that the host window was *asked* for the
// keyboard back rather than that it holds it: an unbundled binary launched from
// a terminal has no active GUI session, so `isKeyWindow` on an ordinary window
// is false throughout regardless of what the code under test does. The
// `.nonactivatingPanel` really does take key in that state, which is what makes
// the hand-back path run at all.

var failures = 0

func check(_ passed: Bool, _ what: String) {
    if passed {
        print("  ok    \(what)")
    } else {
        failures += 1
        print("  FAIL  \(what)")
    }
}

/// Stands in for `AppTerminalView`, which needs libghostty, a Metal device and a
/// spawned shell. What is under test is an AppKit fact and not a ghostty one:
/// which view holds first responder in the pane's window. The one thing that has
/// to be true of the stand-in is the thing that makes the trap possible, which is
/// that it can hold first responder at all.
final class TerminalStandIn: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// Counts the hand-back. `FindPanelController.dismiss()` calls `makeKey()` on the
/// window it was summoned over, and that call is the whole of invariant 1 on the
/// way out.
final class KeyLoggingWindow: NSWindow {
    var makeKeyCount = 0

    override func makeKey() {
        makeKeyCount += 1
        super.makeKey()
    }
}

/// A pane, reduced to the two things that cross the panel's boundary: an id and
/// its lines. Deallocation is the assertion in the retention case, observed
/// through a weak reference rather than through a `deinit` side effect, which
/// under `-default-isolation MainActor` would be a nonisolated deinit touching
/// isolated state.
final class PaneStandIn {
    let id = UUID()
    let lines: [String]

    init(lines: [String]) {
        self.lines = lines
    }
}

/// Owns the panes, as `PaneTreeController` does. Closing a pane is dropping it
/// from here, which is exactly what the real close path amounts to.
@MainActor
final class WorkspaceStandIn {
    var panes: [PaneStandIn] = []
}

// MARK: - reaching into the panel

/// The panel's own window, found by type rather than by `NSApp.keyWindow`, so
/// this works whether or not the process has an active GUI session.
@MainActor func palettePanel() -> PalettePanel? {
    NSApp.windows.compactMap { $0 as? PalettePanel }.first { $0.isVisible }
}

@MainActor func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
}

@MainActor func queryField(in window: NSWindow) -> PaletteQueryField? {
    guard let content = window.contentView else { return nil }
    return descendants(of: content).compactMap { $0 as? PaletteQueryField }.first
}

@MainActor func resultList(in window: NSWindow) -> PaletteListView? {
    guard let content = window.contentView else { return nil }
    return descendants(of: content).compactMap { $0 as? PaletteListView }.first
}

@MainActor func settle() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}

/// A window holding one terminal, with the terminal as first responder, which is
/// the state every ghostty binding in a pane depends on.
@MainActor func makeHost() -> (window: KeyLoggingWindow, terminal: TerminalStandIn) {
    let window = KeyLoggingWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1024, height: 680),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    let terminal = TerminalStandIn(frame: NSRect(x: 0, y: 0, width: 1024, height: 680))
    window.contentView?.addSubview(terminal)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(terminal)
    settle()
    window.makeKeyCount = 0
    return (window, terminal)
}

let lines = [
    "$ make build",
    "error: BRAVO could not be built",
    "note: ALPHA is fine",
]

let app = NSApplication.shared

@main
enum Probe {
    @MainActor static func main() {
        app.setActivationPolicy(.accessory)
        switch CommandLine.arguments[1] {
        case "responder": responder()
        case "retention": retention()
        default: print("unknown case"); exit(2)
        }
        print(failures == 0 ? "PASS" : "FAILED \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - invariant 1

    /// Open the panel over a pane, search, leave by Escape, and prove that
    /// nothing in the pane's window ever moved.
    ///
    /// The trap this exists for is not hypothetical: `performKeyEquivalent` on
    /// the terminal opens with `guard window?.firstResponder === self`, so a find
    /// bar built as a subview of the pane, which is the obvious way to build one,
    /// kills every ghostty binding in that pane with no error anywhere.
    @MainActor static func responder() {
        let (host, terminal) = makeHost()
        let pane = PaneStandIn(lines: lines)
        let find = FindPanelController()
        find.onCollect = { _ in [(id: pane.id, project: "baia", lines: pane.lines)] }
        var went: [UUID] = []
        find.onGo = { went.append($0.paneID) }

        print("=== the panel takes the keyboard in its own window ===")
        check(!find.isVisible, "the panel starts closed")
        find.toggle(over: host)
        settle()

        check(find.isVisible, "the panel is up")
        guard let panel = palettePanel() else {
            check(false, "the panel has a window")
            return
        }
        check(panel !== host, "the panel is a window of its own, not a view in the pane's")
        check(panel.isKeyWindow, "the panel holds the keyboard")
        // Keyness alone is a proxy and was the only thing asserted here until
        // 2026-08-14: a window becomes key by being ordered front, whichever view
        // inside it holds focus, so nothing checked that focus reaches the field,
        // which is the one thing that makes the panel usable.
        //
        // What the mutations found is worth keeping, because it is not what the
        // defect report assumed. Deleting `FindPanelController`'s
        // `makeFirstResponder(queryView.field)` does **not** break focus: AppKit
        // focuses the first `acceptsFirstResponder` view in the key-view loop when
        // a window becomes key with no responder set, and that is this field
        // (`CommandPaletteView.swift:234`). So the explicit call is belt-and-braces
        // and its deletion is invisible from outside, which is why the old arm
        // passed without it and why this one does too. The property that actually
        // decides focus is the field's `acceptsFirstResponder`; refusing it fails
        // this check and passes the keyness one, which is the separation the arm
        // exists for. Proved by both mutations rather than read off the source.
        //
        // `currentEditor()` is in the comparison because an `NSTextField` hands
        // first-responder status to the window's shared field editor once focused,
        // so identity against the field alone is false exactly when focus is right.
        check(
            queryField(in: panel).map { panel.firstResponder === $0 || panel.firstResponder === $0.currentEditor() } ?? false,
            "the search field holds focus inside the panel"
        )
        check(host.firstResponder === terminal, "the pane's window still points at the terminal")
        // The regression a future inline find bar would trip. Every control the
        // panel owns has to be in the panel's window; one of them in the host is
        // the dead-bindings bug whatever else is true.
        let hostControls = descendants(of: host.contentView!).compactMap { $0 as? NSControl }
        check(hostControls.isEmpty, "no control was added to the pane's window")

        print("=== typing searches, and still nothing moves ===")
        guard let field = queryField(in: panel), let list = resultList(in: panel) else {
            check(false, "the panel has a query field and a list")
            return
        }
        field.stringValue = "BRAVO"
        find.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        settle()
        check(list.rows.count == 1, "one hit, drawn in the panel")
        check(host.firstResponder === terminal, "the pane's window still points at the terminal")
        check(host.makeKeyCount == 0, "the keyboard was not handed back while the panel is up")

        print("=== escape hands the keyboard back ===")
        // The real Escape path: `PaletteQueryField.cancelOperation` is what AppKit
        // calls, and it raises the same `onCommand` the controller installed.
        field.cancelOperation(nil)
        settle()
        check(!find.isVisible, "the panel is closed")
        check(host.makeKeyCount == 1, "the pane's window was asked for the keyboard back exactly once")
        check(host.firstResponder === terminal, "the terminal is still first responder")
        check(went.isEmpty, "escape went to no match")

        print("=== the same is true on the way out through a match ===")
        find.toggle(over: host)
        settle()
        guard let reopened = palettePanel(), let field = queryField(in: reopened) else {
            check(false, "the panel reopened")
            return
        }
        field.stringValue = "ALPHA"
        find.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        settle()
        _ = field.onCommand?(#selector(NSResponder.insertNewline(_:)))
        settle()
        check(went == [pane.id], "return reported the match by pane id")
        check(!find.isVisible, "the panel closed on the way to the match")
        check(host.makeKeyCount == 2, "the pane's window was asked for the keyboard back again")
        check(host.firstResponder === terminal, "the terminal is still first responder")
    }

    // MARK: - the leaked-shell check

    /// A pane closed while the panel holds a result for it must still die.
    ///
    /// The panel outlives every window, so anything it holds outlives them too.
    /// `FindResult` carries a pane id and the lines it matched, and never a pane,
    /// precisely so this is true; `onCollect` returns the same value shapes for
    /// the same reason. Without that, closing a tab leaves its shells running
    /// with no window to reach them, visible only as a stray `login -flp` in
    /// `ps`.
    @MainActor static func retention() {
        let (host, _) = makeHost()
        let workspace = WorkspaceStandIn()

        // The only strong reference to the pane is the workspace's, which is the
        // shape the app has: `PaneTreeController` is the sole owner of a
        // `TerminalPaneController`. The local one is dropped at the end of this
        // scope so that what happens next is a real close and not a close with a
        // second owner standing behind it.
        weak var livePane: PaneStandIn?
        let paneID: UUID
        do {
            let pane = PaneStandIn(lines: lines)
            livePane = pane
            paneID = pane.id
            workspace.panes = [pane]
        }

        let find = FindPanelController()
        // Weakly captured and read through the owner, which is what
        // `AppDelegate.panesToSearch` does. A closure that closed over the pane
        // itself would be the leak, and it would be this object holding it.
        find.onCollect = { [weak workspace] _ in
            (workspace?.panes ?? []).map { (id: $0.id, project: "baia", lines: $0.lines) }
        }
        var went: [UUID] = []
        find.onGo = { went.append($0.paneID) }

        print("=== the panel is holding a result for a live pane ===")
        find.toggle(over: host)
        settle()
        guard let panel = palettePanel(),
              let field = queryField(in: panel),
              let list = resultList(in: panel)
        else {
            check(false, "the panel is up with a field and a list")
            return
        }
        field.stringValue = "BRAVO"
        find.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        settle()
        check(list.rows.count == 1, "the panel holds one result for the pane")
        check(livePane != nil, "the pane is alive")

        print("=== closing the pane deallocates it anyway ===")
        // Closing a pane is the owner dropping it. Nothing else releases one, and
        // the panel is still open and still holding the result.
        workspace.panes = []
        settle()
        check(livePane == nil, "the pane deallocated while the panel still shows its match")
        check(list.rows.count == 1, "the result is still drawn, from the lines it copied")

        print("=== and the dead result still travels as an id ===")
        _ = field.onCommand?(#selector(NSResponder.insertNewline(_:)))
        settle()
        check(went == [paneID], "return reported the dead pane by id, carrying no pane")
        check(livePane == nil, "nothing brought the pane back")
    }
}
