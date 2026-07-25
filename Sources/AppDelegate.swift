import AppKit
import WorkspaceLayout
import WorkspaceMenu

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var tree: PaneTreeController?

    func applicationDidFinishLaunching(_: Notification) {
        MainMenu.install(into: NSApp)

        let tree = PaneTreeController(workingDirectory: Self.defaultWorkingDirectory)
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

        // After sizing: naming the autosave restores a previously saved frame if
        // one exists, and otherwise persists the good default just established.
        window.setFrameAutosaveName("baia.main")
        window.makeKeyAndOrderFront(nil)

        // The window owns its title because with several panes only the focused
        // one may name it. A pane that set the title itself would have every
        // pane overwriting it on every one-second poll.
        tree.onFocusedPaneChange = { [weak tree, weak window] in
            guard let tree, let window else { return }
            window.title = tree.windowTitle.title
            window.subtitle = tree.windowTitle.subtitle
        }
        tree.onEmpty = { [weak window] in
            window?.close()
        }

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
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
