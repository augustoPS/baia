import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var pane: TerminalPaneController?

    func applicationDidFinishLaunching(_: Notification) {
        MainMenu.install(into: NSApp)

        let pane = TerminalPaneController(workingDirectory: Self.defaultWorkingDirectory)
        self.pane = pane

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = pane
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

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    @objc func setProjectDirectory(_: Any?) {
        guard let pane else { return }
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
        pane?.anchorTracker.clearPin()
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
    /// Clear Pin is meaningless with nothing pinned.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(clearProjectDirectoryPin(_:)) {
            return pane?.anchorTracker.isPinned ?? false
        }
        return true
    }
}
