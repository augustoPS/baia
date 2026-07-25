import AppKit
import GhosttyTerminal
import PaneChrome
import ProjectAnchor
import WorkspaceLayout
import WorkspaceMenu

/// One terminal surface backed by a real PTY.
///
/// The libghostty example app uses `.inMemory` with ShellCraftKit because it is
/// sandboxed and cannot spawn processes. That backend is an emulated shell: it
/// cannot run git, node, or a coding agent. `.exec` is the real one, and it is
/// the default value of `TerminalSurfaceOptions.backend`.
final class TerminalPaneController: NSViewController {
    /// Exported to the child environment as `BAIA_PANE`. Every process launched
    /// from this pane's shell inherits it, so an externally observed process can
    /// be traced back to the pane that owns it. That is how a session list knows
    /// which pane is running which agent.
    ///
    /// Injected rather than minted here. A pane that generated its own id could
    /// never be re-adopted by a restored session, because the id in the session
    /// file would name a pane that no longer exists, so `BAIA_PANE` would change
    /// meaning on every launch.
    let paneID: PaneID

    /// Raised when this pane takes keyboard focus, so the tree controller can
    /// move the workspace's focus without polling the responder chain.
    var onFocusGained: (() -> Void)?

    /// Raised when the anchor or the working directory moves, which is what the
    /// window title and this pane's footer are derived from.
    var onAnchorChange: (() -> Void)?

    /// Raised when the pane's shell exits. Closing the window here would be
    /// wrong once a window holds several panes.
    var onProcessClose: (() -> Void)?

    /// Non-private: the Pane menu actions drive the pin through it.
    lazy var anchorTracker = PaneAnchorTracker(
        foregroundPid: { [weak self] in self?.terminalView.foregroundPid }
    )

    private let workingDirectory: String

    let statusBar = PaneStatusBarView(frame: .zero)

    private let gitStatus = PaneGitStatus()

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

