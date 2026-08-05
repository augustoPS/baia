import AppKit
import BaiaSettings
import GhosttyTerminal
import PaneChrome
import PaneControl
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

    /// The display id of the pane that opened this one through the control
    /// channel, and nil for a pane the owner opened by hand.
    ///
    /// A stored property rather than a value the snapshot computes, because the
    /// fact is only known at the moment the pane is made: by the time
    /// ``paneState`` is read, the request that caused the split is long gone and
    /// there is nothing left to ask. It is carried back in on restore so the edge
    /// survives a relaunch, which is what makes `baia list`'s answer to "where did
    /// this pane come from" true across launches rather than only within one.
    ///
    /// An identifier and never a credential. Nothing authenticates on a `PaneID`,
    /// which is exactly what makes this safe to persist and safe for a read verb
    /// to return.
    let createdBy: PaneID?

    /// This pane's per-run capability, the value its shell reads as `$BAIA_TOKEN`.
    ///
    /// Minted here, once, per pane per run, and never written to disk. Nil when
    /// the system refused entropy, and nil is honest rather than fatal: a pane
    /// with no capability is a pane whose `baia` says it has none, which is a
    /// working terminal with a broken channel rather than a launch failure.
    ///
    /// It sits in this object because the pane's own shell already holds it in
    /// its environment, so storing it here adds no exposure that spawning the
    /// shell did not already create. It goes to the graph once, through
    /// ``PaneControlChannel/registerPane(_:createdBy:secret:)``, and is read back
    /// by nothing: `PaneSecret.description` redacts, so it cannot reach a log
    /// line by being interpolated into one.
    let controlSecret: PaneSecret?

    /// Where this pane's shell is told the channel is listening, or nil when the
    /// instance runs without one.
    ///
    /// Passed in rather than reached for, because the answer is a launch-time
    /// decision made before the first pane exists and a pane that learned it a
    /// moment later would already have spawned its shell with the wrong
    /// environment.
    private let controlSocketPath: String?

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

    /// What this pane runs instead of a login shell, or nil for the login shell.
    ///
    /// Read once, by the lazy `controller`, and never again. It is not in
    /// ``paneState`` on purpose: a session file that carried it would restore a
    /// pane by re-running a command the owner already watched finish, and the
    /// pane's own directory is the part of it worth keeping.
    private let command: String?

    let statusBar = PaneStatusBarView(frame: .zero)

    /// Covers the terminal and the footer both, which is the point: a background
    /// window recedes as one object, and a scrim that stopped at the footer would
    /// leave every pane in it wearing a bright band.
    private let scrim = PaneScrimView(frame: .zero)

    private let edgeFrame = PaneEdgeFrameView(frame: .zero)

    /// The focused pane's ring, inner highlight and shadow under glass
    /// (Task 6). Covers the terminal and the footer both, the same span as
    /// ``scrim`` and ``edgeFrame``: the lift marks the whole pane as the one
    /// holding focus, not just its footer.
    private let liftView = PaneLiftView(frame: .zero)

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

    /// What the footer and the lift should draw: flat, unchanged, or glass
    /// with a material set, per `PaneChrome.resolvedStyle(setting:appearance:)`.
    ///
    /// Stored here, unlike ``bottomCorners``, because Task 6 gives it a
    /// second reader: ``applyPresentation()`` has to know whether chrome is
    /// glass to decide ``liftView``'s ``PaneLiftView/isVisible``, and a
    /// passthrough straight to ``statusBar`` would leave that read with
    /// nowhere to come from except unwrapping `statusBar.resolvedChrome`
    /// back out, the same value stored a second time under a different name.
    var resolvedChrome: ResolvedChrome = .flat {
        didSet {
            guard resolvedChrome != oldValue else { return }
            statusBar.resolvedChrome = resolvedChrome
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

    /// Which of the window's bottom corners this pane sits in.
    ///
    /// Straight through to the two views that draw a shape there rather than
    /// stored here and pushed in ``applyPresentation()``, because unlike focus,
    /// theme and attention it moves for a different reason: the arrangement
    /// changed, not this pane's state. ``PaneTreeController`` is the only writer.
    ///
    /// The footer and the attention frame both reach the corner, and they overlap
    /// there, so a value that moved one of the two would put a square frame over a
    /// curved fill and leave the frame's own corner to the window's mask.
    /// ``statusBar`` holds the value, since it is the view that has always had one.
    var bottomCorners: BottomCorners {
        get { statusBar.bottomCorners }
        set {
            statusBar.bottomCorners = newValue
            edgeFrame.bottomCorners = newValue
            liftView.bottomCorners = newValue
        }
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
        // The cursor accent is the one part of the presentation that lives inside
        // the surface rather than on a view this can repaint, so it is pushed
        // through the controller here rather than from `applyPresentation`.
        applyTerminalConfiguration()
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
        // The same `isFocused && isWindowActive` gate `PaneStatusBarView`
        // computes internally as `framesForFocus` for its own thick-fill step,
        // recomputed here because the lift lives outside the bar and has no
        // other way to hear about focus or window activation. Glass-only:
        // under flat (or Reduce Transparency, which `resolvedChrome` already
        // folds into `.flat` upstream) the lift stays invisible and the
        // footer's own stroke is the whole expression of focus, unchanged.
        let isGlass = if case .glass = resolvedChrome { true } else { false }
        liftView.isVisible = isPaneFocused && isWindowActive && isGlass
    }

    /// Whether this pane is asking loudly enough to wear a frame.
    ///
    /// Not gated on `isWindowActive`, unlike the footer's focus frame: focus is a
    /// statement about a window that has the keyboard, while an unanswered agent
    /// in a background window is exactly the thing worth finding.
    ///
    /// The volume term is what `AttentionStyle` still owns: both volumes draw the
    /// footer's capsule (`PaneStatusBarView.showsCapsuleFill` is asking-only and
    /// style-blind), and `loud` adds this frame on top as the cross-window carrier.
    private var drawsAttentionFrame: Bool {
        lastAttention == .asking && attentionStyle == .loud
    }

    /// Raised when this pane's git read produced something new.
    ///
    /// The sidebar draws the same answer the footer does, so it has to hear about a
    /// poll landing on the pane already in focus. Without this it would only refresh
    /// when focus moved, which is the case where nothing changed.
    var onGitChange: (() -> Void)?

    /// Readable from outside so a surface can re-point at the focused pane's last
    /// answer instead of starting a read of its own. Read-only on purpose: the
    /// poller's interval and anchor are still set through this controller, so
    /// nothing outside can start, stop or retarget a pane's git reads.
    private(set) var gitStatus = PaneGitStatus()

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

    /// Writes text into this pane's pty, as though the owner had typed it.
    ///
    /// The sidebar's path picker is the only caller. It is the owner's own click
    /// reaching the owner's own pane, which is what a keyboard already does, and it
    /// is **not** the control channel's `run`: the channel's refusal to let one
    /// pane write into another pane's pty stands unchanged.
    ///
    /// Sent whatever the pane is doing. An agent may be running or vim may be
    /// open, nothing can tell reliably, and this has the same semantics as a paste,
    /// which the owner can already do. The running-agent case is the valuable one
    /// rather than the one to guard against.
    ///
    /// `terminalView` stays private, for the reason find-in-pane reaches the
    /// surface through methods here rather than by handing the view out.
    /// Bytes rather than a `String`, because the only caller is sending a
    /// filename. A path is a byte string that need not be UTF-8, and every
    /// spelling of it that goes through `String` is a path no command can find.
    /// `PromptPath` decides what these bytes are; this writes them.
    func send(_ bytes: [UInt8]) {
        terminalView.sendBytes(bytes)
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
        terminalConfiguration = configuration
        terminalTheme = theme
        applyTerminalConfiguration()
    }

    /// What the config file last handed over, kept so the cursor accent can be
    /// re-applied on a focus change without asking for it again.
    private var terminalConfiguration: TerminalConfiguration?
    private var terminalTheme: TerminalTheme?

    /// Re-resolves this pane's surface config, cursor accent included.
    ///
    /// **The accent finally reaches the terminal.** `focusAccent` resolved a
    /// colour that only ever appeared on the chrome, so the setting was doing
    /// half of what its name says: the pane you are typing in looked like every
    /// other pane from the baseline down. The focused pane's cursor now carries
    /// it, and an unfocused pane omits the key entirely rather than setting a
    /// second colour, so it falls back to whatever the terminal theme chose.
    ///
    /// ``PaneTheme/inkFocus`` rather than the raw accent, because that is the
    /// colour the footer already draws the focused pane's name in. One accent in
    /// two places reads as one idea; the unrepaired accent beside the repaired
    /// name is two blues arguing, which is the argument that property was written
    /// for.
    ///
    /// Cheap enough for a focus change, which is the thing to be careful about
    /// here: someone arrowing across a grid moves focus several times a second.
    /// `setTerminalConfiguration` returns early on an equal value, so a pass that
    /// changes nothing costs a comparison, and a real focus change reconfigures
    /// exactly the two panes whose cursor colour actually moved. Nothing is
    /// reparented and no shell is signalled: this patches the live surface, which
    /// is the whole reason it goes through the controller rather than the view.
    private func applyTerminalConfiguration() {
        guard let terminalConfiguration, let terminalTheme else { return }
        controller.setTerminalConfiguration(
            isPaneFocused
                ? terminalConfiguration.cursorColor(theme.inkFocus.hexString)
                : terminalConfiguration
        )
        controller.setTheme(terminalTheme)
    }

    private lazy var terminalView = TerminalView(
        frame: NSRect(x: 0, y: 0, width: 1024, height: 680)
    )

    private lazy var controller: TerminalController = {
        // Lifted out of the closure so the closure captures a string rather than
        // the controller, and read exactly once: the pane's command is decided
        // when the pane is made and a surface rebuilt later is still this pane.
        let command = self.command
        return TerminalController { builder in
            // What the pane runs instead of a login shell, before the denials below
            // rather than after them, and the ordering is not cosmetic. These lines
            // are rendered into a ghostty config file, so a value carrying a newline
            // would write a config key of the caller's choosing.
            // `ControlWire.refusalForCommand` is what makes that unrepresentable and
            // is the lock that counts; putting the caller's line first is the cheap
            // second one, so that under any parser where a later key wins, the
            // denials are the last word on clipboard access rather than the first.
            //
            // Verbatim, so ghostty's own reading of it holds: a bare value with
            // arguments goes through `/bin/sh -c`, `direct:` execs, `shell:` forces
            // the wrap. The pane closes when the command exits, which is ghostty's
            // behaviour and not baia's, and a caller who wants a shell to survive
            // ends its command with one.
            if let command { builder.withCustom("command", command) }

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
    }()

    init(
        paneID: PaneID,
        workingDirectory: String,
        pinnedDirectory: URL? = nil,
        command: String? = nil,
        createdBy: PaneID?,
        controlSocketPath: String?
    ) {
        self.paneID = paneID
        self.workingDirectory = workingDirectory
        self.command = command
        restoredPin = pinnedDirectory
        self.createdBy = createdBy
        self.controlSocketPath = controlSocketPath
        // Minted before the surface exists, because the environment the shell is
        // spawned with is assembled in `viewDidLoad` and a token that arrived
        // after that would belong to a shell that had already started without it.
        controlSecret = ControlSecrets.mint().map(PaneSecret.init)
        super.init(nibName: nil, bundle: nil)
    }

    /// What a session snapshot records for this pane.
    ///
    /// The working directory is the shell's current one rather than the one the
    /// pane opened with, so restoring lands where the pane was left. It falls
    /// back to the opening directory because the tracker reads nil until the
    /// surface exists, and a pane snapshotted in that window would otherwise
    /// restore with no directory at all.
    ///
    /// `createdBy` comes off the stored property rather than being computed, and
    /// the no-default `PaneState.init` exists to make this line impossible to
    /// forget: Wave D wrote `nil` here to make the app target compile, which was
    /// true while no pane could arrive through the channel and would have been
    /// silently false the moment one could. A compiling `nil` is exactly how
    /// attributability ends up nil for every pane forever with nothing failing.
    var paneState: PaneState {
        PaneState(
            id: paneID,
            workingDirectory: anchorTracker.workingDirectory?.path(percentEncoded: false)
                ?? workingDirectory,
            pinnedDirectory: anchorTracker.pinnedDirectory?.path(percentEncoded: false),
            createdBy: createdBy
        )
    }

    /// What the pane header says is running here, for the channel's read verbs.
    ///
    /// Read off the tracker rather than off `statusBar.status`, which is nil until
    /// the anchor first resolves: a pane whose `baia whoami` ran in that window
    /// would otherwise report no activity for a pane that had some.
    /// What is running here, for `PaneRecord.activity` and for the channel's
    /// `activityChanged`.
    ///
    /// Reads the classifier and not `agent?.label`, which substitutes the
    /// attention message when nothing is running. Under the old spelling an idle
    /// pane that rang reported "needs input" as its activity, in the same frame
    /// as it reported "needs input" as what it wanted.
    var activityLabel: String? { activityTracker.classifiedLabel }

    /// How hard this pane is asking, in the chrome's own vocabulary.
    ///
    /// ``lastAttention`` rather than a second derivation, for the reason
    /// `PaneStatus.Attention.init(_:)` exists: two copies of "is this pane asking"
    /// is one copy that can disagree with the footer the owner is looking at.
    var attentionState: PaneStatus.Attention { lastAttention }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("baia does not use nibs")
    }

    /// Everything this pane's shell is told, and the only channel macOS does not
    /// let another process read.
    ///
    /// Four entries, and each is a decision.
    ///
    /// `BAIA_PANE` keeps the value and the meaning it has always had: the pane's
    /// **public display id**, the persisted `PaneID`, which sits in `session.json`
    /// where any same-uid process can read it. It is not a credential and nothing
    /// authenticates on it.
    ///
    /// `BAIA_TOKEN` is the credential, and it is a different value for exactly
    /// that reason. 32 bytes from `SecRandomCopyBytes`, base64url, per pane per
    /// run, never persisted, and refused by the graph if it ever parsed as a pane
    /// id.
    ///
    /// `BAIA_SOCK` is where to talk, and it deliberately does not arrive through
    /// the terminal stream: rule 1 keeps every byte of this protocol off the PTY,
    /// so there is no escape sequence that could tell a pane where the channel is.
    ///
    /// `PATH` gains the bundle's `Contents/Helpers`, which is where the `baia`
    /// tool lives. That is what makes the tool exist exactly where the capability
    /// does: a shell outside baia has neither.
    ///
    /// **The socket and the token go in together or not at all.** An instance
    /// running without a channel injects neither, so its panes never reach the
    /// other instance's socket where their secrets are unknown. A pane whose mint
    /// failed injects neither for the mirror-image reason: a socket path with no
    /// token would send the reader looking at the registry when the truth is that
    /// this pane never got a capability.
    private var shellEnvironment: [String: String] {
        var environment = [
            "BAIA_PANE": paneID.rawValue.uuidString,
            // The accent the chrome resolved, so a prompt can wear the same
            // colour the footer draws this pane's name in. A shell cannot ask
            // for it any other way: `focusAccent` names a derivation, the theme
            // decides what it resolves to, and neither is on disk as a hex.
            //
            // `#rrggbb`, which zsh takes directly as `%F{$BAIA_ACCENT}` from 5.7
            // and every other shell can read as a colour. Read once when the
            // shell spawns, so a live theme edit reaches new panes and leaves the
            // running ones alone: re-exporting into a live process is not a thing
            // the kernel offers, and a prompt that redrew in a colour its pane
            // no longer uses would be worse than one that is a theme behind.
            "BAIA_ACCENT": theme.inkFocus.hexString,
        ]

        if let helpers = Self.helperDirectory {
            // Prepended to the app's own PATH rather than replacing it. The shell
            // ghostty spawns is a login shell, so `/etc/zprofile` runs
            // `path_helper`, which rebuilds PATH from `/etc/paths` and appends
            // whatever was already there behind it. Survival is what matters,
            // since nothing in `/usr/bin` is named `baia`.
            let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            environment["PATH"] = "\(helpers):\(inherited)"
        }

        if let controlSocketPath, let controlSecret {
            environment["BAIA_SOCK"] = controlSocketPath
            environment["BAIA_TOKEN"] = controlSecret.rawValue
        }

        return environment
    }

    /// `baia.app/Contents/Helpers`, or nil when there is no such directory.
    ///
    /// Checked rather than assumed. The copy phase that puts the tool there is a
    /// build setting, and a PATH entry naming a directory that does not exist
    /// would leave `command -v baia` empty with nothing on screen to say the
    /// embedding is what broke.
    private static let helperDirectory: String? = {
        let url = Bundle.main.bundleURL.appending(path: "Contents/Helpers", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        // Trailing slash dropped before this reaches PATH. `directoryHint:
        // .isDirectory` is right for the existence check and puts a `/` on the
        // end of the path string, which is the same URL trap `Anchor` already
        // canonicalizes for. It survives into `PATH`, so `command -v baia`
        // answers `…/Contents/Helpers//baia`, which resolves and reads as a bug
        // in the first place anybody looks.
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }()

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
            envVars: shellEnvironment
        )
        terminalView.controller = controller
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)
        view.addSubview(statusBar)
        // Added last so they sit above both. None can be hit, so ordering
        // costs the terminal nothing. liftView is added after edgeFrame, so
        // an attention frame and the focused-pane lift never fight over which
        // draws on top; in practice the two are mutually exclusive states
        // (attention outranks focus) and this ordering is a tie-break that
        // never triggers rather than a load-bearing one.
        for overlay in [scrim, edgeFrame, liftView] {
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

        for overlay in [scrim, edgeFrame, liftView] {
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
            guard let self else { return }
            refreshStatus()
            // Raised after the footer is rebuilt, so anything drawing the same read
            // elsewhere is redrawing from a poller that has already settled.
            onGitChange?()
        }

        // Weak, so the footer cannot keep the pane alive. `PaneTreeController`
        // is the only strong owner of a pane, and a leaked pane is a leaked
        // shell.
        statusBar.onClick = { [weak self] in self?.takeFocus() }

        activityTracker.onChange = { [weak self] in
            guard let self else { return }
            // Unconditional, so the footer keeps tracking the label.
            refreshStatus()

            // Edge-triggering, the ordering, and the source rule all live in
            // `ObservedPaneState`, which is pure and tested. `onChange` fires on
            // a timer for any change to the pane's whole state, so what escapes
            // to the channel has to be a transition rather than a heartbeat, and
            // that decision was eight lines here where nothing could check it.
            //
            // `activityLabel` is the same property `ControlAdapter.record` reads
            // for `PaneRecord.activity`, so a subscriber's bootstrap and its
            // stream speak one vocabulary.
            // The tracker is asked for the live report on every poll as well, so
            // an expiry reaches the chrome without a timer of its own.
            pushReportToTracker()
            for change in publishedState.changes(
                activity: activityTracker.activityReading,
                isAsking: activityTracker.wantsAttention,
                message: attentionMessage,
                report: reports.live(at: Date())
            ) {
                onObservableChange?(change.kind, change.message, change.activity, change.source)
            }

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

    /// Readable so the channel's read verbs report the same level the footer
    /// draws, and settable only here.
    private(set) var lastAttention: PaneStatus.Attention = .none

    /// The last values published to the control channel, held apart from
    /// `lastAttention`.
    ///
    /// `lastAttention` is the chrome's three-level value and drives the footer.
    /// The channel publishes the boolean the spec defines its events on plus the
    /// activity label, and collapsing the two would turn a footer change into a
    /// wire event or the reverse.
    private var publishedState = ObservedPaneState()

    /// The pane's own statement about itself, when it has made one.
    ///
    /// Per pane and per run, like the capability that reaches it. Nothing
    /// persists: a report describes a process that will not outlive a relaunch,
    /// and a restored one would be a claim about a pane that no longer exists.
    private var reports = ReportStore()

    /// Records a statement the pane made about itself and publishes at once.
    ///
    /// **Publishes rather than waiting for the next poll.** The tracker fires on
    /// a one-second timer, and a report is a synchronous answer to something that
    /// already happened: an agent that says it is blocked has stopped, and up to a
    /// second of the pane looking busy is the whole latency the verb exists to
    /// remove.
    ///
    /// A superseded report still runs the publish. It changes nothing, because
    /// the comparator sees no transition, and skipping it would make the fast
    /// path depend on the ordering rule agreeing with the comparator.
    func accept(report: PaneReport) {
        reports.accept(report)
        pushReportToTracker()
        activityTracker.onChange?()
    }

    /// Hands authority back to the pollers and publishes whatever they now say.
    func releaseReport() {
        reports.release()
        pushReportToTracker()
        activityTracker.onChange?()
    }

    /// Hands the tracker the live report, so the chrome and the channel read the
    /// same statement.
    ///
    /// **Before the publish, never after.** The publish derives both the wire
    /// event and the footer level, so a report pushed afterwards leaves the
    /// chrome a poll behind the channel: the subscriber is told the pane is
    /// asking and the pane the owner is looking at is still dark. That is a
    /// smaller version of the bug this whole change exists to fix.
    private func pushReportToTracker() {
        let live = reports.live(at: Date())
        activityTracker.setReportedBlock(
            live.map(\.state.isAsking),
            finished: live.map(\.state.isFinished),
            message: live?.message
        )
    }

    /// Set by `PaneTreeController` when the pane has a capability. Nil for a pane
    /// running without a channel, where the diff above is computed and thrown
    /// away, which costs two comparisons per poll.
    var onObservableChange: (
        (ControlEventKind, String?, String?, ControlEventSource?) -> Void
    )?

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
            agent: activityTracker.agent,
            notice: notice
        )
    }

    /// The sentence the footer is showing instead of its segments, and nil the
    /// rest of the time.
    ///
    /// Held here rather than written straight into `statusBar.status`, because
    /// the anchor tracker rebuilds that once a second: a notice written directly
    /// would survive for up to one poll and no longer, which is both too short to
    /// read and impossible to predict.
    private var notice: String?

    /// The work the notice timer is waiting to do, kept so a second refusal
    /// restarts the clock rather than inheriting the remains of the first one.
    private var noticeDismissal: DispatchWorkItem?

    /// Shows a sentence in the footer for a few seconds, then puts the bar back.
    ///
    /// **Three seconds, and the number is the only arbitrary thing here.** Long
    /// enough to read eleven words without hurrying, short enough that a bar
    /// showing stale text is never what the owner is looking at. Two refusals in
    /// a row restart it rather than queueing, since the second is the one being
    /// asked about.
    func showNotice(_ text: String) {
        noticeDismissal?.cancel()
        notice = text
        refreshStatus()

        let dismissal = DispatchWorkItem { [weak self] in
            guard let self else { return }
            notice = nil
            refreshStatus()
        }
        noticeDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeDuration, execute: dismissal)
    }

    private static let noticeDuration: TimeInterval = 3

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
        // **Activity is not gated on focus here, and the other two are.**
        // `windowDidResignKey` already leaves activity running for the reason
        // `windowDidBecomeKey` states: it is the one tracker whose whole purpose
        // is to notice something while the owner is looking elsewhere. This path
        // gated all three, so a pane appearing in a window that never becomes key
        // never started polling at all, and nothing else would ever start it: the
        // only other entry point is `windowDidBecomeKey`, which by definition
        // does not fire for such a window.
        //
        // The pane that matters is one a control-channel `split` opened in a
        // background window while the owner works in another app, which is the
        // exact case the feature exists for. Found 2026-07-30 by
        // `Diagnostics/control-channel/`, whose app is launched from a script and
        // is never key, so no pane in it ever reported activity.
        activityTracker.startPolling()
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
    /// Shortened to the last two components by ``DisplayPath``, the rule the
    /// shell prompt follows. A working directory under `$TMPDIR` is 76 characters
    /// of machine-generated prefix with the two words worth reading at the end,
    /// and the titlebar draws all of it.
    ///
    /// Read by whoever owns the window, because with several panes in one window
    /// only the focused pane may name it. A pane that set the title itself would
    /// have every pane fighting over it on every poll.
    var windowTitle: (title: String, subtitle: String) {
        guard let anchor = anchorTracker.anchor else { return ("baia", "") }
        let cwd = anchorTracker.workingDirectory?.path(percentEncoded: false) ?? ""
        let shown = DisplayPath.shortened((cwd as NSString).abbreviatingWithTildeInPath)
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
