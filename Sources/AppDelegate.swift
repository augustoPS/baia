import AppKit
import BaiaSettings
import GitWorkspace
import PaneChrome
import WorkspaceLayout
import WorkspaceMenu

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Unordered, and deliberately so. Tab order lives in `window.tabGroup` and
    /// is read from there when a session is written. Keeping an ordered mirror
    /// here would drift the moment a tab is dragged out or windows are merged,
    /// and it would drift silently.
    private var windows: [WorkspaceWindowController] = []

    private let sessionStore = SessionStore(fileURL: SessionStore.defaultFileURL())

    /// The config file, and everything derived from it. Created before any
    /// window, because a pane built before it exists would come up in
    /// libghostty's defaults.
    private lazy var configuration: ConfigurationCenter = {
        let center = ConfigurationCenter()
        center.onSettingsChange = { [weak self] in self?.settingsDidChange() }
        return center
    }()

    private let notifier = AttentionNotifier()

    private lazy var palette: CommandPaletteController = {
        let palette = CommandPaletteController()
        palette.theme = configuration.paneTheme
        palette.onOpen = { [weak self] project, action in
            self?.open(project, action: action)
        }
        return palette
    }()

    /// The ⌘F panel. Built once and reused, like the palette, because a panel
    /// rebuilt per invocation would rebuild its window on a keystroke.
    private lazy var find: FindPanelController = {
        let find = FindPanelController()
        find.theme = configuration.paneTheme
        find.onCollect = { [weak self] scope in self?.panesToSearch(scope) ?? [] }
        find.onGo = { [weak self] result in self?.go(to: result) }
        return find
    }()

    /// The project list, discovered once and reused until something asks for it
    /// again.
    ///
    /// Walking the roots stats a large tree, and doing it on every ⌘K would put
    /// that cost between the key and the first character typed, which is exactly
    /// where it is most noticeable. Reload Project List is the escape hatch for a
    /// project created since launch.
    private var discoveredProjects: [Project]?

    /// Guards against two walks running at once, which the launch warm-up and an
    /// early ⌘K would otherwise start.
    private var isDiscovering = false

    /// Watches every keystroke that reaches a workspace window, so typing into a
    /// pane answers its request for attention.
    ///
    /// A local monitor rather than anything in the responder chain, because
    /// `AppTerminalView.performKeyEquivalent` opens with
    /// `guard window?.firstResponder === self`, so any view in a pane that can
    /// take first responder silently disables every ghostty binding in it. The
    /// monitor sees the event and returns it unchanged, adding no responder.
    /// `Any?` because that is what `addLocalMonitorForEvents` returns. Never
    /// removed: the monitor lives as long as the app does, and the delegate
    /// outlives every window.
    private var keyMonitor: Any?

    private let recentProjects = RecentProjects(fileURL: RecentProjects.defaultFileURL())

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
        // Authorization is requested regardless of the setting, so turning
        // notifications back on later does not need a relaunch to get the
        // prompt. Only `notify` is gated.
        notifier.requestAuthorizationIfNeeded()
        notifier.isEnabled = configuration.settings.notificationsEnabled

        restoreSession()
        NSApp.activate(ignoringOtherApps: true)
        scheduleSave()
        installKeyMonitor()
        // Warmed here so the first ⌘K of a session opens on a full list rather
        // than on an empty one that fills in a moment later.
        discoverProjects()
    }

    /// Routes each keystroke to the pane that received it.
    ///
    /// `event.window` rather than the app's key window, and matched against the
    /// windows baia owns: one monitor for the whole app, and typing in one tab
    /// must not answer another tab's request. Events belonging to the palette
    /// match nothing here and are ignored.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let window = event.window,
               let match = self?.windows.first(where: { $0.window === window }) {
                match.tree.focusedPane?.noteInput()
            }
            return event
        }
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
    ///
    /// `mainWindow` is consulted second because the ⌘K palette is a key window
    /// baia does not own. While it is up, `keyWindow` matches nothing here and
    /// the old fallback to `windows.first` handed every command to the *oldest*
    /// tab, which is unordered and usually not the one on screen: ⌥⌘W closed a
    /// background tab and all of its live shells while nothing visible changed.
    /// `PalettePanel.canBecomeMain` is false precisely so the workspace window
    /// stays main underneath it, which is what makes this resolve correctly.
    private var focused: WorkspaceWindowController? {
        for candidate in [NSApp.keyWindow, NSApp.mainWindow] {
            if let candidate, let match = windows.first(where: { $0.window === candidate }) {
                return match
            }
        }
        return windows.first
    }

    private var tree: PaneTreeController? { focused?.tree }

    /// The one place a workspace window is built and wired.
    ///
    /// `tabbing` exists so New Window can be this function too. It used to have
    /// its own copy of the wiring, which drifted: a detached window never got
    /// `onAttentionChange`, so a pane in it could ask for the owner and produce
    /// no banner and no title marker at all.
    @discardableResult
    private func openWindow(
        tree: PaneTreeController,
        joining sibling: NSWindow?,
        tabbing: NSWindow.TabbingMode = .preferred
    ) -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(tree: tree)
        controller.window.tabbingMode = tabbing
        windows.append(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            windows.removeAll { $0 === controller }
            // Dropped before the save so a closed tab is gone from the next
            // snapshot rather than restored on the following launch.
            scheduleSave()
            // Retitle the survivors. The waiting count is workspace-wide, so a
            // closed tab whose pane was asking otherwise leaves `! project` on
            // every remaining title, naming a pane that no longer exists.
            updateWindowTitles()
        }
        controller.onSessionChange = { [weak self] in self?.scheduleSave() }
        controller.onFocusedPaneChange = { [weak self] in self?.updateWindowTitles() }
        // `weak controller` is not decoration. The controller stores this
        // closure, so a strong capture is a cycle that outlives the close:
        // `isReleasedWhenClosed` is false and `onClose` only drops *our*
        // reference, so the controller, its tree, every pane and every live
        // shell under them stayed alive with no window to reach them. There is
        // no API to close a libghostty surface, so one leaked reference here is
        // a leaked shell, visible only as a stray `login -flp` in `ps`.
        controller.onAttentionChange = { [weak self, weak controller] project, message in
            self?.updateWindowTitles()
            self?.notifyIfUnfocused(controller, project: project, message: message)
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
            tree: PaneTreeController(workingDirectory: directory, configuration: configuration),
            joining: focused?.window
        )
    }

    @objc func newWorkspaceWindow(_: Any?) {
        // Detached on purpose: New Window means a window, and joining the group
        // would make it indistinguishable from New Tab.
        openWindow(
            tree: PaneTreeController(
                workingDirectory: Self.defaultWorkingDirectory,
                configuration: configuration
            ),
            joining: nil,
            tabbing: .disallowed
        )
    }

    @objc func closeTab(_: Any?) {
        focused?.window.close()
    }

    // MARK: - Command palette

    @objc func showCommandPalette(_: Any?) {
        // Opens on the cache, which is empty only on the first ⌘K of a launch
        // that beat the warm-up. The walk never happens between the key and the
        // first frame: it stats the whole workspace and forks one
        // `git worktree list` per repository, all synchronously, so running it
        // here froze the app for the duration and one hung repository on a
        // network mount would have frozen it indefinitely.
        palette.toggle(
            over: focused?.window,
            projects: discoveredProjects ?? [],
            recency: recentProjects.load()
        )
        discoverProjects()
    }

    // MARK: - Find

    @objc func findInPane(_: Any?) {
        find.toggle(over: focused?.window)
    }

    /// The panes a search covers, already read.
    ///
    /// Reading happens here rather than in the panel because only the delegate
    /// knows what a tab is, and the read has to be on the main actor: surface
    /// access requires it. Matching is on the main actor too, which is why the
    /// panel calls this once per open rather than once per keystroke and why the
    /// matching itself is capped.
    ///
    /// Lines and ids cross the boundary, never panes. The panel outlives every
    /// window, and libghostty has no way to close a surface, so a pane reference
    /// held there would be a live shell with nothing to reach it.
    private func panesToSearch(
        _ scope: FindScope
    ) -> [(id: UUID, project: String, lines: [String])] {
        let controllers: [PaneTreeController] = switch scope {
        case .focusedPane: [tree].compactMap { $0 }
        case .workspace: windows.map(\.tree)
        }

        return controllers.flatMap { controller -> [(id: UUID, project: String, lines: [String])] in
            let panes = scope == .focusedPane
                ? [controller.focusedPane].compactMap { $0 }
                : controller.allPanes
            return panes.compactMap { pane in
                // A pane whose surface does not exist yet contributes nothing
                // rather than an empty result that would read as "searched, no
                // hits" for a pane that was never searched.
                guard let lines = pane.readScreenLines() else { return nil }
                return (
                    pane.paneID.rawValue,
                    pane.anchorTracker.anchor?.displayName ?? "baia",
                    lines
                )
            }
        }
    }

    /// Focuses the pane holding a match and scrolls it into view.
    ///
    /// The pane is looked up by id, and a match whose pane has closed since the
    /// search simply does nothing. That is the cost of holding ids rather than
    /// panes, and it is the cheaper of the two failures by a long way.
    private func go(to result: FindResult) {
        guard let (controller, pane) = paneNamed(result.paneID) else { return }
        controller.window.makeKeyAndOrderFront(nil)
        pane.takeFocus()
        updateWindowTitles()

        // No confirmed row means no scroll. The pane is focused either way, so
        // the owner still lands where the match was found, and the beep is the
        // only thing on screen that can say the jump did not happen: the panel
        // is already dismissed by the time this runs. Scrolling to an
        // unconfirmed estimate instead would move the viewport to output that
        // does not hold the match and say nothing at all.
        guard let row = pane.row(of: result.match, in: result.lines) else {
            NSSound.beep()
            return
        }
        pane.reveal(row: row, viewportRows: Self.viewportRowEstimate)
    }

    private func paneNamed(
        _ id: UUID
    ) -> (controller: WorkspaceWindowController, pane: TerminalPaneController)? {
        for controller in windows {
            if let pane = controller.tree.allPanes.first(where: { $0.paneID.rawValue == id }) {
                return (controller, pane)
            }
        }
        return nil
    }

    /// Rows to centre the match within. A fixed estimate rather than the pane's
    /// real row count, which `TerminalPaneController` does not track: being a
    /// few rows off moves the match within the viewport rather than out of it,
    /// and the row itself was already estimated.
    private static let viewportRowEstimate = 40

    /// Discards the cached project list and walks again, so a project created
    /// since launch shows up.
    @objc func reloadProjectList(_: Any?) {
        discoveredProjects = nil
        discoverProjects()
    }

    /// Walks the configured roots off the main thread and hands the result to
    /// the palette.
    ///
    /// Re-entrant by design: `isDiscovering` collapses the launch warm-up, the
    /// ⌘K that arrives before it finishes, and Reload Project List into one
    /// walk rather than three concurrent ones.
    private func discoverProjects() {
        guard discoveredProjects == nil, !isDiscovering else { return }
        isDiscovering = true

        let settings = configuration.settings
        let roots = settings.projectRoots.map {
            URL(filePath: $0, directoryHint: .isDirectory)
        }
        let maxDepth = settings.discoveryMaxDepth

        Task.detached(priority: .userInitiated) {
            let git = GitCommand()
            let discovery = ProjectDiscovery(
                roots: roots,
                maxDepth: maxDepth,
                ignoredNames: ProjectDiscovery.defaultIgnoredNames
            )
            // git names the worktrees rather than the walk finding them. They
            // are full file copies living inside the repository, so walking
            // into them triples the tree and reports the same files twice.
            let found = discovery.discover { git.worktrees(ofRepositoryRoot: $0) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                isDiscovering = false
                discoveredProjects = found
                palette.setProjects(found, recency: recentProjects.load())
            }
        }
    }

    /// Opens a project chosen in the palette.
    private func open(_ project: Project, action: PaletteAction) {
        let directory = project.url.path(percentEncoded: false)

        // Recorded before the open, so the ranking reflects the choice even if
        // the window fails to come up. False means the path could not be written
        // and costs a ranking hint, which is why it is not surfaced.
        _ = recentProjects.recordUse(of: directory)

        switch action {
        case .newTab:
            openWindow(
                tree: PaneTreeController(workingDirectory: directory, configuration: configuration),
                joining: focused?.window
            )
        case .splitRight:
            // Splits the focused pane and points the new one at the project. The
            // split has to happen first: the new pane does not exist until the
            // workspace has made it, and it opens at the focused pane's directory
            // by default rather than at the project's.
            tree?.splitFocusedPane(axis: .horizontal, workingDirectory: directory)
        }
        updateWindowTitles()
    }

    // MARK: - Title

    /// Retitles every window, because the waiting count is a property of the
    /// workspace rather than of one tab: a tab in the background that starts
    /// asking has to be visible from whichever tab is in front.
    private func updateWindowTitles() {
        // Named rather than counted. A count answers "how many", which nobody
        // asked; a name answers "which", which is the entire reason the marker
        // exists, since the signal it replaces was one identical sound per
        // session. It goes on every window because that is the one surface macOS
        // shows reliably for a background app: the Window menu, Mission Control
        // and the window switcher all read it. A dock badge would be the obvious
        // home and does not work here, see `AttentionNotifier`.
        //
        // Uniqued, because the list is one entry per waiting *pane*. Two panes
        // in the same repository, which is the ordinary shape of this workspace,
        // otherwise put `! vault ! vault` in the title. It happens here rather
        // than in `PaneTreeController` so two windows on one project collapse
        // too.
        var seen: Set<String> = []
        let waiting = windows
            .flatMap { $0.tree.waitingProjects }
            .filter { seen.insert($0).inserted }

        // One disambiguation pass across every window, so two tabs on the same
        // project name become `baia (Projects)` and `baia (sandbox)` rather than
        // two tabs nobody can tell apart. It has to see all of them at once,
        // which is why it happens here and not in a pane.
        let projects = TabTitle.disambiguated(windows.map { $0.tree.tabPath })

        for (controller, project) in zip(windows, projects) {
            // The budget comes from this window's own tab group rather than from
            // the app's window count. A detached window is not competing for
            // titlebar width with a group of six somewhere else.
            let siblings = controller.window.tabGroup?.windows.count ?? 1
            let tab = controller.tree.tabTitle(
                project: project,
                budget: TabTitle.Budget.forTabCount(siblings)
            )
            controller.window.title = TabTitle.windowTitle(waitingProjects: waiting, tab: tab)
            controller.window.subtitle = controller.tree.windowTitle.subtitle
        }
    }

    /// The project and message come from the pane that changed, not from the
    /// waiting list. Re-deriving them with `waitingProjects.last` named whichever
    /// pane sorted last and dropped the OSC 9 text the pane had already sent.
    /// Re-derives everything that is not a pane after the config file changes.
    /// The panes themselves are updated by the configuration center directly.
    private func settingsDidChange() {
        notifier.isEnabled = configuration.settings.notificationsEnabled
        // Dropped so the next palette walks the roots the file now names. The
        // walk is not started here: it would fire on every keystroke of an
        // editor holding the file open.
        discoveredProjects = nil
        for controller in windows {
            controller.tree.refreshTheme()
        }
        palette.theme = configuration.paneTheme
        find.theme = configuration.paneTheme
    }

    private func notifyIfUnfocused(
        _ controller: WorkspaceWindowController?,
        project: String,
        message: String?
    ) {
        guard let controller, controller.window.isKeyWindow != true else { return }
        // Only a pane that is actually asking earns a banner. The callback also
        // fires when attention *clears*, and notifying on that announced a pane
        // that had just gone quiet.
        guard controller.tree.waitingProjects.contains(project) else { return }
        notifier.notify(project: project, message: message)
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
        // Opt out entirely rather than restoring and discarding. Someone who
        // turns this off wants a clean window, not the old one rebuilt and
        // thrown away, which would spawn every recorded shell on the way past.
        guard configuration.settings.restoreSession else { return openFresh() }
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
                    defaultWorkingDirectory: Self.defaultWorkingDirectory,
                    configuration: configuration
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
            tree: PaneTreeController(
                workingDirectory: Self.defaultWorkingDirectory,
                configuration: configuration
            ),
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

    @objc func growPaneLeft(_: Any?) { tree?.resizeFocusedPane(.left) }

    @objc func growPaneRight(_: Any?) { tree?.resizeFocusedPane(.right) }

    @objc func growPaneUp(_: Any?) { tree?.resizeFocusedPane(.up) }

    @objc func growPaneDown(_: Any?) { tree?.resizeFocusedPane(.down) }

    @objc func equalizePanes(_: Any?) { tree?.equalizePanes() }

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
            // Enabled until the walk proves otherwise. `MenuValidation` wants
            // this to mean "there are projects to show", and the honest answer
            // needs a walk of every root, which cannot happen here: AppKit
            // revalidates on every menu open and on every key equivalent, so a
            // walk behind this property would stat the workspace continuously.
            // Nil means not yet discovered, and an optimistic answer costs at
            // worst one empty palette that corrects itself the moment it opens.
            paletteAvailable: discoveredProjects.map { !$0.isEmpty } ?? true
        )
    }
}
