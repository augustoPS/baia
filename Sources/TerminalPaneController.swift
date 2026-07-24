import AppKit
import GhosttyTerminal

/// One terminal surface backed by a real PTY.
///
/// The libghostty example app uses `.inMemory` with ShellCraftKit because it is
/// sandboxed and cannot spawn processes. That backend is an emulated shell: it
/// cannot run git, node, or a coding agent. `.exec` is the real one, and it is
/// the default value of `TerminalSurfaceOptions.backend`.
final class TerminalPaneController: NSViewController {
    /// Exported to the child environment as `BAIA_PANE`. Every process launched
    /// from this pane's shell inherits it, so an externally observed process can
    /// be traced back to the pane that owns it. That is how a future session
    /// list knows which pane is running which agent.
    let paneID = UUID()

    private let workingDirectory: String

    private lazy var terminalView = TerminalView(
        frame: NSRect(x: 0, y: 0, width: 1024, height: 680)
    )

    private lazy var controller = TerminalController { builder in
        // Terminal-driven clipboard access is denied. Attacker-controlled output
        // (a compromised SSH host, a malicious build script) can issue OSC 52 to
        // read the host clipboard and receive the reply back through the PTY.
        // kero shipped with these set to `allow` and it was reported as a
        // vulnerability within a day (egoist/kero#8). Keyboard copy and paste are
        // unaffected by these settings.
        builder.withCustom("clipboard-read", "deny")
        builder.withCustom("clipboard-write", "deny")
        builder.withCustom("clipboard-paste-protection", "true")
    }

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("baia does not use nibs")
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        terminalView.delegate = self
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: workingDirectory,
            envVars: ["BAIA_PANE": paneID.uuidString]
        )
        terminalView.controller = controller
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(terminalView)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        terminalView.fitToSize()
    }
}

// MARK: - Surface callbacks

extension TerminalPaneController:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceResizeDelegate,
    TerminalSurfaceCloseDelegate
{
    func terminalDidChangeTitle(_ title: String) {
        view.window?.title = title.isEmpty ? "baia" : title
    }

    func terminalDidResize(columns _: Int, rows _: Int) {}

    func terminalDidClose(processAlive _: Bool) {
        view.window?.close()
    }
}
