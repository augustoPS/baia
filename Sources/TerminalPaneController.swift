import AppKit
import BaiaSettings
import GhosttyTerminal
import PaneChrome
import PaneSearch
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
        foregroundPid: { [weak self] in self?.terminalView.foregroundPid },
        pinnedDirectory: restoredPin
    )

    /// Held until the lazy tracker is first touched. A restored pin has to be in
    /// place before the first poll resolves an anchor, or the pane would show its
    /// unpinned anchor for a tick and then jump.
    private let restoredPin: URL?

    private let workingDirectory: String

    let statusBar = PaneStatusBarView(frame: .zero)

    /// Covers the terminal and the footer both, which is the point: a background
    /// window recedes as one object, and a scrim that stopped at the footer would
    /// leave every pane in it wearing a bright band.
    private let scrim = PaneScrimView(frame: .zero)

    private let edgeFrame = PaneEdgeFrameView(frame: .zero)

    /// The palette everything in this pane derives from. One property rather than
    /// one per view, so a theme change cannot land on the footer and miss the
    /// scrim.
    var theme: PaneTheme = .darkPastel {
        didSet {
            guard theme != oldValue else { return }
            statusBar.theme = theme
            applyPresentation()
        }
    }

    var attentionStyle: AttentionStyle = .loud {
        didSet {
            guard attentionStyle != oldValue else { return }
            statusBar.attentionStyle = attentionStyle
            // The frame is gated on `loud` too, so a live config edit that
            // quietens attention has to take the frame down with the fill.
            applyPresentation()
        }
    }

    /// Which derivation the attention signal is drawn from, and what to do when it
    /// lands on the focus colour.
    ///
    /// Both reach the footer and the pane frame, which is why they are stored here
    /// rather than passed straight to the bar the way ``bottomCorners`` is: the
    /// frame around the whole pane is drawn in the same colour, and a setting that
    /// moved one of the two would leave half of the loud treatment behind.
    var attentionAccent: AttentionAccent = .alert {
        didSet {
            guard attentionAccent != oldValue else { return }
            statusBar.attentionAccent = attentionAccent
            applyPresentation()
        }
    }

    var alertBehavior: AlertBehavior = .stock {
        didSet {
            guard alertBehavior != oldValue else { return }
            statusBar.alertBehavior = alertBehavior
            applyPresentation()
        }
    }

    /// Which of the window's bottom corners this pane's footer has to curve to.
    ///
    /// Straight through to the bar rather than stored here and pushed in
    /// ``applyPresentation()``, because unlike focus, theme and attention it moves
    /// exactly one view and it moves for a different reason: the arrangement
    /// changed, not this pane's state. ``PaneTreeController`` is the only writer.
    var bottomCorners: BottomCorners {
        get { statusBar.bottomCorners }
        set { statusBar.bottomCorners = newValue }
    }

    private(set) var isPaneFocused = false

    /// Whether this pane's window is the key window.
    ///
    /// Every pane recedes when the window is not key, including the focused one,
    /// so an inactive window reads as one recessed object rather than as a window
    /// that still has a live pane in it. macOS offers no other honest signal for
    /// this here, because the titlebar is transparent.
    var isWindowActive = true {
        didSet {
            guard isWindowActive != oldValue else { return }
            applyPresentation()
        }
    }

    func setPaneFocused(_ focused: Bool) {
        guard isPaneFocused != focused else { return }
        isPaneFocused = focused
        applyPresentation()
    }

    /// Pushes focus, window activation, theme and attention into the three views
    /// that draw them, in one pass.
    ///
    /// One method rather than one per input, because every input moves more than
    /// one view: a theme change has to reach the scrim as well as the footer, and
    /// an attention change has to reach the pane frame as well as the bar. Split
    /// setters are how a pane ends up with a repainted footer over a stale scrim.
    private func applyPresentation() {
        statusBar.isFocused = isPaneFocused
        statusBar.isWindowActive = isWindowActive
        statusBar.theme = theme
        scrim.colour = theme.background
        // See `isWindowActive` above for why an inactive window is the only thing
        // that scrims a pane. An unfocused pane in the key window is left alone
        // and the focused one is enclosed by its footer instead.
        scrim.amount = isWindowActive ? 0 : PaneTheme.inactiveScrim
        // The pane frame has one reason to appear and therefore one colour, but
        // the colour still has to be pushed on every pass: a live theme edit moves
        // what the attention colour resolves to under a frame that is already on
        // screen. Resolved from the same call the footer's wash uses, so the frame
        // around the pane and the fill inside it cannot end up two colours.
        edgeFrame.colour = theme.attentionColour(attentionAccent, behavior: alertBehavior)
        edgeFrame.isVisible = drawsAttentionFrame
    }

    /// Whether this pane is asking loudly enough to wear a frame.
    ///
    /// Not gated on `isWindowActive`, unlike the footer's focus frame: focus is a
    /// statement about a window that has the keyboard, while an unanswered agent
    /// in a background window is exactly the thing worth finding.
    ///
    /// Both terms are `PaneStatusBarView.fillsBarForAttention`'s, so the frame and
    /// the fill can only ever appear together. Splitting them would leave half of
    /// level 2 on screen.
    private var drawsAttentionFrame: Bool {
        lastAttention == .asking && attentionStyle == .loud
    }

    private let gitStatus = PaneGitStatus()

    private lazy var activityTracker = PaneActivityTracker(
        foregroundPid: { [weak self] in self?.terminalView.foregroundPid }
    )

    /// Raised when the pane starts or stops asking for attention, so the window
    /// can badge itself and post a notification naming the project.
    var onAttentionChange: (() -> Void)?

    var wantsAttention: Bool { activityTracker.wantsAttention }

    /// What this pane asked for, when it said so rather than only ringing.
    var attentionMessage: String? { activityTracker.attentionMessage }

    /// A keystroke reached this pane. Driven by the app's key monitor, since
    /// nothing in a pane may take first responder.
    func noteInput() { activityTracker.noteInput() }

    /// The pane's current width in cells, from `terminalDidResize`.
    ///
    /// Zero until the surface exists and reports, which is the same window in
    /// which `readScreenText` returns nil, so both are handled by the same
    /// early return rather than by a special case.
    private var gridColumns = 0

    /// Every logical line the pane holds, scrollback included.
    ///
    /// Nil before the surface exists. A pane whose view is not yet in a window
    /// contributes no matches rather than counting as an error, which is the
    /// same rule every tracker's first poll follows.
    ///
    /// Logical lines, not screen rows: a line wider than the pane comes back
    /// whole, so a match is never cut in half by a soft wrap. That is why
    /// `row(ofLine:in:containing:)` exists at all, since the index of a line
    /// here is not the row it starts on.
    func readScreenLines() -> [String]? {
        guard let text = terminalView.readScreenText() else { return nil }
        return text.components(separatedBy: "\n")
    }

    /// The screen row a match is drawn on, for `scrollToRow`, or nil when no
    /// read confirms one.
    ///
    /// Estimated, then confirmed. The estimate is `TerminalRows.row`, which
    /// counts the cells a line occupies rather than its characters, because a
    /// terminal wraps when the cells run out: counting characters lost a row for
    /// every wide character above the match, and the error accumulated over the
    /// whole scrollback rather than over a screenful. Measured against a
    /// simulated terminal, 200 lines of 60 CJK characters in an 80 column pane
    /// put the match 200 rows below where the old arithmetic pointed.
    ///
    /// The confirmation walks outward from the estimate until a row's text holds
    /// the match, which is a per-row exact read and therefore a real screen row.
    /// It is bounded at 64 rows either side, so the worst case is 129 reads
    /// rather than a scan of the whole scrollback.
    ///
    /// Nil when the bound is exhausted, and never the unconfirmed estimate. The
    /// pane's output can have moved since the search, and scrolling to a row
    /// that does not hold the match sends the owner somewhere arbitrary with the
    /// panel already dismissed and nothing on screen to say what happened.
    func row(of match: LineMatch, in lines: [String]) -> UInt? {
        guard gridColumns > 0 else { return nil }

        let characters = Array(match.line)
        guard match.range.lowerBound >= 0,
              match.range.upperBound <= characters.count,
              !match.range.isEmpty
        else { return nil }

        // The matched text itself rather than the query, so the confirmation
        // looks for what is really on screen even when the query was
        // case-insensitive.
        let needle = String(characters[match.range])
        let estimate = TerminalRows.row(
            ofLine: match.lineIndex,
            offset: match.range.lowerBound,
            in: lines,
            columns: gridColumns
        )

        for offset in 0 ... Self.rowSearchBound {
            // Offset zero names one row, not two. Spelling it as the symmetric
            // pair would read the estimate twice on the common case where the
            // estimate is already right, which is one wasted surface read per
            // match the owner visits.
            let candidates = offset == 0 ? [estimate] : [estimate + offset, estimate - offset]
            for candidate in candidates where candidate >= 0 {
                let text = terminalView.readRow(UInt32(candidate), columns: UInt32(gridColumns))
                if text?.contains(needle) == true { return UInt(candidate) }
            }
        }
        return nil
    }

    /// Scrolls the pane so `row` sits in the middle of the viewport rather than
    /// at its top, which is what keeps a match visible when the row was
    /// estimated rather than confirmed.
    func reveal(row: UInt, viewportRows: Int) {
        let centred = Int(row) - viewportRows / 2
        terminalView.scrollToRow(UInt(max(0, centred)))
    }

    private static let rowSearchBound = 64

    var gitPollInterval: TimeInterval {
        get { gitStatus.pollInterval }
        set { gitStatus.pollInterval = newValue }
    }

    var activityPollInterval: TimeInterval {
        get { activityTracker.pollInterval }
        set { activityTracker.pollInterval = newValue }
    }

    /// Applies the config file's terminal settings to this pane's surface.
    ///
    /// Through the controller, never through the view. `view.configuration` and
    /// `view.controller` both have a `didSet` that tears the surface down and
    /// respawns the shell, guarded only by `isEquivalent`, so changing a font
    /// size that way would lose the scrollback and kill whatever was running.
    /// `setTerminalConfiguration` and `setTheme` re-resolve and patch the
    /// existing surface instead.
    ///
    /// Called once before the surface exists, from registration, and again on
    /// every config file change. The first call is what makes a new pane come up
    /// already themed rather than coming up in libghostty's defaults and
    /// changing a frame later.
    func applyTerminalConfiguration(
        _ configuration: TerminalConfiguration,
        theme: TerminalTheme
    ) {
        controller.setTerminalConfiguration(configuration)
        controller.setTheme(theme)
    }

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

    init(paneID: PaneID, workingDirectory: String, pinnedDirectory: URL? = nil) {
        self.paneID = paneID
        self.workingDirectory = workingDirectory
        restoredPin = pinnedDirectory
        super.init(nibName: nil, bundle: nil)
    }

    /// What a session snapshot records for this pane.
    ///
    /// The working directory is the shell's current one rather than the one the
    /// pane opened with, so restoring lands where the pane was left. It falls
    /// back to the opening directory because the tracker reads nil until the
    /// surface exists, and a pane snapshotted in that window would otherwise
    /// restore with no directory at all.
    var paneState: PaneState {
        PaneState(
            id: paneID,
            workingDirectory: anchorTracker.workingDirectory?.path(percentEncoded: false)
                ?? workingDirectory,
            pinnedDirectory: anchorTracker.pinnedDirectory?.path(percentEncoded: false)
        )
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
        // Added last so they sit above both. Neither can be hit, so ordering
        // costs the terminal nothing.
        for overlay in [scrim, edgeFrame] {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(overlay)
        }

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

        for overlay in [scrim, edgeFrame] {
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: view.topAnchor),
                overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }

        applyPresentation()

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

        // Weak, so the footer cannot keep the pane alive. `PaneTreeController`
        // is the only strong owner of a pane, and a leaked pane is a leaked
        // shell.
        statusBar.onClick = { [weak self] in self?.takeFocus() }

        activityTracker.onChange = { [weak self] in
            guard let self else { return }
            // Unconditional, so the footer keeps tracking the label.
            refreshStatus()
            // The upward callback is not. `onChange` fires for any change to the
            // whole agent value, and the label changes as a build walks its
            // targets, so raising attention from here re-bounced the Dock and
            // re-posted the banner on every poll of a pane that was merely
            // compiling. Only a real transition of the attention state escapes.
            //
            // Read from the tracker rather than from `statusBar.status`, which is
            // nil until the anchor first resolves. A bell arriving in that window
            // used to leave the level at `.none`, and since `refreshStatus` does
            // not re-enter this block, an idle pane that rang once could sit there
            // asking with nothing drawn and no notification posted.
            let now = PaneStatus.Attention(activityTracker.agent)
            guard now != lastAttention else { return }
            lastAttention = now
            // The frame follows the level, so it is repainted here rather than
            // from `refreshStatus`, which fires on every poll of a pane that is
            // merely compiling.
            applyPresentation()
            onAttentionChange?()
        }
    }

    private var lastAttention: PaneStatus.Attention = .none

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
            agent: activityTracker.agent
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
            activityTracker.startPolling()
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
        activityTracker.stopPolling()
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
        // Activity keeps polling while the window is unfocused. It is the one
        // tracker whose whole purpose is to notice something while the user is
        // looking elsewhere, so gating it on focus would disable the feature
        // exactly when it matters.
        activityTracker.startPolling()
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
            tabPath,
            anchor.source == .pinned ? "\(shown) · pinned" : shown
        )
    }

    /// The slash-separated path a tab is disambiguated with, whose last
    /// component is the name the tab wants to show.
    ///
    /// A path rather than a bare name because two tabs called `baia` can only be
    /// told apart by what is above them, and `TabTitle.disambiguated` needs the
    /// parents to grow into.
    var tabPath: String {
        guard let anchor = anchorTracker.anchor else { return "baia" }
        let title = TabTitle.title(
            anchorName: anchor.displayName,
            isWorktree: statusBar.status?.git?.isLinkedWorktree ?? false
        )
        let parent = anchor.url.deletingLastPathComponent().path(percentEncoded: false)
        return parent.isEmpty ? title : parent + "/" + title
    }

    /// This pane's contribution to its window's tab label.
    ///
    /// - Parameter project: the already-disambiguated name, which only the owner
    ///   of every window can compute, since disambiguating needs to see the
    ///   others.
    func tabTitle(project: String, budget: TabTitle.Budget) -> String {
        let status = statusBar.status
        let git = status?.git
        let markers = status
            .map { PaneStatusSegments.build(from: $0) }?
            .first { $0.role == .indicators }?
            .text ?? ""
        return TabTitle.tab(
            project: project,
            branch: git?.head,
            // From the resolver rather than from the name of the branch. A
            // repository whose default is `develop` showed `:develop` on every tab
            // forever, and one defaulting to `main` said nothing at all on a branch
            // called `master`, which is the state worth shouting about.
            isDefaultBranch: gitStatus.isOnDefaultBranch,
            markers: markers,
            attention: status?.attention ?? .none,
            isBusy: status?.agent?.isBusy ?? false,
            budget: budget
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
    TerminalSurfaceBellDelegate,
    TerminalSurfaceDesktopNotificationDelegate,
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

    func terminalDidResize(columns: Int, rows _: Int) {
        // Kept because both the row estimate and `readRow` need it. Taken from
        // here and never from `TerminalSurfaceGridResizeDelegate`, which carries
        // a richer `TerminalGridMetrics` and looks like the better source: the
        // surface coordinator dispatches its delegate by `as?` casts and tests
        // the grid variant first in an `else if`, so conforming to both would
        // silence this method with no error at all.
        gridColumns = columns
    }

    /// The footer follows both directions, because the pane losing focus has to
    /// stop drawing its accent stripe. Only the gaining side is reported upward:
    /// a responder change delivers false to the outgoing pane and true to the
    /// incoming one, so raising the callback on both would have two panes racing
    /// to tell the workspace which of them is focused.
    func terminalDidChangeFocus(_ focused: Bool) {
        setPaneFocused(focused)
        guard focused else { return }
        // Looking at the pane acknowledges the request without ending it. The
        // pane may still be waiting, and it now says so quietly rather than
        // falling silent the instant it is glanced at.
        activityTracker.noteFocused()
        onFocusGained?()
    }

    /// A bell. Claude Code rings one when it wants input, if its notification
    /// channel is set to a form that rings, which makes this the signal that
    /// turns "which of my agents needs me" from a guess into a fact.
    func terminalDidRingBell() {
        activityTracker.noteBell()
    }

    /// OSC 9 and OSC 777. Needs no shell integration, since it is emitted by
    /// whatever is running rather than by the shell, which matters because the
    /// trimmed libghostty ships no shell integration at all.
    func terminalDidRequestDesktopNotification(title: String, body: String) {
        activityTracker.noteNotification(title: title, body: body)
    }

    /// Closing the window here was right while a window held exactly one pane.
    /// With splits it would take every sibling pane down with it, so the owner
    /// decides: collapse this pane, and close the window only when it was the
    /// last one.
    func terminalDidClose(processAlive _: Bool) {
        onProcessClose?()
    }
}
