import AppKit
import WorkspaceLayout
import WorkspaceMenu

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Unordered, and deliberately so. Tab order lives in `window.tabGroup` and
    /// is read from there when a session is written. Keeping an ordered mirror
    /// here would drift the moment a tab is dragged out or windows are merged,
    /// and it would drift silently.
    private var windows: [WorkspaceWindowController] = []

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

        restoreSession()
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

    // MARK: - Windows and tabs

    /// The window the commands act on. `keyWindow` rather than a stored value,
    /// because a tab is selected by AppKit and by dragging, neither of which
    /// routes through baia.
    private var focused: WorkspaceWindowController? {
        if let key = NSApp.keyWindow, let match = windows.first(where: { $0.window === key }) {
            return match
        }
        return windows.first
    }

    private var tree: PaneTreeController? { focused?.tree }

    @discardableResult
    private func openWindow(
        tree: PaneTreeController,
        joining sibling: NSWindow?
    ) -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(tree: tree)
        windows.append(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            windows.removeAll { $0 === controller }
            // Dropped before the save so a closed tab is gone from the next
            // snapshot rather than restored on the following launch.
            scheduleSave()
        }
        controller.onSessionChange = { [weak self] in self?.scheduleSave() }
        controller.onFocusedPaneChange = { [weak self] in self?.updateWindowTitles() }
        controller.onAttentionChange = { [weak self] in
            self?.updateWindowTitles()
            self?.notifyIfUnfocused(controller)
        }
        controller.show(joining: sibling)
        updateWindowTitles()
        return controller
    }

    @objc func newTab(_: Any?) {
        // The new tab opens where the focused pane is, not at the workspace root.
        // Opening a tab is usually a second view of the project already in front.
        let directory = tree?.focusedPane?.anchorTracker.workingDirectory?
            .path(percentEncoded: false) ?? Self.defaultWorkingDirectory
        openWindow(
            tree: PaneTreeController(workingDirectory: directory),
            joining: focused?.window
        )
    }

    @objc func newWorkspaceWindow(_: Any?) {
        let controller = WorkspaceWindowController(
            tree: PaneTreeController(workingDirectory: Self.defaultWorkingDirectory)
        )
        // Detached on purpose: New Window means a window, and joining the group
        // would make it indistinguishable from New Tab.
        controller.window.tabbingMode = .disallowed
        windows.append(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            windows.removeAll { $0 === controller }
            scheduleSave()
        }
        controller.onSessionChange = { [weak self] in self?.scheduleSave() }
        controller.onFocusedPaneChange = { [weak self] in self?.updateWindowTitles() }
        controller.show(joining: nil)
    }

    @objc func closeTab(_: Any?) {
        focused?.window.close()
    }

    // MARK: - Title

    /// Retitles every window, because the waiting count is a property of the
    /// workspace rather than of one tab: a tab in the background that starts
    /// asking has to be visible from whichever tab is in front.
    private func updateWindowTitles() {
        let waiting = windows.reduce(0) { $0 + $1.tree.waitingProjects.count }
        // The marker goes in the title because that is the one place macOS shows
        // reliably for a background app: the Window menu, Mission Control, and
        // the window switcher all read it. A dock badge would be the obvious home
        // and does not work here, see `AttentionNotifier`.
        let marker = waiting > 0 ? "\u{25CF} \(waiting) waiting  " : ""
        for controller in windows {
            controller.window.title = marker + controller.tree.windowTitle.title
            controller.window.subtitle = controller.tree.windowTitle.subtitle
        }
    }

    private func notifyIfUnfocused(_ controller: WorkspaceWindowController?) {
        guard let controller,
              controller.window.isKeyWindow != true,
              let project = controller.tree.waitingProjects.last
        else { return }
        notifier.notify(project: project, message: nil)
    }

    // MARK: - Session

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
        guard !isTerminating, !windows.isEmpty else { return }
        _ = sessionStore.save(snapshot())
    }

    /// Tabs in the order AppKit has them, which is the only place that order
    /// exists. `tabGroup` is nil for a window that is not in a group, so a
    /// detached window contributes itself.
    private func orderedWindows() -> [WorkspaceWindowController] {
        var seen: Set<ObjectIdentifier> = []
        var ordered: [WorkspaceWindowController] = []
        for controller in windows {
            let group = controller.window.tabGroup?.windows ?? [controller.window]
            for window in group {
                guard let match = windows.first(where: { $0.window === window }),
                      seen.insert(ObjectIdentifier(match)).inserted
                else { continue }
                ordered.append(match)
            }
        }
        return ordered
    }

    private func snapshot() -> SessionSnapshot {
        var tabs: [Tab] = []
        var panes: [PaneState] = []
        var focusedIndex = 0
        for (index, controller) in orderedWindows().enumerated() {
            guard let piece = controller.snapshot else { continue }
            if controller.window.isKeyWindow { focusedIndex = index }
            tabs.append(piece.tab)
            panes.append(contentsOf: piece.panes)
        }
        return SessionSnapshot(
            workspace: Workspace(tabs: tabs, focusedTabIndex: focusedIndex),
            panes: panes,
            windowFrame: focused?.frame
        )
    }

    /// Rebuilds the workspace, or opens one fresh pane.
    ///
    /// Reconciliation drops panes whose directory no longer exists and repairs
    /// focus, so a workspace that pointed at a deleted worktree opens without it
    /// rather than failing to open. A snapshot with nothing left after that is
    /// treated as no snapshot at all.
    private func restoreSession() {
        guard let snapshot = sessionStore.load() else { return openFresh() }
        let (reconciled, _) = SessionStore.reconciled(snapshot) { path in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
        guard !reconciled.workspace.tabs.isEmpty else { return openFresh() }

        var first: NSWindow?
        // Each tab joins the one before it, never the first. `addTabbedWindow`
        // inserts *after* the window it is given, so joining everything to the
        // first window builds the group in reverse after the second tab: saving
        // baia, vault, shop restored them as baia, shop, vault.
        var previous: NSWindow?
        for tab in reconciled.workspace.tabs {
            // One window per tab, each restoring only its own panes.
            let piece = SessionSnapshot(
                workspace: Workspace(tabs: [tab], focusedTabIndex: 0),
                panes: reconciled.panes,
                windowFrame: nil
            )
            let controller = openWindow(
                tree: PaneTreeController(
                    restoring: piece,
                    defaultWorkingDirectory: Self.defaultWorkingDirectory
                ),
                joining: previous
            )
            if first == nil { first = controller.window }
            previous = controller.window
        }
        restoreFrame(reconciled.windowFrame, on: first)

        // Focused last, because joining a tab group brings the new tab forward.
        let index = reconciled.workspace.focusedTabIndex
        if windows.indices.contains(index) {
            windows[index].window.makeKeyAndOrderFront(nil)
            windows[index].tree.focusedPane?.takeFocus()
        }
        updateWindowTitles()
    }

    private func openFresh() {
        openWindow(
            tree: PaneTreeController(workingDirectory: Self.defaultWorkingDirectory),
            joining: nil
        )
    }

    /// Applied only when the frame still lands on a screen that exists. A frame
    /// saved on a monitor since unplugged would put the window somewhere running,
    /// focusable, and invisible.
    private func restoreFrame(_ frame: WindowFrame?, on window: NSWindow?) {
        guard let frame, let window else { return }
        let restored = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(restored) }) else {
            return
        }
        window.setFrame(restored, display: false)
    }

    /// Opens in the workspace root. A tab opened from a pane inherits that pane's
    /// directory instead, which is what `newTab` does.
    private static var defaultWorkingDirectory: String {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Projects")
            .path(percentEncoded: false)
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
        scheduleSave()
    }

    @objc func clearProjectDirectoryPin(_: Any?) {
        tree?.focusedPane?.anchorTracker.clearPin()
        scheduleSave()
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
            tabCount: focused?.window.tabGroup?.windows.count ?? windows.count,
            isPinned: tree.focusedPane?.anchorTracker.isPinned ?? false,
            hasAnchor: anchor != nil,
            anchorIsRepository: anchor?.kind == .repository,
            isZoomed: tree.isZoomed,
            statusBarsVisible: true,
            paletteAvailable: false
        )
    }
}
