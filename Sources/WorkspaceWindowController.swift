import AppKit
import WorkspaceLayout

/// One window, which is also one tab.
///
/// Tabs are native `NSWindow` tabs rather than a bar baia draws. Drag to reorder,
/// drag out to detach, the overflow menu, Merge All Windows, and the keyboard
/// commands all come free and behave the way every other Mac app does. A custom
/// bar would mean rebuilding each of those and maintaining a second title path
/// beside `window.title`.
///
/// The cost is that tab *order* lives in AppKit rather than here. It is read from
/// `window.tabGroup` when a session is written, never mirrored continuously: a
/// mirror drifts the moment a tab is dragged out or windows are merged, and it
/// drifts silently.
@MainActor
final class WorkspaceWindowController: NSObject {
    let window: NSWindow
    let tree: PaneTreeController

    /// Raised when the window closes, so the owner drops its reference. Nothing
    /// else releases the panes, and a pane that outlives its window is a live
    /// shell with nowhere to type.
    var onClose: (() -> Void)?

    /// Raised for anything worth persisting or retitling.
    var onSessionChange: (() -> Void)?
    var onFocusedPaneChange: (() -> Void)?
    var onAttentionChange: (() -> Void)?

    init(tree: PaneTreeController) {
        self.tree = tree
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.contentViewController = tree
        window.title = "baia"

        // Assigning a contentViewController makes the window adopt the content's
        // fitting size and discard the contentRect above, so the size is set
        // after the assignment, not before. contentMinSize stops a future layout
        // change from collapsing the window to an invisible sliver.
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.setContentSize(NSSize(width: 1024, height: 680))
        window.center()

        // Every baia window shares one identifier, which is what lets AppKit
        // group them as tabs at all. `.preferred` means a new window joins the
        // existing group rather than opening detached, matching what cmd+t means
        // in a terminal.
        window.tabbingIdentifier = "baia.workspace"
        window.tabbingMode = .preferred

        // Closing a window must not deallocate it while AppKit is still using it
        // during the close. The owner drops its reference from `onClose` instead,
        // which is what actually releases the panes.
        window.isReleasedWhenClosed = false
        window.delegate = self

        tree.onFocusedPaneChange = { [weak self] in self?.onFocusedPaneChange?() }
        tree.onSessionChange = { [weak self] in self?.onSessionChange?() }
        tree.onAttentionChange = { [weak self] _ in self?.onAttentionChange?() }
        tree.onEmpty = { [weak self] in
            // The last pane of this tab exited. Close the tab rather than leaving
            // an empty one, which also releases the tree and any remaining panes.
            self?.window.close()
        }
    }

    /// Joins `other`'s tab group, or opens standalone when there is none.
    func show(joining other: NSWindow?) {
        if let other, other !== window {
            other.addTabbedWindow(window, ordered: .above)
        }
        window.makeKeyAndOrderFront(nil)
        tree.focusedPane?.takeFocus()
    }

    /// This window's tab, with its panes, for the session file.
    var snapshot: (tab: Tab, panes: [PaneState])? {
        let snapshot = tree.snapshot(windowFrame: nil)
        guard let tab = snapshot.workspace.tabs.first else { return nil }
        return (tab, snapshot.panes)
    }

    var frame: WindowFrame {
        WindowFrame(
            x: Double(window.frame.origin.x),
            y: Double(window.frame.origin.y),
            width: Double(window.frame.width),
            height: Double(window.frame.height)
        )
    }
}

extension WorkspaceWindowController: NSWindowDelegate {
    func windowWillClose(_: Notification) {
        onClose?()
    }

    func windowDidResize(_: Notification) {
        onSessionChange?()
    }

    func windowDidMove(_: Notification) {
        onSessionChange?()
    }

    /// AppKit asks for this when the tab bar's plus button is clicked, and hides
    /// the button entirely when nothing in the responder chain implements it.
    @objc func newWindowForTab(_ sender: Any?) {
        NSApp.sendAction(#selector(AppDelegate.newTab(_:)), to: nil, from: sender)
    }
}
