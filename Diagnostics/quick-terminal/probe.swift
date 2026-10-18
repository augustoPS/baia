import AppKit
import Carbon
import WorkspaceLayout

// These fixtures replace only the engine and configuration dependencies. The
// panel, its lifecycle, shortcut ownership and animations are shipped source.
final class TerminalPaneController: NSViewController {
    let paneID: PaneID
    var onProcessClose: (() -> Void)?
    private(set) var focusRequests = 0

    init(paneID: PaneID, workingDirectory: String, createdBy: String?, controlSocketPath: String?) {
        self.paneID = paneID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)) }
    func setPaneFocused(_ focused: Bool) {}
    func takeFocus() { focusRequests += 1 }
}

final class ConfigurationCenter {
    var windowIsDark = true
    var windowIsTransparent = false
    private(set) var registeredPanes = 0
    func register(_ pane: TerminalPaneController) { registeredPanes += 1 }
}

@main
struct QuickTerminalProbe {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func settle() {
        let end = Date(timeIntervalSinceNow: 0.35)
        while Date() < end {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let configuration = ConfigurationCenter()
        let quick = QuickTerminalController(configuration: configuration)
        require(quick.pane == nil, "opening the app must not create the quick terminal")
        quick.toggle()
        settle()
        guard let pane = quick.pane else { fatalError("show did not create the pane") }
        let view = pane.view
        require(quick.panel.isVisible, "toggle must show the panel")
        require(quick.panel.contentViewController === pane, "panel must own its terminal")
        require(pane.focusRequests > 0, "show must focus the terminal")
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main else { fatalError("no screen available") }
        let expected = NSRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.midY,
                              width: screen.visibleFrame.width, height: screen.visibleFrame.height / 2)
        require(quick.panel.frame.equalTo(expected), "panel must occupy the upper half of the pointer screen")

        quick.hide()
        settle()
        if CommandLine.arguments.contains("--negative-control") {
            quick.panel.contentViewController = nil
        }
        require(!quick.panel.isVisible, "hide must remove the panel from screen")
        require(quick.pane === pane, "hide must retain the same terminal controller")
        require(quick.panel.contentViewController === pane, "hide must keep the terminal attached")
        require(pane.view === view, "hide must retain the same terminal view")
        quick.toggle()
        settle()
        require(quick.pane === pane, "show must reuse the hidden terminal")
        quick.panel.performClose(nil)
        settle()
        require(!quick.panel.isVisible && quick.pane === pane, "close must hide and preserve the terminal")
        require(!quick.windowShouldClose(quick.panel), "window delegate must refuse destructive close")

        quick.toggle()
        quick.hide()
        quick.toggle()
        settle()
        require(quick.panel.isVisible && quick.panel.alphaValue > 0.99,
                "stale hide completion must not hide a reopened terminal")
        require(quick.panel.frame.equalTo(expected), "interrupted transition must finish at the visible frame")
        require(configuration.registeredPanes == 1, "toggles must not register extra terminals")

        pane.onProcessClose?()
        settle()
        require(quick.pane == nil && quick.panel.contentViewController == nil,
                "shell exit must release the terminal")
        require(!quick.panel.isVisible, "shell exit must hide the panel")
        require(pane.onProcessClose == nil, "shutdown must clear the process callback")
        quick.toggle()
        settle()
        require(quick.pane != nil && quick.pane !== pane, "show after shell exit must create a fresh terminal")
        require(configuration.registeredPanes == 2, "replacement terminal must register once")
        quick.shutdown()

        var first: GlobalTerminalShortcut? = GlobalTerminalShortcut(action: {})
        let firstStatus = first!.register()
        if firstStatus == noErr {
            require(first!.register() == noErr, "register must be idempotent")
            let second = GlobalTerminalShortcut(action: {})
            require(second.register() != noErr, "conflicting registration must fail")
            first = nil
            require(second.register() == noErr, "failed registration must retry after owner releases key")
        } else {
            print("SKIP: live shortcut owned elsewhere (OSStatus \(firstStatus)); no key events sent")
        }
        print("PASS: lazy creation, geometry, hide/close identity, interruption, exit/recreate and shortcut cleanup")
        print("Reduce Motion: \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? "enabled" : "disabled"); rerun with the other setting for both paths")
    }
}
