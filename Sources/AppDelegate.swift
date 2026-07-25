import AppKit
import WorkspaceLayout
import WorkspaceMenu

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var tree: PaneTreeController?

    private let sessionStore = SessionStore(fileURL: SessionStore.defaultFileURL())

    private let notifier = AttentionNotifier()

    /// Coalesces the writes. Every `cd` in every pane reports a session change
    /// through the one-second anchor poll, so writing on each one would rewrite
    /// the file several times a second for a workspace nobody is restructuring.
    private var saveTimer: Timer?

    /// Cleared during teardown so the flush at termination cannot be followed by
    /// an empty snapshot that overwrites a good file with nothing.
    private var isTerminating = false

    func applicationDidFinishLaunching(_: Notification) {
        MainMenu.install(into: NSApp)
        PaneAnchorTracker.removeLegacyPin()
        notifier.requestAuthorizationIfNeeded()

        let tree = Self.restoredTree(from: sessionStore)
        self.tree = tree

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = tree
        window.title = "baia"

        // Assigning a contentViewController makes the window adopt the content's
        // fitting size and discard the contentRect above, so set the size after
        // the assignment, not before. contentMinSize stops a future layout change
        // from collapsing the window to an invisible sliver.
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.setContentSize(NSSize(width: 1024, height: 680))
        window.center()

        // The session file owns the frame now, so there is no autosave name. Two
        // mechanisms restoring one frame would fight, and the autosave one
        // already persisted a collapsed window once, which then survived a code
        // fix and made it look like the fix had done nothing.
        if let frame = sessionStore.load()?.windowFrame {
            let restored = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            // Only when it lands on a screen that still exists. A frame saved on
            // a monitor that has since been unplugged would put the window off
            // every display, where it is running, focusable, and invisible.
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(restored) }) {
                window.setFrame(restored, display: false)
            }
        }
        window.makeKeyAndOrderFront(nil)

        // The window owns its title because with several panes only the focused
        // one may name it. A pane that set the title itself would have every
        // pane overwriting it on every one-second poll.
        tree.onFocusedPaneChange = { [weak self] in
            self?.updateWindowTitle()
        }
        tree.onEmpty = { [weak self, weak window] in
            // The last pane is gone, so there is nothing left worth restoring.
            // Cleared before the close so the teardown flush cannot write a
            // snapshot of a window that is on its way out.
            self?.isTerminating = true
            window?.close()
        }
        tree.onSessionChange = { [weak self] in
            self?.scheduleSave()
        }
        tree.onAttentionChange = { [weak self, weak window] projects in
            guard let self else { return }
            updateWindowTitle()
            // Only for a window the user is not already looking at. A banner for
            // a pane on screen is noise, and the footer already shows it.
            guard window?.isKeyWindow != true, let project = projects.last else { return }
            notifier.notify(project: project, message: nil)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeFrame),
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeFrame),
            name: NSWindow.didMoveNotification,
            object: window
        )

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        scheduleSave()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_: Notification) {
        // Written synchronously rather than through the timer, which would never
        // fire: the run loop stops before a scheduled save comes due.
        saveTimer?.invalidate()
        saveTimer = nil
        save()
        isTerminating = true
    }

    /// Composes the window title from the focused pane plus anything waiting.
    ///
    /// The waiting count lives in the title because that is the one place macOS
    /// shows reliably for a background app: the window menu, Mission Control, and
    /// the window switcher all read it. A dock badge would be the obvious home
    /// and does not work here, see `AttentionNotifier`.
    private func updateWindowTitle() {
        guard let tree, let window else { return }
        let waiting = tree.waitingProjects.count
        let marker = waiting > 0 ? "\u{25CF} \(waiting) waiting  " : ""
        window.title = marker + tree.windowTitle.title
        window.subtitle = tree.windowTitle.subtitle
    }

    // MARK: - Session

    @objc private func windowDidChangeFrame() {
        scheduleSave()
    }

    private func scheduleSave() {
        guard !isTerminating else { return }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.save()
            }
        }
    }

    private func save() {
        guard !isTerminating, let tree else { return }
        _ = sessionStore.save(tree.snapshot(windowFrame: windowFrame))
    }

    private var windowFrame: WindowFrame? {
        guard let frame = window?.frame else { return nil }
        return WindowFrame(
            x: Double(frame.origin.x),
            y: Double(frame.origin.y),
            width: Double(frame.width),
            height: Double(frame.height)
        )
    }

    /// Restores the last session, or opens a fresh single pane.
    ///
    /// Reconciliation drops panes whose directory no longer exists and repairs
    /// focus, so a workspace that pointed at a deleted worktree opens without it
    /// rather than failing to open. A snapshot with nothing left after that is
    /// treated as no snapshot at all.
    /// The fresh controller is built only on the paths that return it. Building
    /// it up front as a fallback and discarding it spawned a shell and killed it
    /// again on every restore, which is invisible but real: a pty allocated, a
    /// login and a zsh forked, and all of it torn down a millisecond later.
    private static func restoredTree(from store: SessionStore) -> PaneTreeController {
        guard let snapshot = store.load() else {
            return PaneTreeController(workingDirectory: defaultWorkingDirectory)
        }
        let (reconciled, _) = SessionStore.reconciled(snapshot) { path in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
        guard reconciled.workspace.focusedPane != nil else {
            return PaneTreeController(workingDirectory: defaultWorkingDirectory)
        }
        return PaneTreeController(
            restoring: reconciled,
            defaultWorkingDirectory: defaultWorkingDirectory
        )
    }

    // MARK: - Pane commands

    @objc func splitPaneRight(_: Any?) {
        tree?.splitFocusedPane(axis: .horizontal)
    }

    @objc func splitPaneDown(_: Any?) {
        tree?.splitFocusedPane(axis: .vertical)
    }

    @objc func closePane(_: Any?) {
        tree?.closeFocusedPane()
    }

    @objc func zoomPane(_: Any?) {
        tree?.toggleZoom()
    }

    @objc func focusPaneLeft(_: Any?) { tree?.moveFocus(.left) }

    @objc func focusPaneRight(_: Any?) { tree?.moveFocus(.right) }

    @objc func focusPaneUp(_: Any?) { tree?.moveFocus(.up) }

    @objc func focusPaneDown(_: Any?) { tree?.moveFocus(.down) }

    @objc func selectNextPane(_: Any?) {
        tree?.focusNextPane()
    }

    // MARK: - Project commands

    @objc func setProjectDirectory(_: Any?) {
        guard let pane = tree?.focusedPane else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Pin"
        panel.message = "Choose the directory to anchor this pane's project to."
        panel.directoryURL = pane.anchorTracker.workingDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pane.anchorTracker.setPin(url)
    }

    @objc func clearProjectDirectoryPin(_: Any?) {
        tree?.focusedPane?.anchorTracker.clearPin()
    }

    @objc func revealAnchor(_: Any?) {
        guard let anchor = tree?.focusedPane?.anchorTracker.anchor else { return }
        NSWorkspace.shared.activateFileViewerSelecting([anchor.url])
    }

    @objc func copyAnchorPath(_: Any?) {
        guard let anchor = tree?.focusedPane?.anchorTracker.anchor else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(anchor.url.path(percentEncoded: false), forType: .string)
    }

    /// Opens in the workspace root for now. Once panes are per-project this
    /// becomes the selected project's directory instead.
    private static var defaultWorkingDirectory: String {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Projects")
            .path(percentEncoded: false)
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Every rule lives in `MenuValidation`, an exhaustive switch over the
    /// command set, so adding a command is a compile error in the package until
    /// its rule is written. This method's only job is to describe the current
    /// state and recover which command an item is.
    ///
    /// The command is read from the item's tag rather than its selector, because
    /// several commands share one selector shape and a title can be localised.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = MenuCommand(tag: menuItem.tag) else { return true }
        let state = MenuValidation.state(for: command, given: availability)
        // Set here rather than when the menu is built. AppKit revalidates on
        // every menu open, so a checkmark applied at build time would sit on
        // whichever item held it at launch until the app was relaunched.
        if let checked = state.isChecked {
            menuItem.state = checked ? .on : .off
        }
        return state.isEnabled
    }

    private var availability: MenuAvailability {
        guard let tree else { return .empty }
        let anchor = tree.focusedPane?.anchorTracker.anchor
        return MenuAvailability(
            paneCount: tree.paneCount,
            tabCount: 1,
            isPinned: tree.focusedPane?.anchorTracker.isPinned ?? false,
            hasAnchor: anchor != nil,
            anchorIsRepository: anchor?.kind == .repository,
            isZoomed: tree.isZoomed,
            statusBarsVisible: true,
            paletteAvailable: false
        )
    }
}
