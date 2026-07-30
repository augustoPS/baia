import AppKit
import GhosttyTerminal

/// A terminal surface that renders canned output so a theme can be looked at.
///
/// `.inMemory` rather than `.exec`, and that is not a preference.
/// `TerminalSurface.free()` is internal to libghostty, so baia cannot close a
/// surface, and the pty dies only when the view deallocates. An `.exec` sample
/// would orphan a shell every time this window opened, and baia could not kill
/// it. `.inMemory` has no pty: it spawns nothing, and closing the window drops a
/// view and leaks no process.
///
/// Rendering is unaffected by the choice, because the backend is I/O only. Font,
/// theme, background and cursor are as faithful here as in a real pane, which is
/// the whole reason a sample is worth looking at.
@MainActor
final class SettingsSampleSurface: NSViewController {
    /// Fixed output, chosen to exercise what the appearance keys change.
    ///
    /// A prompt for the cursor and the foreground, a diff for the red and green
    /// the alert and accent colours are picked against, and both palette rows so
    /// a theme is judged on more than two colours. Prose would show the font and
    /// nothing else.
    private static let cannedOutput = """
    \u{1b}[1;32m~/Projects/baia\u{1b}[0m on \u{1b}[1;35mmain\u{1b}[0m\r
    $ git diff --stat\r
     \u{1b}[36mSources/SettingsView.swift\u{1b}[0m | \u{1b}[32m+++++++++\u{1b}[31m--\u{1b}[0m\r
     \u{1b}[36mSources/ConfigurationCenter.swift\u{1b}[0m | \u{1b}[32m++\u{1b}[0m\r
    $ make test\r
    \u{1b}[32m✔\u{1b}[0m 138 tests in 10 suites passed\r
    \u{1b}[90m██\u{1b}[31m██\u{1b}[32m██\u{1b}[33m██\u{1b}[34m██\u{1b}[35m██\u{1b}[36m██\u{1b}[37m██\u{1b}[0m\r
    \u{1b}[90m██\u{1b}[91m██\u{1b}[92m██\u{1b}[93m██\u{1b}[94m██\u{1b}[95m██\u{1b}[96m██\u{1b}[97m██\u{1b}[0m\r
    $ \r
    """

    /// Held so the surface has somewhere to send input it will never be given.
    ///
    /// Both handlers discard. This surface accepts no keystrokes and resizes
    /// nothing but itself, so there is no host on the other end to tell.
    private let session = InMemoryTerminalSession(
        write: { _ in },
        resize: { _ in }
    )

    private lazy var terminalView = TerminalView(
        frame: NSRect(x: 0, y: 0, width: 640, height: 360)
    )

    private lazy var controller = TerminalController { builder in
        // The same denials a real pane sets. This surface runs no process and so
        // nothing here is reachable, but a sample that disagreed with the pane it
        // stands in for would be a sample of the wrong thing.
        builder.withCustom("clipboard-read", "deny")
        builder.withCustom("clipboard-write", "deny")
        builder.withCustom("clipboard-paste-protection", "true")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Assigned once, here and nowhere else. `configuration` and `controller`
        // both have a `didSet` that tears the surface down and rebuilds it, so a
        // settings change must never come back through these. `apply(_:theme:)`
        // is the live path.
        terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        terminalView.controller = controller
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        session.receive(Self.cannedOutput)
    }

    /// Re-themes the sample without rebuilding it.
    ///
    /// Through the controller, the way `TerminalPaneController` does it, and for
    /// the same reason: the view's own setters respawn the surface.
    func apply(_ configuration: TerminalConfiguration, theme: TerminalTheme) {
        controller.setTerminalConfiguration(configuration)
        controller.setTheme(theme)
    }
}