        // Give every key baia's menu bar claims back to AppKit.
        //
        // AppTerminalView.performKeyEquivalent turns any key ghostty has a
        // binding for into a surface keyDown and returns true. AppKit reads that
        // as handled and never consults the main menu, so a claimed key works
        // when the item is clicked while the shortcut does nothing at all, with
        // no error. Ghostty's own split and tab actions are unreachable from
        // Swift as well, so the key is not merely stolen, it is inert.
        //
        // The list is derived from the menu itself rather than written out here.
        // Maintaining two lists by hand is what killed super+q and
        // super+shift+p, and WorkspaceMenu's tests fail if a claimed key is
        // missing from ghostty's default table or if a key declared
        // conflict-free turns out to be bound.
        for line in GhosttyDefaultKeybinds.unbindLines(for: MenuBarLayout.menus) {
            builder.withCustom("keybind", line)
        }
    }

    init(paneID: PaneID, workingDirectory: String) {
        self.paneID = paneID
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
            envVars: ["BAIA_PANE": paneID.rawValue.uuidString]
        )
        terminalView.controller = controller
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)
        view.addSubview(statusBar)

        // Edge pinning alone leaves the hierarchy with no size of its own.
        // TerminalView has no intrinsic content size, so `fittingSize` collapses
        // to zero and a window using this controller as its contentViewController
        // shrinks to a 1x32 sliver. These two constraints supply a preferred size
        // at a priority the window can override when the user resizes.
        let preferredWidth = terminalView.widthAnchor.constraint(equalToConstant: 1024)
        let preferredHeight = terminalView.heightAnchor.constraint(equalToConstant: 680)
        preferredWidth.priority = .defaultLow
        preferredHeight.priority = .defaultLow

        // The footer's height is fixed but breakable, while the terminal's
        // minimum is not. Under extreme vertical pressure the footer is what
        // gives, because a terminal squeezed to zero rows is a surface ghostty
        // cannot lay out, and the pane stops rendering entirely rather than
        // merely looking cramped.
        let barHeight = statusBar.heightAnchor.constraint(
            equalToConstant: PaneStatusBarMetrics.height
        )
        barHeight.priority = .init(999)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            terminalView.heightAnchor.constraint(greaterThanOrEqualToConstant: 1),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            barHeight,

            preferredWidth,
            preferredHeight,
        ])

        anchorTracker.onChange = { [weak self] in
            guard let self else { return }
            // Handed the anchor on every change, and it returns immediately
            // unless the repository actually moved. Without that guard this
            // would fork git once a second per pane.
            gitStatus.setAnchor(anchorTracker.anchor)
            refreshStatus()
            onAnchorChange?()
        }

        gitStatus.onChange = { [weak self] _ in
            self?.refreshStatus()
        }
    }

    /// Rebuilds the footer's value from the anchor. Git and agent state are left
    /// nil until their subsystems are wired, and `PaneStatusSegments` already
    /// suppresses those segments rather than rendering placeholders.
    private func refreshStatus() {
        guard let anchor = anchorTracker.anchor else {
            statusBar.status = nil
            return
        }
        let home = FileManager.default
            .homeDirectoryForCurrentUser
            .path(percentEncoded: false)
        let shown = anchorTracker.workingDirectory.flatMap { directory in
            PaneStatus.workingDirectory(
                ofShellAt: directory.path(percentEncoded: false),
                anchoredAt: anchor.url.path(percentEncoded: false),
                home: home
            )
        }
        statusBar.status = PaneStatus(
            anchorName: anchor.displayName,
            anchorIsRepository: anchor.kind == .repository,
            isPinned: anchor.source == .pinned,
            workingDirectory: shown,
            git: gitStatus.git,
            agent: nil
        )
    }

    /// Makes this pane's terminal the first responder. Nothing else may take it:
    /// `AppTerminalView.performKeyEquivalent` returns false unless the surface is
    /// itself the window's first responder, so a stray responder anywhere in the
    /// pane disables every ghostty binding in it.
    func takeFocus() {
        view.window?.makeFirstResponder(terminalView)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        observeWindowFocus()
        refreshStatus()
        onAnchorChange?()
        if view.window?.isKeyWindow == true {
            anchorTracker.startPolling()
            gitStatus.startPolling()
        }
    }

    /// A pane that leaves the window stops polling. Both timers are scheduled on
    /// the run loop, which retains them, so a closed pane that relied on
    /// deallocation would leave two timers firing against a nil target forever.
    /// This also covers the rebuild path, where a pane is detached and
    /// reattached and `viewDidAppear` starts it again.
    override func viewDidDisappear() {
        super.viewDidDisappear()
        anchorTracker.stopPolling()
        gitStatus.stopPolling()
    }

    /// Polling is gated on focus, so an unfocused window costs nothing and a
    /// focused one refreshes on the first tick after it comes forward.
    ///
    /// Removal is scoped by name and object rather than a blanket
    /// `removeObserver(self)`. A pane can be moved between windows when a tab is
    /// torn out, so this runs more than once per pane, and the blanket form would
    /// also drop observers registered for this object by anything else.
    private func observeWindowFocus() {
        guard let window = view.window else { return }
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
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
        gitStatus.startPolling()
    }

    @objc private func windowDidResignKey() {
        anchorTracker.stopPolling()
        gitStatus.stopPolling()
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
    ///
    /// Read by whoever owns the window, because with several panes in one window
    /// only the focused pane may name it. A pane that set the title itself would
    /// have every pane fighting over it on every poll.
    var windowTitle: (title: String, subtitle: String) {
        guard let anchor = anchorTracker.anchor else { return ("baia", "") }
        let cwd = anchorTracker.workingDirectory?.path(percentEncoded: false) ?? ""
        let shown = (cwd as NSString).abbreviatingWithTildeInPath
        return (
            "baia — \(anchor.displayName)",
            anchor.source == .pinned ? "\(shown) · pinned" : shown
        )
    }
}

// MARK: - Surface callbacks

/// One weak object receives all of these. The coordinator dispatches by a chain
/// of `as?` casts against a single `delegate`, so a callback only arrives if this
/// type conforms to its protocol.
///
/// `TerminalSurfaceGridResizeDelegate` is deliberately absent: the coordinator
/// tests for it with an `else if` before the plain resize protocol, so adding it
/// would silence `terminalDidResize(columns:rows:)` rather than supplement it.
extension TerminalPaneController:
    TerminalSurfacePwdDelegate,
    TerminalSurfaceResizeDelegate,
    TerminalSurfaceFocusDelegate,
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

    /// The footer follows both directions, because the pane losing focus has to
    /// stop drawing its accent stripe. Only the gaining side is reported upward:
    /// a responder change delivers false to the outgoing pane and true to the
    /// incoming one, so raising the callback on both would have two panes racing
    /// to tell the workspace which of them is focused.
    func terminalDidChangeFocus(_ focused: Bool) {
        statusBar.isFocused = focused
        guard focused else { return }
        onFocusGained?()
    }

    /// Closing the window here was right while a window held exactly one pane.
    /// With splits it would take every sibling pane down with it, so the owner
    /// decides: collapse this pane, and close the window only when it was the
    /// last one.
    func terminalDidClose(processAlive _: Bool) {
        onProcessClose?()
    }
}
