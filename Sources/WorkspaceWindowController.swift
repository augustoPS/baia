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
    /// Carries the project and message of the pane that just changed, so the
    /// banner names the pane that asked rather than the last one in the list.
    var onAttentionChange: ((String, String?) -> Void)?

    /// Raised for a capsule click with something to open. Carries this
    /// window's own pane id and request through unchanged; only the app
    /// delegate owns the popover panel that answers it.
    var onApprovalRequested: ((PaneID, TerminalPaneController.ApprovalRequest) -> Void)?

    /// The sidebar. Always present and always the window's content view, even when
    /// it is showing nothing: a host that came and went would have to swap
    /// `contentViewController`, and that reparents every live ghostty surface.
    let sidebar: SidebarHost

    /// Whether the window itself is transparent, so glass in it can sample the
    /// desktop rather than this app's own darkness.
    ///
    /// **This is what makes every other glass surface in the window mean
    /// anything.** `NSGlassEffectView` samples what is *behind* its window. An
    /// opaque `NSWindow` fills its whole frame rect with `backgroundColor`
    /// under the content view, so until this existed the sidebar's backing
    /// (``SurfaceHosts``) and the footer's (``PaneStatusBarView``) both lensed
    /// an opaque fill of the app's own making and returned flat grey. The
    /// terminal's own `background-opacity` had the same fate one layer down:
    /// ghostty's Metal layer does render the alpha the setting asks for, and a
    /// window-buffer capture measured every pixel at alpha 255 anyway, because
    /// that correctly-translucent surface was compositing against an opaque
    /// window instead of the desktop. The window had never been non-opaque —
    /// no commit in this repository had ever set `isOpaque` on it.
    ///
    /// **Driven by the setting, not by the chrome style** (owner decision,
    /// 2026-08-07). ``PaneChrome/windowIsTransparent(backgroundOpacity:appearance:)``
    /// is the whole rule and carries the rationale: `backgroundOpacity < 1`
    /// with Reduce Transparency off, whatever `chromeStyle` says. Flat chrome
    /// over translucent wells is a supported look, so nothing here reads
    /// ``PaneChrome/ResolvedChrome``. This is settings-driven window behaviour
    /// the owner has specified, and it leaves the "flat renders
    /// byte-identically" invariant intact because that invariant governs the
    /// chrome *drawing* paths — the fills, rims and backing views a surface
    /// creates — and none of them read these two flags.
    ///
    /// `backgroundBlur` remains unimplemented at the window level: it decodes,
    /// writes, and reaches ghostty as `background-blur`, but blurring what
    /// shows *through* this transparency needs the private CGS window-backdrop
    /// API, which is a separate decision.
    ///
    /// **Safe to move on a live window, unlike the pane arrangement.** A pane's
    /// glass arrangement is frozen at spawn (see
    /// ``TerminalPaneController/spawnedUnderGlass``) because changing it moves
    /// `window-padding-y` or the surface's bottom anchor, and either is a live
    /// grid resize that signals `SIGWINCH` to whatever is running in the shell.
    /// Nothing here goes near that: `isOpaque` and `backgroundColor` are
    /// compositing properties that AppKit reads when it draws the window's
    /// backing store. They feed no layout pass, no view frame, and no ghostty
    /// config key, so no surface changes size and no process is signalled. That
    /// is the asymmetry: window transparency follows a settings change live,
    /// pane layout cannot.
    var isTransparent: Bool = false {
        didSet {
            guard isTransparent != oldValue else { return }
            applyTransparency()
        }
    }

    /// `isTransparent` is a parameter rather than a later assignment for the
    /// reason ``ConfigurationCenter`` states about its own appearance observer:
    /// a caller cannot forget what it must name. It is also the reason
    /// ``SidebarHost`` takes its chrome. A window built opaque and made
    /// transparent a moment later would show one solid frame first.
    init(tree: PaneTreeController, sidebar: SidebarHost, isTransparent: Bool) {
        self.tree = tree
        self.sidebar = sidebar
        self.isTransparent = isTransparent
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        // The sidebar is the content and adopts the tree as a child, so the tree
        // still owns every pane and the window still has one content controller.
        // Showing nothing is a column of zero width, not a different content view.
        window.contentViewController = sidebar
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

        // Called rather than left to the property's `didSet`, which does not run
        // for an assignment made inside `init`. At `backgroundOpacity == 1` (or
        // under Reduce Transparency) this writes the values the window was born
        // with, so that case stays exactly what it has always been.
        applyTransparency()

        tree.onFocusedPaneChange = { [weak self] in self?.onFocusedPaneChange?() }
        tree.onSessionChange = { [weak self] in self?.onSessionChange?() }
        tree.onAttentionChange = { [weak self] _, project, message in
            self?.onAttentionChange?(project, message)
        }
        tree.onApprovalRequested = { [weak self] id, request in
            self?.onApprovalRequested?(id, request)
        }
        tree.onEmpty = { [weak self] in
            // The last pane of this tab exited. Close the tab rather than leaving
            // an empty one, which also releases the tree and any remaining panes.
            self?.window.close()
        }
    }

    /// Writes ``isTransparent`` onto the window.
    ///
    /// Both properties move together and neither alone is enough. `isOpaque =
    /// false` only *permits* transparency; the window still fills its frame
    /// rect with `backgroundColor` underneath the content view, so a window
    /// left at the default `windowBackgroundColor` renders exactly as solid as
    /// before. That is the same pairing the palette panel documents on its own
    /// copy (``CommandPaletteController``), found there when an opaque window
    /// colour refilled corners the content had just clipped away.
    ///
    /// Restores `.windowBackgroundColor` rather than remembering what was
    /// there: that is the value an `NSWindow` of this style mask is born with,
    /// and nothing in this file has ever assigned another.
    private func applyTransparency() {
        window.isOpaque = !isTransparent
        window.backgroundColor = isTransparent ? .clear : .windowBackgroundColor
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
