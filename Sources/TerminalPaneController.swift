import AppKit
import GhosttyTerminal
import ProjectAnchor

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

    /// Non-private: AppDelegate's Pane menu actions drive the pin through it.
    lazy var anchorTracker = PaneAnchorTracker(
        foregroundPid: { [weak self] in self?.terminalView.foregroundPid }
    )

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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1024, height: 680))
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

        // Edge pinning alone leaves the hierarchy with no size of its own.
        // TerminalView has no intrinsic content size, so `fittingSize` collapses
        // to zero and a window using this controller as its contentViewController
        // shrinks to a 1x32 sliver. These two constraints supply a preferred size
        // at a priority the window can override when the user resizes.
        let preferredWidth = terminalView.widthAnchor.constraint(equalToConstant: 1024)
        let preferredHeight = terminalView.heightAnchor.constraint(equalToConstant: 680)
        preferredWidth.priority = .defaultLow
        preferredHeight.priority = .defaultLow

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            preferredWidth,
            preferredHeight,
        ])

        anchorTracker.onAnchorChange = { [weak self] anchor in
            self?.updateWindowTitle(for: anchor)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(terminalView)
        observeWindowFocus()
        updateWindowTitle(for: anchorTracker.anchor)
        if view.window?.isKeyWindow == true {
            anchorTracker.startPolling()
        }
    }

    /// Polling is gated on focus, so an unfocused window costs nothing and a
    /// focused one refreshes on the first tick after it comes forward.
    private func observeWindowFocus() {
        guard let window = view.window else { return }
        let center = NotificationCenter.default
        center.removeObserver(self)
        center.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    @objc private func windowDidBecomeKey() {
        anchorTracker.startPolling()
    }

    @objc private func windowDidResignKey() {
        anchorTracker.stopPolling()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        terminalView.fitToSize()
    }

    /// Title carries the anchor, subtitle the working directory. The subtitle is
    /// the cwd rather than the anchor: seeing both is the point, since the whole
    /// feature is about them differing.
    private func updateWindowTitle(for anchor: Anchor?) {
        guard let window = view.window else { return }
        guard let anchor else {
            window.title = "baia"
            window.subtitle = ""
            return
        }
        window.title = "baia — \(anchor.displayName)"
        let cwd = anchorTracker.workingDirectory?.path(percentEncoded: false) ?? ""
        let shown = (cwd as NSString).abbreviatingWithTildeInPath
        window.subtitle = anchor.source == .pinned ? "\(shown) · pinned" : shown
    }
}

// MARK: - Surface callbacks

extension TerminalPaneController:
    TerminalSurfacePwdDelegate,
    TerminalSurfaceResizeDelegate,
    TerminalSurfaceCloseDelegate
{
    /// OSC 7. Nothing emits it today: the bundled libghostty ships no
    /// shell-integration resources and macOS gates its own emitter on
    /// TERM_PROGRAM=Apple_Terminal. The tracker's polling covers that. This stays
    /// because it is one method, and it makes updates instant if anything ever
    /// does emit.
    func terminalDidChangeWorkingDirectory(_ path: String) {
        anchorTracker.reportWorkingDirectory(path)
    }

    func terminalDidResize(columns _: Int, rows _: Int) {}

    func terminalDidClose(processAlive _: Bool) {
        view.window?.close()
    }
}
