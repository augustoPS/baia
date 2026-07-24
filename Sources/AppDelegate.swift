import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_: Notification) {
        let pane = TerminalPaneController(workingDirectory: Self.defaultWorkingDirectory)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = pane
        window.title = "baia"
        window.setFrameAutosaveName("baia.main")
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
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
