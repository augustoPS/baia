import AgentIntegration
import AppKit
import BaiaSettings
import GitWorkspace
import PaneChrome
import PanePrompt
import ProjectAnchor
import WorkspaceLayout
import WorkspaceMenu

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Unordered, and deliberately so. Tab order lives in `window.tabGroup` and
    /// is read from there when a session is written. Keeping an ordered mirror
    /// here would drift the moment a tab is dragged out or windows are merged,
    /// and it would drift silently.
    private var windows: [WorkspaceWindowController] = []

    private let sessionStore = SessionStore(fileURL: SessionStore.defaultFileURL(directoryName: SupportDirectory.name))

    /// The config file, and everything derived from it. Created before any
    /// window, because a pane built before it exists would come up in
    /// libghostty's defaults.
    private lazy var configuration: ConfigurationCenter = {
        let center = ConfigurationCenter()
        center.onSettingsChange { [weak self] in self?.settingsDidChange() }
        return center
    }()

    private let notifier = AttentionNotifier()

    /// The control channel's socket, its pool, and its graph.
    ///
    /// Held whether or not it bound: an instance that found the socket already
    /// owned still answers `boundSocketPath` with nil, which is what tells a pane
    /// to inject no `BAIA_SOCK` rather than hand its shell the *first* instance's
    /// live socket.
    let control = ControlServer()

    /// The workspace end of the channel, held here because the server's reference
    /// to it is weak: the server is reached from the adapter's own windows, and two
    /// strong references would be a cycle that outlives every window.
    ///
    /// Built with closures over this delegate's own state rather than a reference
    /// to it, so the adapter can be read without knowing what an `AppDelegate` is
    /// and cannot reach anything but the window list, the key window, and the one
    /// door that opens a window.
    private lazy var controlAdapter = ControlAdapter(
        windows: { [weak self] in self?.windows ?? [] },
        openWindows: { [weak self] pieces in
            guard let self else { return }
            openWindows(restoring: pieces)
        }
    )

    private lazy var palette: CommandPaletteController = {
        let palette = CommandPaletteController()
        palette.theme = configuration.paneTheme
        // Read once at construction, the same as `theme` above; `settingsDidChange()`
        // keeps it current afterwards the way it already does for the sidebar.
        palette.resolvedChrome = configuration.resolvedChrome
        // Which fill that glass is tinted with, nil with nothing dialled and
        // kept current by `settingsDidChange()` the same way. See ``SurfaceFill``.
        palette.fillMaterial = configuration.chromeOverrides.surfaces.palette
        // The panel's own window appearance, from the same derivation the
        // workspace window's titlebar takes and the same one that now picks the
        // glass material set inside this panel. See
        // ``CommandPaletteController/isDark``.
        palette.isDark = configuration.windowIsDark
        palette.onOpen = { [weak self] project, action in
            self?.open(project, action: action)
        }
        palette.availableVerbs = { [weak self] in self?.paletteVerbs() ?? [] }
        palette.onRunVerb = { [weak self] tag in self?.runVerb(tag: tag) }
        return palette
    }()

    /// Every verb the palette can offer, available or not.
    ///
    /// Eligibility is `MenuValidation`'s answer and nothing else, which is the
    /// decision recorded in the palette spec: one source of truth for whether a
    /// command can be performed, rather than a second list beside it that can
    /// disagree. The cost is that always-enabled verbs nobody searches for
    /// (`Hide`, `Quit`, `Copy`) are in the list, and it was taken knowingly.
    ///
    /// **Disabled commands are included and carry their reason**, which is the
    /// correction the first look on screen produced. They were dropped at first,
    /// and `>eq` then returned nothing in a one-pane window: correct, since
    /// Equalize Panes wants two, and useless, because an absent verb reads as a
    /// mistyped one. A menu greys the item rather than removing it, and the
    /// palette now does the same.
    ///
    /// Rebuilt per call rather than cached. `availability` is a snapshot of what
    /// the app can do, and it changes with every split, tab and focus move; a
    /// list held across opens would offer Close Tab with one tab left.
    private func paletteVerbs() -> [PaletteVerb] {
        let state = availability
        return MenuCommand.allCases.compactMap { command in
            guard let title = MenuBarLayout.title(of: command) else { return nil }
            let itemState = MenuValidation.state(for: command, given: state)
            return PaletteVerb(
                title: title,
                shortcut: MenuBarLayout.shortcutText(of: command) ?? "",
                id: command.tag,
                unavailableReason: itemState.isEnabled ? nil : itemState.unavailableReason
            )
        }
    }

    /// Performs the verb the palette committed, recovered from its tag.
    ///
    /// The tag rather than the command itself, for the same reason
    /// `validateMenuItem` reads it: the palette is a surface and knows nothing
    /// about `MenuCommand`, so the integer is the whole of what crosses the
    /// boundary.
    private func runVerb(tag: Int) {
        guard let command = MenuCommand(tag: tag) else { return }
        guard let selector = MenuCommandSelectors.selector(for: command) else { return }
        // Through the responder chain rather than called directly, so a verb
        // reaches whatever `NSMenuItem` would have reached. A direct call here
        // would run against the delegate for commands the first responder owns.
        NSApp.sendAction(selector, to: nil, from: menuItem(for: command))
    }

    /// A stand-in item carrying the command's tag, so an action that reads the
    /// sender's tag (as several do) finds the command it was asked for.
    private func menuItem(for command: MenuCommand) -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = command.tag
        return item
    }

    /// The ⌘F panel. Built once and reused, like the palette, because a panel
    /// rebuilt per invocation would rebuild its window on a keystroke.
    private lazy var find: FindPanelController = {
        let find = FindPanelController()
        find.theme = configuration.paneTheme
        find.onCollect = { [weak self] scope in self?.panesToSearch(scope) ?? [] }
        find.onGo = { [weak self] result in self?.go(to: result) }
        return find
    }()

    #if DEBUG
        /// The debug design panel.
        ///
        /// **`lazy var` is the enforcement, not a convenience.**
        /// `ConfigurationCenter.onSettingsChange` has no unregister, and the panel
        /// registers in its own `init`, so a second instance would be a second
        /// permanent handler and a second window writing the same
        /// `designOverrides`. A `lazy var` is created once and never rebuilt —
        /// unlike `settingsWindow`, which is deliberately rebuilt per ⌘, and which
        /// is the consumer whose dead handler entries that doc comment accounts
        /// for. See ``DesignPanelController``.
        private lazy var designPanel = DesignPanelController(center: configuration)

        /// ⌃⌘D, from the `#if DEBUG` Debug menu `MainMenu` appends.
        @objc func toggleDesignPanel(_: Any?) {
            designPanel.toggle()
        }

        /// Opens the panel at launch when `BAIA_DESIGN_PANEL=1` is in the
        /// environment, so a dialing session never has to touch the menu bar.
        ///
        /// The route around, not the fix: on macOS 26A5388g the menu bar
        /// renders in-process through SwiftUI, and its gesture-activation and
        /// dismissal-cleanup renders crash in
        /// `swift_task_isMainExecutorImpl` (a garbage executor identity;
        /// every crashing stack is Apple frames). Dropping the debug dylib
        /// (`ENABLE_DEBUG_DYLIB: NO`, project.yml) cured the click-to-open
        /// path, but the deferred cleanup render after any menu engagement
        /// still dies on the next event. Until a seed fixes it, the panel's
        /// menu item stays for the day that happens; this env hook is how a
        /// dialing session actually starts. `BAIA_DESIGN_PANEL=1 make run`.
        func openDesignPanelIfRequested() {
            if ProcessInfo.processInfo.environment["BAIA_DESIGN_PANEL"] == "1" {
                designPanel.toggle()
            }
        }
    #endif

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

    private let recentProjects = RecentProjects(fileURL: RecentProjects.defaultFileURL(directoryName: SupportDirectory.name))

    /// Coalesces the writes. Every `cd` in every pane reports a session change
    /// through the one-second anchor poll, so writing on each one would rewrite
    /// the file several times a second for a workspace nobody is restructuring.
    private var saveTimer: Timer?

    /// Cleared during teardown so the flush at termination cannot be followed by
    /// an empty snapshot that overwrites a good file with nothing.
    private var isTerminating = false

    /// Carries the last workspace across the moment it stops existing.
    ///
    /// The window list empties before the terminate flush runs, so without this a
    /// write coalesced in the final second is flushed against nothing. The rule
    /// itself is in ``SessionFlush``, where a test can reach it.
    private var flush = SessionFlush()

    func applicationDidFinishLaunching(_: Notification) {
        MainMenu.install(into: NSApp)
        PaneAnchorTracker.removeLegacyPin()
        // Authorization is requested regardless of the setting, so turning
        // notifications back on later does not need a relaunch to get the
        // prompt. Only `notify` is gated.
        notifier.requestAuthorizationIfNeeded()
        notifier.isEnabled = configuration.settings.notificationsEnabled
        // Before the first pane exists, because a pane opened by the restore
        // below has to be told where to talk while it is being built.
        startControlChannel()

        restoreSession()
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
            openDesignPanelIfRequested()
        #endif
        scheduleSave()
        installKeyMonitor()
        // Warmed here so the first ⌘K of a session opens on a full list rather
        // than on an empty one that fills in a moment later.
        discoverProjects()
        noticeOutdatedHook()
    }

    /// One line on stderr when an installed agent hook is older than this build.
    ///
    /// **One line, and nothing else.** Not a dialog: a modal at launch about a
    /// hook the owner may have installed months ago is the wrong weight for an app
    /// whose whole chrome argument is that a pane must not be interrupted. Not a
    /// notification either, because that surface is for panes asking for their
    /// owner and this is not that.
    ///
    /// **Silent when the file is absent.** Not installing is not a problem, and an
    /// app that nagged about an integration nobody asked for would be answering a
    /// question nobody put.
    private func noticeOutdatedHook() {
        let layout = HookInstaller.Layout.standard(home: HookInstaller.Layout.home())
        guard let text = try? String(contentsOf: layout.script, encoding: .utf8) else { return }
        guard ManagedHeader.isOutdated(text) else { return }
        let installed = ManagedHeader.version(in: text).map(String.init) ?? "unknown"
        FileHandle.standardError.write(Data(
            ("baia: the agent hook at \(layout.script.path) is version \(installed) and this build "
                + "ships \(ManagedHeader.currentVersion). Run `baia install-hooks` to update it.\n").utf8
        ))
    }

    /// Binds the control socket, and says on stderr what happened either way.
    ///
    /// A failure here is not a launch failure. baia is a terminal first, and an
    /// instance with no channel is a working workspace whose panes are told there
    /// is nothing to talk to, which the CLI reports in one sentence.
    private func startControlChannel() {
        // Through the same call the reload path uses, so startup and reload
        // cannot drift. The previous two direct writes never seeded
        // `isReadAllowed`, and `controlAllowRead: false` was ignored until the
        // first real settings change: the server's default happened to match
        // the settings default, so the gap was invisible until audited.
        control.settingsChanged(
            channelEnabled: configuration.settings.controlChannelEnabled,
            allowRun: configuration.settings.controlAllowRun,
            allowRead: configuration.settings.controlAllowRead
        )
        // Attached before the socket is bound, so the first request cannot arrive
        // at a server with no workspace to apply it to.
        control.bridge = controlAdapter

        switch control.start() {
        case .bound:
            break
        case let .ownedByAnotherInstance(path):
            report("another baia already owns \(path), so this one runs without a control channel")
        case let .failed(reason):
            report("the control channel did not start: \(reason)")
        }
    }

    private func report(_ message: String) {
        FileHandle.standardError.write(Data("baia: \(message)\n".utf8))
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
        // After the save, and last of all: every parked `recv` is answered with
        // an empty drain here, and a client that got a bare EOF instead would
        // report the app as broken on the one exit that is not.
        control.stop()
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

    /// The sidebar this window opens with, or none.
    ///
    /// Read once per window rather than watched, because a window that gains or
    /// loses its sidebar changes what its content view *is*, and swapping that under
    /// a live tree would reparent every ghostty surface. That is the reparenting the
    /// theme refresh was rewritten to avoid: it resizes every grid and signals every
    /// process, for a setting change. Switching between contents afterwards is a
    /// different thing and costs nothing, which is what ``SidebarHost/show(_:)`` is.
    private func sidebar(for tree: PaneTreeController) -> SidebarHost {
        let content = configuration.settings.sidebar
        let host = SidebarHost(
            tree: tree,
            surfaces: surfaces(for: content, tree: tree),
            theme: configuration.paneTheme,
            // The composed value, not the committed one, so a dialled opacity
            // reaches the column rather than only the wells — the shape every
            // neighbour here reads. In Release `effectiveSettings` *is*
            // `settings`. It reaches the surface and, since the wash retired
            // on 2026-08-08, nothing else under glass.
            backgroundOpacity: configuration.effectiveSettings.backgroundOpacity,
            resolvedChrome: configuration.resolvedChrome
        )
        // Which fill this column's glass is tinted with, nil with nothing
        // dialled. See ``SurfaceFill``.
        host.fillMaterial = configuration.chromeOverrides.surfaces.sidebar
        // A `MenuBarLayout.shortcutText(of: .newTab)` lookup stood here until
        // 2026-08-12, pushing the bar's own binding into the action row's
        // keycap so the row could not advertise a key its click did not
        // perform. The owner's ruling that day removed the row on exactly what
        // that lookup was evidence of: a button that has to ask the menu what it
        // is called is the menu's command wearing a second face. `.newTab` keeps
        // its item and its `⌘T`.
        return host
    }

    /// The surface for a content, built fresh, or nil.
    ///
    /// One surface or none since 2026-08-12. The column used to stack a CHANGES
    /// surface above this tree, and the owner's ruling that day removed it: the
    /// capsule's changes card already lists the changed files with their status
    /// letters and hands each one to a diff split, so it was a second copy of
    /// the same list in the same window. Task 6 made that "one or none" the
    /// type rather than an invariant on a list: the column's surface is a
    /// plain `FilesSurface?`, with no shared interface left for it to satisfy.
    private func surfaces(
        for content: SidebarContent,
        tree: PaneTreeController
    ) -> FilesSurface? {
        switch content {
        // Off is an empty column rather than a missing one. The host stays the
        // window's content view either way, so nothing is ever reparented.
        case .off: return nil
        case .files: break
        }
        let files = FilesSurface()
        // `weak tree` is not decoration. The surface is held by the sidebar
        // host, which is held by the window controller, which holds the tree, so a
        // strong capture here is a cycle that outlives the close. The `onClose`
        // comment below records what that class of cycle already cost once: a
        // leaked controller keeps every pane and every live shell under it alive
        // with no window to reach them.
        // False when the window has gone: a click that reaches nothing is a
        // refusal from the row's point of view, which is the honest thing to draw.
        files.onSelect = { [weak self, weak tree] path in
            guard let self, let tree else { return false }
            return sendToPrompt(path, of: tree)
        }
        files.onInitialise = { [weak self, weak tree] in
            guard let self, let tree else { return }
            offerInit(of: tree)
        }
        return files
    }

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
        let controller = WorkspaceWindowController(
            tree: tree,
            sidebar: sidebar(for: tree),
            // Not the chrome the sidebar just took: window transparency follows
            // `backgroundOpacity` rather than `chromeStyle` (owner decision,
            // 2026-08-07). It has to reach the window and not only the column in
            // it, because the sidebar's glass samples what is behind its
            // *window*, so a transparent backing over an opaque window lenses
            // this app's own fill. See
            // ``WorkspaceWindowController/isTransparent``.
            isTransparent: configuration.windowIsTransparent,
            // Stored now, applied by `show(joining:)` a few lines below, because
            // the SPI behind it needs a `windowNumber` the window server has not
            // issued yet. See ``WorkspaceWindowController/blurRadius``.
            blurRadius: configuration.windowBlurRadius,
            // Titlebar should follow the pane's appearance (owner request,
            // 2026-08-07): the theme's own background decides light/dark for
            // this window's chrome, never the system appearance. See
            // ``WorkspaceWindowController/isDark`` and
            // ``PaneChrome/windowIsDark(paneTheme:)``.
            isDark: configuration.windowIsDark,
            // The titlebar's own treatment, and the one window property here
            // that follows `chromeStyle` rather than `backgroundOpacity`: a
            // glass view is chrome. Under flat this window keeps the system
            // titlebar `78aadfe` shipped. See
            // ``WorkspaceWindowController/resolvedChrome``.
            resolvedChrome: configuration.resolvedChrome,
            // **`theme` is back, for a different surface than the one it left.**
            // It was passed here until 2026-08-08 for the titlebar *wash*, which
            // retired on the owner's naked-glass ruling; the band's material is
            // still untinted and no palette feeds it. What needs the theme now is
            // the icon and path the 2026-08-13 ruling put in the band — glyph and
            // text drawn in ``PaneTheme/inkFaint``, not a fill. Passed at
            // construction rather than assigned after, so a new window never
            // shows one frame in the wrong ink.
            theme: configuration.paneTheme
        )
        // Which fill the titlebar band's glass is tinted with, nil with nothing
        // dialled and live-followed by `settingsDidChange()`. See ``SurfaceFill``.
        controller.fillMaterial = configuration.chromeOverrides.surfaces.titlebar
        controller.window.tabbingMode = tabbing
        // Coalesced by the same timer every other session change goes through, so a
        // drag writes the file once when it settles rather than on every frame.
        controller.sidebar.onGeometryChange = { [weak self] in self?.scheduleSave() }
        // The sidebar's own "New session" row was wired here until 2026-08-12,
        // to the same shape as ``newTab(_:)``: open where the focused pane
        // already is, joining a window. The owner's ruling that day removed the
        // row as a second face for the `New Tab` item it read its own keycap
        // off, and ``newTab(_:)`` is the surviving path.
        //
        // The one thing the closure did that the menu item does not is worth
        // recording rather than mourning: it captured `controller`/`tree` rather
        // than reading `self.focused`, so a click in a *background* window's
        // sidebar opened a tab on that window instead of on the focused one.
        // With the row gone there is no click in a background window's chrome to
        // route, ``newTab(_:)`` arriving from the menu or from `⌘T` and the
        // focused window being the only window either can mean.
        windows.append(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            // Before anything is torn down, and only for the last window: once it
            // leaves `windows` there is nothing left to snapshot, and the flush at
            // termination arrives after that. A change made in the final second is
            // scheduled, coalesced, and then flushed against an empty workspace,
            // so this is where it has to be caught.
            if windows.count == 1 {
                flush.hold(snapshot())
            }
            // Before the reference goes, because the tree is the only thing that
            // knows which panes went with the window. A registration that outlived
            // its shell is a token that still works against a pane nobody can see.
            controller.tree.forgetEveryPane()
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
        // `weak controller` here for the reason spelled out below, which this line
        // did not follow. The closure is stored on the controller and captured it
        // strongly, so every window was in a retain cycle with itself: `onClose`
        // dropped our reference and nothing else did, the controller never
        // deallocated, and neither did its tree, its panes, or the terminal views
        // holding the ptys. Closing a tab left its shell running, which is exactly
        // the failure the comment under `onAttentionChange` describes.
        //
        // Measured before and after: a window with two tabs has two direct child
        // processes, closing one left two, and now leaves one.
        controller.onFocusedPaneChange = { [weak self, weak controller] in
            guard let self, let controller else { return }
            updateWindowTitles()
            refreshSidebar(of: controller)
        }
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
        // The sidebar opens empty otherwise, and stays empty until something
        // *changes*: `refreshSidebar(of:)` is reached only from
        // `onFocusedPaneChange`, so a window whose pane sits still in a settled
        // repository showed nothing at all. The pane's anchor may not have
        // resolved yet at this point, which costs nothing: the resolution fires
        // `onAnchorChange` and lands here again.
        refreshSidebar(of: controller)
        return controller
    }

    /// Held so the window survives being shown. An `NSWindowController` created
    /// inside the action and not retained is released before it can appear.
    private var settingsWindow: SettingsWindowController?

    @objc func showSettings(_: Any?) {
        // Rebuilt rather than reused, because `SettingsDraft` snapshots the
        // committed settings at init. A controller kept from last time would open
        // showing whatever was in effect then, which after one accept is stale.
        settingsWindow?.close()
        let controller = SettingsWindowController(center: configuration)
        settingsWindow = controller
        controller.showWindow(nil)
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func newTab(_: Any?) {
        // The new tab opens where the focused pane is, not at the workspace root.
        // Opening a tab is usually a second view of the project already in front.
        let directory = tree?.focusedPane?.anchorTracker.workingDirectory?
            .path(percentEncoded: false) ?? Self.defaultWorkingDirectory
        openWindow(
            tree: PaneTreeController(
                workingDirectory: directory,
                configuration: configuration,
                channel: control
            ),
            joining: focused?.window
        )
    }

    @objc func newWorkspaceWindow(_: Any?) {
        // Detached on purpose: New Window means a window, and joining the group
        // would make it indistinguishable from New Tab.
        openWindow(
            tree: PaneTreeController(
                workingDirectory: Self.defaultWorkingDirectory,
                configuration: configuration,
                channel: control
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

    /// Returns the sidebar to the size it ships with.
    ///
    /// Every window, unlike Switch Sidebar, because the geometry is session-level: a
    /// reset that left the other tabs at a dragged width would put the file and the
    /// screen into two different states, and the next save would pick one of them
    /// arbitrarily.
    @objc func resetSidebarSize(_: Any?) {
        for controller in windows { controller.sidebar.geometry = .default }
        scheduleSave()
    }

    /// Opens the sidebar on the file tree, or closes it.
    ///
    /// This window's and not every window's: the column describes the focused
    /// pane's repository, so switching a background tab's from the front one
    /// would change a surface nobody is looking at.
    ///
    /// **A toggle since 2026-08-12, and a four-state cycle before it.** It used
    /// to walk `off → changes → files → both → off`, matched against the surface
    /// titles the column was showing. The owner's ruling that day removed the
    /// CHANGES surface, which left two states, and a cycle through two states is
    /// a toggle. Reading whether the column holds a surface rather than matching
    /// titles follows from that: with one surface left there is no title worth
    /// matching, and the string match was the arm that broke silently whenever a
    /// title moved.
    @objc func toggleSurfacePanels(_: Any?) {
        guard let window = focused ?? windows.first else { return }
        let next: SidebarContent = window.sidebar.files == nil ? .files : .off
        // The window's own tree, not the focused one: this rebuilds the surfaces
        // of one window, and a click in them has to reach that window's panes.
        window.sidebar.show(surfaces(for: next, tree: window.tree))
        refreshSidebar(of: window)
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
                tree: PaneTreeController(
                    workingDirectory: directory,
                    configuration: configuration,
                    channel: control
                ),
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
    /// Re-points the sidebar at the focused pane and redraws from what that pane
    /// already holds.
    ///
    /// **Zero `git` invocations, by construction.** `PaneGitStatus` polls per pane
    /// and keeps its last answer, so this reads a value that is already in memory.
    /// Starting a read here instead would fork git on every click and every
    /// ⌥⌘arrow, which is several times a second while someone arrows across a grid.
    ///
    /// A pane with no repository is told so rather than shown an empty list, because
    /// "nothing changed" and "not a repository" are different answers.
    private func refreshSidebar(of controller: WorkspaceWindowController) {
        let pane = controller.tree.focusedPane
        let anchor = pane?.anchorTracker.anchor
        // The repository root, and nil outside one: git lists a repository's
        // files and a plain directory is walked instead.
        let root = anchor?.kind == .repository ? anchor?.url : nil

        // The anchor's own path, not the working directory: the absent state is
        // answering for what the section is pointed at.
        let anchorPath = anchor?.url.path(percentEncoded: false)

        // The CHANGES surface was fed here too until 2026-08-12, from
        // `gitStatus.changes` and `gitStatus.stats`. The owner's ruling that day
        // removed it. `files.changes` below is not what went: the tree's own
        // per-file dirty marks are the tree's annotation on a row it was already
        // drawing, not a second list of changed files.
        if let files = controller.sidebar.files {
            // Inside a repository git lists the files; outside one the
            // directory is walked. The mode follows the anchor rather than a
            // control, because repo-or-local has one right answer at any
            // moment and it is a fact about the pane, not a preference.
            //
            // `Anchor.Kind` has said as much all along: a plain anchor exists
            // "so a file tree always has a root". Until now this discarded it.
            //
            // **And the column was told a boolean that discarded it too**,
            // which is the bug the owner's 2026-08-12 ruling on the `git init`
            // offer exposed. `files.hasRoot = anchor != nil` was assigned
            // here, and a plain directory resolves an anchor perfectly well,
            // so the surface could not tell a walked tree from a listed one:
            // the offer keyed on that boolean appeared only when nothing
            // resolved at all. The three cases this branch already
            // distinguishes are now the three cases the surface is told, so
            // the state the column draws from is the state this decides.
            switch anchor?.kind {
            case .repository: files.listing = .repository
            case .plain: files.listing = .directory
            case nil: files.listing = .absent
            }
            if let root {
                // Optional because the cache can miss: the read is async and a
                // first refresh arrives before it lands.
                files.tree = fileTrees.tree(for: root) ?? []
                readFileTree(at: root)
            } else if let plain = anchor?.url {
                files.tree = DirectoryTree.tree(at: plain)
            } else {
                files.tree = []
            }
            files.changes = pane?.gitStatus.changes ?? []
            files.anchorPath = anchorPath
        }
        controller.sidebar.anchorName = anchor?.displayName
        // `sidebar.sessionStatus` was pushed here too until 2026-08-12, feeding
        // the session header row its anchor name, branch and status word off
        // the same `PaneStatus` the pane's own footer draws from. The owner's
        // ruling that day removed the row as a fourth copy of what the window
        // title, the prompt and the capsule already say, and the pane's status
        // reaches this column through none of them now.
    }

    /// Puts a clicked path on the focused pane's prompt.
    ///
    /// **The focused pane of the sidebar's own window**, which is the pane the
    /// sidebar is already showing: it is repointed by ``refreshSidebar(of:)`` on
    /// every focus change. With no focused pane a click does nothing and says
    /// nothing, the one silent no-op here, because there is no pane for feedback
    /// to belong to.
    ///
    /// Every decision about the bytes belongs to ``PromptPath`` and none to this
    /// function, which reads three values and passes the answer on. A refusal is
    /// the untrusted-filename case: the tree is filled from `git ls-files` over
    /// whatever repository the pane is anchored to, and a name carrying a control
    /// byte would drive zsh's line editor rather than land on the prompt line.
    ///
    /// **Answers whether the path landed**, which is the one bit the row needs to
    /// draw the right flash. Design v3 §2.3 gives a refusal `alert` on the row and
    /// in the path's own ink, and gives a landing the pressed fill released and
    /// nothing more: zsh already brackets the inserted path on the prompt line,
    /// and a second announcement in the column would be the app saying the same
    /// thing twice.
    ///
    /// The beep stays. It is the half of the answer that survives the pointer
    /// having moved on, and the drawn half is what it was missing.
    ///
    /// A click with no focused pane is `false` without a beep: there is no pane
    /// for the feedback to belong to, so the row flashes a refusal and nothing
    /// sounds. That is the one silent no-op here.
    @discardableResult
    private func sendToPrompt(_ path: RepositoryPath, of tree: PaneTreeController) -> Bool {
        guard let pane = tree.focusedPane else { return false }
        // **Resolved against any anchor, sent only from a repository.** The two
        // roots and the argument for keeping them apart live in
        // ``ProjectAnchor/Anchor/refusalRoot(of:)``, where a test can reach them.
        // This guard read `kind == .repository` until 2026-08-13 and returned
        // *before* ``PromptPath/resolve`` ran, so a row a shell could not hold was
        // refused with no reason and `showNotice` was never asked for. Resolving
        // first is what recovers the reason; `promptRoot` below is what keeps a
        // bare shell pane send-inert, which is the owner's ruling and not a
        // consequence of where the guard sits.
        guard let root = Anchor.refusalRoot(of: pane.anchorTracker.anchor) else {
            return false
        }

        // **Both directories through the same resolution, or they never match.**
        // `ProcessWorkingDirectory` asks the kernel, which answers with a fully
        // resolved path (`/private/var/folders/...`), while the anchor's root has
        // been through `resolvingSymlinksInPath()` in `GitRepositoryLocator`,
        // which on macOS *strips* a leading `/private` when the result exists. The
        // two spellings of one directory then share no prefix, so a repository
        // under `$TMPDIR`, `/tmp` or `/var` sent every path absolute: caught on
        // 2026-07-29 by the fixture, which lives in exactly that place.
        switch PromptPath.resolve(
            repositoryRelativePath: path.bytes,
            repositoryRoot: root.resolvingSymlinksInPath().path(percentEncoded: false),
            workingDirectory: pane.anchorTracker.workingDirectory?
                .resolvingSymlinksInPath().path(percentEncoded: false)
        ) {
        case let .send(bytes):
            // **The pane's affordance, asked after the path is known to be
            // sendable.** A bare shell pane resolves its rows so a refusal can name
            // itself, and stops here: nothing reaches its prompt. The row still
            // flashes, because the click was declined either way.
            guard Anchor.promptRoot(of: pane.anchorTracker.anchor) != nil else {
                return false
            }
            pane.send(bytes)
            return true
        case let .refuse(reason):
            // The beep says a click was refused and never which one or why, and
            // the row's red flash says the same thing twice. The capsule carries
            // the reason, which is the half that lets the owner act: every
            // message names the fix. Both are kept, because the sound is what
            // survives the pointer having moved on.
            pane.showNotice(reason.notice)
            NSSound.beep()
            return false
        }
    }

    /// Puts `git init` on the focused pane's prompt, for the owner to run or to
    /// clear.
    ///
    /// The owner's 2026-08-12 ruling, option E: the no-repository state gets an
    /// action that resolves it rather than a message naming a dead end, the way
    /// kero offers Initialize Repository.
    ///
    /// **It does not run git, and that is the design rather than a shortcut.**
    /// `git init` writes a `.git` directory into a real directory on the owner's
    /// filesystem, so the question is not whether the app *can* spawn it but what
    /// happens when the click was a mistake. Three properties make this safe, and
    /// they are the ones the sidebar already had rather than a new mechanism:
    ///
    /// 1. **No newline is ever sent.** `PromptPath` established the rule for the
    ///    file rows — a newline executes whatever is on the prompt line, so a
    ///    click would run a command nobody read — and this obeys it. The command
    ///    lands on the line, the cursor sits after it, and the owner presses
    ///    Return or `⌃C`. The gesture that mutates the filesystem is the owner's
    ///    keystroke, which is exactly where it was before this button existed.
    /// 2. **The caption is the command.** ``SurfaceMessage/initCaption`` draws the
    ///    literal `git init`, so what is read before the click and what appears
    ///    after it are the same string. Nothing is composed out of sight.
    /// 3. **Where it runs is the pane's own working directory**, which the prompt
    ///    line already shows and the capsule already names. No path is
    ///    interpolated here — the command carries none — so there is no spelling
    ///    of a directory for this to get wrong, which is the whole class of bug
    ///    `sendToPrompt` needs its symlink resolution for.
    ///
    /// Nothing is spawned at draw time either: this runs from a `mouseUp` on the
    /// button and from nowhere else.
    ///
    /// Silent with no focused pane, like `sendToPrompt`'s own no-pane case: there
    /// is no prompt to write on, and there is no row here to flash a refusal.
    private func offerInit(of tree: PaneTreeController) {
        guard let pane = tree.focusedPane else { return }
        pane.send(Array(SurfaceMessage.initCaption.utf8))
    }

    /// Every repository's file tree, once read.
    ///
    /// The rule lives in `GitWorkspace` rather than here, because it is the rule the
    /// sidebar's cost rests on and it is testable there without a window: reading a
    /// tree is a `git ls-files` over the whole repository, and focus moves several
    /// times a second while someone arrows across a grid. See ``FileTreeCache``.
    private var fileTrees = FileTreeCache()

    /// Reads a repository's tree once and pushes it into whatever is showing it.
    ///
    /// Deliberately not on the git poll. The status read is on a two second timer per
    /// pane and this is not: a tree is re-read when the sidebar first needs it and
    /// then left alone, because paying `ls-files` every two seconds per pane is a
    /// cost with no question behind it.
    private func readFileTree(at root: URL) {
        // Claiming is what starts the read, so two focus changes in one turn cannot
        // both be told yes. The check and the claim are one call for that reason.
        guard fileTrees.claimRead(of: root) else { return }
        let command = GitCommand()
        DispatchQueue.global(qos: .userInitiated).async {
            let tree = command.files(ofRepositoryRoot: root)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if tree.isEmpty {
                        // Nothing to store, and the root is released rather than
                        // recorded as empty: a repository mid-clone resolves itself,
                        // and a cache that never retried would need a relaunch.
                        self.fileTrees.forget(root)
                    } else {
                        self.fileTrees.store(tree, for: root)
                    }
                    // Pushed into every window, because the same repository can be
                    // open in more than one and each of them is waiting on this.
                    for controller in self.windows { self.refreshSidebar(of: controller) }
                }
            }
        }
    }

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
            // **Still the joined grammar, and the band no longer draws it.** The
            // 2026-08-13 ruling took the folder name out of the *titlebar*, and
            // `WorkspaceWindowController` does that with `titleVisibility`
            // rather than by emptying this string, because the native tab bar
            // labels each tab from `window.title` and blanking it here would
            // leave a bar of unlabelled tabs. The comment on that flag carries
            // the probe. So this line is unchanged: the name still reaches the
            // tab bar, the Window menu and the switcher, and only the band stops
            // showing it.
            controller.window.title = TabTitle.windowTitle(waitingProjects: waiting, tab: tab)

            // The subtitle goes with it — `titleVisibility` hides both — so the
            // path is written to the accessory that replaced it. Left assigned
            // as well rather than dropped: it is what the Window menu and the
            // accessibility string read for a window nobody is looking at, which
            // is the same reason the announcement is in the title at all.
            controller.window.subtitle = controller.tree.windowTitle.subtitle
            controller.titlebarPath.path = controller.tree.windowTitle.subtitle
        }
    }

    /// The project and message come from the pane that changed, not from the
    /// waiting list. Re-deriving them with `waitingProjects.last` named whichever
    /// pane sorted last and dropped the OSC 9 text the pane had already sent.
    /// Re-derives everything that is not a pane after the config file changes.
    /// The panes themselves are updated by the configuration center directly.
    private func settingsDidChange() {
        notifier.isEnabled = configuration.settings.notificationsEnabled
        control.settingsChanged(
            channelEnabled: configuration.settings.controlChannelEnabled,
            allowRun: configuration.settings.controlAllowRun,
            allowRead: configuration.settings.controlAllowRead
        )
        // Dropped so the next palette walks the roots the file now names. The
        // walk is not started here: it would fire on every keystroke of an
        // editor holding the file open.
        discoveredProjects = nil
        for controller in windows {
            controller.tree.refreshTheme()
            // The sidebar too, which this loop did not reach: a theme or an opacity
            // edited under a running app repainted every pane and left the column
            // beside them wearing the values the window was built with, until it
            // was closed and opened again.
            controller.sidebar.theme = configuration.paneTheme
            // And the titlebar's icon and path, which are inked from the same
            // theme and were the surface this loop did not reach — the bug the
            // sidebar line above was added to fix, one surface further up.
            controller.titlebarPath.theme = configuration.paneTheme
            // Composed, not committed: the design panel writes through
            // `designOverrides`, which fires exactly this handler, so a read of
            // `settings` here would take the dial's redraw and paint the value
            // the dial was moved *off*.
            controller.sidebar.backgroundOpacity = configuration.effectiveSettings.backgroundOpacity
            controller.sidebar.fillMaterial = configuration.chromeOverrides.surfaces.sidebar
            // `resolvedChrome` is read fresh from `configuration` the same way
            // `apply(to:)` reads it for a pane (Task 4): a dark/light or Reduce
            // Transparency change reaches `onSettingsChange` through the same
            // observer closure this loop is called from, so the sidebar's own
            // material follows it here rather than waiting for an unrelated
            // settings-file edit to force a reload.
            controller.sidebar.resolvedChrome = configuration.resolvedChrome
            // The window under that sidebar, which is what the sidebar's glass
            // actually samples through. Reads `windowIsTransparent` rather than
            // the `resolvedChrome` on the line above, because an edit to
            // `backgroundOpacity` alone moves this and leaves the chrome where
            // it was. Live-following is safe here in a way the pane arrangement
            // deliberately is not: `refreshTheme()` and `apply(to:)` keep a
            // running pane on the padding it spawned with because moving it is a
            // live grid resize and a `SIGWINCH`, whereas a window's
            // `isOpaque`/`backgroundColor` feed no layout at all. See
            // ``WorkspaceWindowController/isTransparent``.
            controller.isTransparent = configuration.windowIsTransparent
            // And the blur behind it, on the same live path and for the same
            // reason: `backgroundBlur` and `backgroundOpacity` are both settings
            // the owner edits under a running app, and a window left on the
            // radius it opened with would need closing and reopening to follow.
            // Safe to write directly here, unlike at construction: this loop only
            // ever reaches windows that have been shown, so the `windowNumber`
            // the SPI needs already exists.
            controller.blurRadius = configuration.windowBlurRadius
            // Titlebar follows the pane's appearance live, the same way the
            // sidebar's `resolvedChrome` line above does: a theme edit reaches
            // this loop through the same `onSettingsChange` callback, so the
            // titlebar moves with the theme rather than waiting for the window
            // to be closed and reopened. See
            // ``WorkspaceWindowController/isDark``.
            controller.isDark = configuration.windowIsDark
            // The titlebar's glass, live-followed the same way: `chromeStyle`
            // decides whether the band is glass at all and the owner changes it
            // with windows open. The controller's own `didSet` makes this a
            // no-op when the value has not moved. The theme and the opacity
            // were written here too until 2026-08-08, for the wash that retired
            // that day; the band is the bare material now and follows neither.
            controller.resolvedChrome = configuration.resolvedChrome
            // And the titlebar band's own glass tint, on the same live path.
            controller.fillMaterial = configuration.chromeOverrides.surfaces.titlebar
        }
        palette.theme = configuration.paneTheme
        // Same live-follow as the sidebar's own line above; the find panel is
        // deliberately not given `resolvedChrome` here; it shares the palette's
        // view types but was never asked for the glass restyle and stays flat.
        palette.resolvedChrome = configuration.resolvedChrome
        palette.fillMaterial = configuration.chromeOverrides.surfaces.palette
        // The palette's own window appearance, live-followed on this same loop
        // rather than through a separate `onSettingsChange` registration. This
        // method *is* the registered handler for everything the delegate owns
        // (the windows, the sidebars, the palette's theme and chrome), so a
        // second registration would run the same work at a second point in
        // the same notification with no ordering guarantee between them —
        // exactly what `onSettingsChange`'s own doc comment says no consumer
        // may depend on. It also keeps every panel property the delegate
        // writes visible in one place.
        //
        // Reads `windowIsDark`, so a theme edit moves the panel's appearance in
        // the same frame it moves its glass material and the panes' ink; a
        // system light/dark switch with the theme unmoved moves neither. The
        // find panel is left out here for the same reason it is left out of the
        // `resolvedChrome` line above: its flat exemption stands.
        palette.isDark = configuration.windowIsDark
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
        guard !isTerminating else { return }
        // Nil for "no window left to snapshot", which is the case ``SessionFlush``
        // answers: it hands back what the last window held on its way out, once,
        // and nil after that so an empty workspace still cannot overwrite a good
        // file.
        guard let snapshot = flush.resolve(live: windows.isEmpty ? nil : snapshot()) else { return }
        _ = sessionStore.save(snapshot)
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
            windowFrame: focused?.frame,
            // The focused window's, for the reason its frame is the one recorded:
            // the snapshot carries one of each, and the window being looked at is
            // the one whose size the owner just settled.
            sidebar: focused?.sidebar.geometry,
            fileTreeExpansions: fileTreeExpansions()
        )
    }

    /// Every window's open directories, merged into the one map the file holds.
    ///
    /// Merged rather than taken from the focused window alone, which is what
    /// `sidebar` above does, because the two fields are different shapes. A
    /// sidebar width is one number and two windows disagreeing about it means one
    /// of them has to lose. This map is keyed by anchor, so two windows on two
    /// repositories hold two disjoint halves of it, and writing one window's would
    /// forget the other's on every quit.
    ///
    /// The focused window merges last, so an anchor two windows both visited keeps
    /// the tree the owner was last looking at.
    private func fileTreeExpansions() -> [String: [String]] {
        var merged: [String: [String]] = [:]
        for controller in windows where controller !== focused {
            merged.merge(controller.sidebar.fileTreeExpansions) { _, later in later }
        }
        if let focused {
            merged.merge(focused.sidebar.fileTreeExpansions) { _, later in later }
        }
        return merged
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
        let resolver = AnchorResolver()
        let (reconciled, _) = SessionStore.reconciled(
            snapshot,
            directoryExists: { path in
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                return exists && isDirectory.boolValue
            },
            // The same resolver, asked the same question, as the one that points
            // the sidebar in `refreshSidebar(of:)`, and the same
            // `url.path(percentEncoded:)` spelling of the answer. That is not a
            // coincidence to be tidied away later: the expansions are keyed by
            // whatever string that call produces, so anything else here prunes
            // against keys the surface never writes and silently empties the map.
            resolveAnchor: { pane in
                resolver.resolve(
                    workingDirectory: pane.workingDirectory.map {
                        URL(filePath: $0, directoryHint: .isDirectory)
                    },
                    pin: pane.pinnedDirectory.map {
                        URL(filePath: $0, directoryHint: .isDirectory)
                    }
                ).anchor?.url.path(percentEncoded: false)
            }
        )
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
                windowFrame: nil,
                // Nil for the same reason the frame is: this piece builds one tab's
                // panes, and the window-level geometry is applied to every window
                // once they all exist.
                sidebar: nil,
                fileTreeExpansions: nil
            )
            let controller = openWindow(
                tree: PaneTreeController(
                    restoring: piece,
                    defaultWorkingDirectory: Self.defaultWorkingDirectory,
                    configuration: configuration,
                    channel: control
                ),
                joining: previous
            )
            if first == nil { first = controller.window }
            previous = controller.window
        }
        restoreFrame(reconciled.windowFrame, on: first)

        // Applied to every window, not only the first. Each tab has its own sidebar
        // and the file records one size, so restoring it to one of them would leave
        // the rest at the default and read as a drag that half took.
        if let geometry = reconciled.sidebar {
            for controller in windows { controller.sidebar.geometry = geometry }
        }

        // Every window again, and for a different reason: the map is keyed by
        // anchor, so a window gets back the set belonging to whichever repository
        // its own focused pane is in and ignores the rest. Handing each window the
        // whole map is what lets two tabs on two repositories both come back the
        // way they were left.
        //
        // After `openWindow`, which refreshes each sidebar as it opens. That
        // ordering is why `SidebarHost.fileTreeExpansions` assigns back into the
        // rows rather than only filling the map: the Files surface has already been
        // pointed at an anchor and shown it empty by the time this runs.
        if let expansions = reconciled.fileTreeExpansions {
            for controller in windows { controller.sidebar.fileTreeExpansions = expansions }
        }

        // Focused last, because joining a tab group brings the new tab forward.
        let index = reconciled.workspace.focusedTabIndex
        if windows.indices.contains(index) {
            windows[index].window.makeKeyAndOrderFront(nil)
            windows[index].tree.focusedPane?.takeFocus()
        }
        updateWindowTitles()
    }

    /// Opens one window per snapshot, joined into a group of their own.
    ///
    /// What `baia layout apply` lands on. The join order is `restoreSession`'s and
    /// for its reason: `addTabbedWindow` inserts *after* the window it is given,
    /// so each tab joins the one before it rather than all of them joining the
    /// first, which builds the group in reverse from the third tab on.
    ///
    /// **Detached from every existing window**, which is `.disallowed` on the
    /// first and `joining: nil` with it. A layout arriving in the caller's tab
    /// group would reorder a tab bar the owner arranged: no pane moves, and the
    /// window they were looking at is not the window they are looking at now.
    ///
    /// Scheduled rather than run now, because the caller's shell is waiting on the
    /// response frame and this opens shells. The server hands that frame to the
    /// transport on the way out of the adapter, inside the current turn, so it is
    /// queued before any of this runs.
    func openWindows(restoring pieces: [SessionSnapshot]) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                var previous: NSWindow?
                for piece in pieces {
                    let controller = self.openWindow(
                        tree: PaneTreeController(
                            restoring: piece,
                            defaultWorkingDirectory: Self.defaultWorkingDirectory,
                            configuration: self.configuration,
                            channel: self.control
                        ),
                        joining: previous,
                        tabbing: previous == nil ? .disallowed : .preferred
                    )
                    previous = controller.window
                }
                self.scheduleSave()
            }
        }
    }

    private func openFresh() {
        openWindow(
            tree: PaneTreeController(
                workingDirectory: Self.defaultWorkingDirectory,
                configuration: configuration,
                channel: control
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
