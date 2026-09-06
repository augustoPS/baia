import AppKit
import BaiaSettings
import GhosttyTerminal
import GitWorkspace
import os
import PaneActivity
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
    /// window title and this pane's capsule are derived from.
    var onAnchorChange: (() -> Void)?

    /// Raised when the pane's shell exits. Closing the window here would be
    /// wrong once a window holds several panes.
    var onProcessClose: (() -> Void)?

    /// Raised when a cluster card hands work to the terminal: a new pane
    /// split beside this one, running `command` at `workingDirectory`. A pane
    /// owns no workspace, so its job ends at naming what it wants, and
    /// `PaneTreeController` (the one thing holding one) makes the pane
    /// through the same `split(pane:axis:workingDirectory:command:createdBy:)`
    /// the channel's `baia split --command` lands on.
    var onSplitCommandRequested: ((_ command: String, _ workingDirectory: String?) -> Void)?

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

    /// Everything this pane draws around its surface: the glass plane and
    /// wash, the capsule, the scrim, the attention frame and the focus lift.
    ///
    /// One object since 2026-09-04, so the Settings preview wears the same
    /// chrome for the same settings. This controller owned the six views and
    /// their rules until then; what it keeps is what only a pane knows: focus,
    /// window activation, the attention level and the corner it sits in, which
    /// it pushes into the stack, and the surface, which the stack never touches.
    private let chrome = PaneChromeStack()

    /// The capsule, for the segment clicks and card presentation below.
    private var clusterView: PaneClusterView { chrome.clusterView }

    /// The one card mechanism for this pane's capsule: place and changes both
    /// present through it, which is what makes "one card at a time" a
    /// property of the pane rather than a discipline every card keeps. Lazy
    /// beside the approval popover's own build-on-first-use shape (the
    /// popover itself is app-wide in `AppDelegate`; this is per pane because
    /// the card's toggle state is). It was load-bearing for a pane dialled to
    /// the retired `.footer` mode, where the capsule was never installed; the
    /// laziness is kept for its own sake, since the only touch is inside the
    /// click path and a pane whose card is never opened never constructs the
    /// panel at all.
    private lazy var clusterCards = ClusterCardController()

    /// Which segment summoned the card now up, or nil when none is. The
    /// toggle's memory: ``ClusterCardController`` can say a card is showing
    /// but cannot know whose, so this is what turns a second click on the
    /// same segment into a dismissal. Cleared in the card's `onDismiss`, so
    /// every exit (⎋, resign-key, switch, toggle) clears it once.
    ///
    /// **Also the one answer to "is a card up", through
    /// ``clusterCardIsShowing``.** Two call sites used to ask that question two
    /// ways — `showNotice` off `clusterCardRole != nil`, the toggle off the
    /// conjunction `clusterCards.isShowing && clusterCardRole == role` — and the
    /// two can disagree. `ClusterCardController`'s panel sets
    /// `hidesOnDeactivate`, so AppKit can order it out with no dismissal path
    /// run at all: `isShowing` false while this role is still set. The
    /// resign-key observer normally catches that and calls `dismiss()`, but
    /// `dismiss()` opens `guard panel.isVisible` and returns on an
    /// already-hidden panel without firing `onDismiss`, so the role survives its
    /// own card. Read one way, that stale role only costs a redundant no-op
    /// `dismiss()`; read the other way, the toggle's conjunction went false and
    /// a click on the same segment re-showed a card the owner had just lost, and
    /// `showNotice`'s dismissal could be skipped for a card AppKit had merely
    /// hidden rather than closed.
    private var clusterCardRole: PaneClusterSegmentRole?

    /// Whether a card is up over this pane's capsule, in one place.
    ///
    /// This and not ``ClusterCardController/isShowing``, for the reason
    /// ``applyClusterMode()`` gives for its own superview check: reading the
    /// lazy controller *builds* it, and building a floating panel for every pane
    /// that has never opened a card — which is most panes — is the cost that
    /// laziness exists to avoid. The role is
    /// written when a card is shown and cleared from its `onDismiss`, so it
    /// answers the same question without touching the panel.
    ///
    /// Where it can drift from the panel it is the *safe* direction, which is
    /// what makes it the one to keep: it can be set with the panel hidden (see
    /// ``clusterCardRole``), never clear with the panel visible, because every
    /// path that shows a card sets it first. So a caller acting on this either
    /// dismisses a card that is up, or calls a `dismiss()` that guards itself
    /// and returns.
    private var clusterCardIsShowing: Bool { clusterCardRole != nil }

    /// The changes card currently presented, weak so a dismissed card dies
    /// with its panel: the background read below lands through this, and a
    /// result arriving after dismissal must find nobody rather than a view
    /// kept alive to be updated invisibly.
    private weak var changesCard: ClusterChangesCardView?

    /// Whether the repository behind the open changes card has a commit for
    /// `HEAD` to name, from the same porcelain read that fills the rows
    /// (`# branch.oid (initial)` parses to ``RepositoryStatus/Head/unborn(_:)``).
    /// What ``DiffSplitCommand`` needs to pick its comparison; a row cannot
    /// know it. True until the read lands: the only command reachable before
    /// then is `Full diff`, and on the unborn repository that window is a
    /// transient git error ahead of the shell rather than a wrong diff.
    private var changesCardHeadExists = true

    /// The changes card's one-shot read, off the main actor for the observer's
    /// reason: forking git where the user is waiting would have the card
    /// competing with the terminal for the main queue. Lazy like
    /// ``clusterCards`` and touched only in the click path, so the closed gate
    /// builds none of this machinery.
    private lazy var clusterCardQueue = DispatchQueue(
        label: "gutons.baia.cluster-card", qos: .utility
    )

    /// The card read's own spawner, separate from the shared observer's so what
    /// each one costs stays legible. Lazy for ``clusterCardQueue``'s reason.
    private lazy var clusterGitCommand = GitCommand()

    /// Cancels the card's read when the card closes, so a read that outlives
    /// its card is torn down at the process boundary rather than left to finish
    /// for nobody.
    private var changesCardCancellation: SubprocessCancellation?

    /// The palette everything in this pane derives from, off the chrome stack.
    private var theme: PaneTheme { chrome.theme }

    /// What the capsule and the lift draw, off the chrome stack.
    private var resolvedChrome: ResolvedChrome { chrome.resolvedChrome }

    /// Which of the window's bottom corners this pane sits in.
    ///
    /// Straight through to the stack rather than stored here: unlike focus,
    /// theme and attention it moves for a different reason, the arrangement
    /// changed, and ``PaneTreeController`` is the only writer.
    var bottomCorners: BottomCorners {
        get { chrome.bottomCorners }
        set { chrome.bottomCorners = newValue }
    }

    var isPaneFocused: Bool { chrome.isPaneFocused }

    /// Whether this pane's window is the key window.
    ///
    /// Every pane recedes when the window is not key, including the focused one,
    /// so an inactive window reads as one recessed object rather than as a window
    /// that still has a live pane in it. macOS offers no other honest signal for
    /// this here, because the titlebar is transparent.
    var isWindowActive: Bool {
        get { chrome.isWindowActive }
        set { chrome.isWindowActive = newValue }
    }

    func setPaneFocused(_ focused: Bool) {
        guard chrome.isPaneFocused != focused else { return }
        chrome.isPaneFocused = focused
        // The cursor accent is the one part of the presentation that lives inside
        // the surface rather than on a view the stack can repaint, so it is pushed
        // through the controller here.
        applyTerminalConfiguration()
    }

    /// The last ``PaneChrome/PaneAppearance`` this pane was given, or nil
    /// before its first ``apply(_:)``.
    ///
    /// Read-only outward face for `DesignPanelController`'s dials: a dial that
    /// wants to move one field builds a modified copy of this value, or of
    /// `PaneAppearance.make(...)` when this is nil, and calls `apply(_:)` with
    /// the whole thing.
    private(set) var lastAppliedAppearance: PaneAppearance?

    /// The diff instrument the 2026-07-30 sighting lacked: a live config edit
    /// reported reaching new panes but not ones already open, and nothing was
    /// logging what a pane was actually handed on each pass.
    private static let appearanceLog = Logger(subsystem: "gutons.baia", category: "appearance")

    /// The one entry point for everything ``PaneAppearance`` carries.
    ///
    /// The thirteen chrome fields go to ``chrome`` in one call; the two poll
    /// intervals and the terminal configuration are this controller's own.
    func apply(_ appearance: PaneAppearance) {
        if let lastAppliedAppearance, lastAppliedAppearance != appearance {
            Self.appearanceLog.debug(
                "\(self.paneID.rawValue.uuidString, privacy: .public): \(Self.changedFields(from: lastAppliedAppearance, to: appearance), privacy: .public)"
            )
        }
        lastAppliedAppearance = appearance

        chrome.apply(appearance)
        gitPollInterval = appearance.gitPollInterval
        activityPollInterval = appearance.activityPollInterval

        // Both go through the controller rather than through the view.
        // Assigning `view.configuration` or `view.controller` has a `didSet`
        // that tears the surface down and respawns the shell, losing the
        // scrollback and whatever was running in the pane.
        //
        // **Which configuration, not just whether one applies.** Reading
        // `isSpawnedUnderGlass` here rather than branching on the live
        // `resolvedChrome` is deliberate: that property is frozen at this
        // pane's first configuration (see `spawnedUnderGlass`'s doc comment),
        // so a pane spawned under flat keeps taking
        // `appearance.terminalConfiguration` even after a live toggle moves
        // `resolvedChrome` to glass, and a pane spawned under glass keeps its
        // zeroed `background-opacity` even after a toggle moves back to flat.
        // Either direction, changing which configuration an already-running
        // pane receives would move its `window-padding-y` on a live surface,
        // which is a live grid resize and a SIGWINCH. Under glass the well
        // belongs to the plane and the wash, so the surface's own
        // `background-opacity` goes to zero rather than painting a second one
        // over them; under flat the surface keeps the settings-derived opacity.
        //
        // This is the first read of the frozen fact, and it runs at
        // registration, after `resolvedChrome` is assigned above and before
        // the view loads, which is what "at spawn" means concretely.
        let spawnConfiguration = isSpawnedUnderGlass
            ? appearance.glassClearTerminalConfiguration
            : appearance.terminalConfiguration
        applyTerminalConfiguration(spawnConfiguration, theme: appearance.terminalTheme)
    }

    /// The field names that moved between `lastAppliedAppearance` and
    /// `appearance`, comma-joined, for ``apply(_:)``'s diff log.
    private static func changedFields(from previous: PaneAppearance, to next: PaneAppearance) -> String {
        var changed: [String] = []
        if previous.theme != next.theme { changed.append("theme") }
        if previous.attentionStyle != next.attentionStyle { changed.append("attentionStyle") }
        if previous.attentionAccent != next.attentionAccent { changed.append("attentionAccent") }
        if previous.alertBehavior != next.alertBehavior { changed.append("alertBehavior") }
        if previous.gitPollInterval != next.gitPollInterval { changed.append("gitPollInterval") }
        if previous.activityPollInterval != next.activityPollInterval { changed.append("activityPollInterval") }
        if previous.resolvedChrome != next.resolvedChrome { changed.append("resolvedChrome") }
        if previous.liftParameters != next.liftParameters { changed.append("liftParameters") }
        if previous.rimParameters != next.rimParameters { changed.append("rimParameters") }
        if previous.backgroundOpacity != next.backgroundOpacity { changed.append("backgroundOpacity") }
        if previous.paneWashFloor != next.paneWashFloor { changed.append("paneWashFloor") }
        if previous.clusterCornerInset != next.clusterCornerInset { changed.append("clusterCornerInset") }
        if previous.clusterOpacity != next.clusterOpacity { changed.append("clusterOpacity") }
        if previous.terminalTheme != next.terminalTheme { changed.append("terminalTheme") }
        if previous.terminalConfiguration != next.terminalConfiguration { changed.append("terminalConfiguration") }
        if previous.glassClearTerminalConfiguration != next.glassClearTerminalConfiguration {
            changed.append("glassClearTerminalConfiguration")
        }
        return changed.joined(separator: ", ")
    }

    /// Raised when this pane's git read produced something new.
    ///
    /// The sidebar draws the same answer the capsule does, so it has to hear about a
    /// poll landing on the pane already in focus. Without this it would only refresh
    /// when focus moved, which is the case where nothing changed.
    var onGitChange: (() -> Void)?

    /// This pane's binding to the shared repository observer. Readable from
    /// outside so a surface can draw the focused pane's snapshot instead of
    /// starting a read of its own. Read-only on purpose: the root and the
    /// activity are set through this controller, so nothing outside can
    /// retarget a pane's repository.
    ///
    /// Lazy, because the centre is a main-actor static and the pane's
    /// initialiser runs before it needs one.
    private(set) lazy var repository = RepositoryService.shared.makeBinding()

    private lazy var activityTracker = PaneActivityTracker(
        foregroundPid: { [weak self] in self?.terminalView.foregroundPid }
    )

    /// Raised when the pane starts or stops asking for attention, so the window
    /// can badge itself and post a notification naming the project.
    var onAttentionChange: (() -> Void)?

    var wantsAttention: Bool { activityTracker.revision.wantsAttention }

    /// What this pane asked for, when it said so rather than only ringing.
    var attentionMessage: String? { activityTracker.revision.attentionMessage }

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

    /// The status cadence, which every pane shares: the observer polls per
    /// repository, so this sets one value for the process and the last pane to
    /// apply a settings change writes the same number as the first.
    private var gitPollInterval: TimeInterval {
        get { RepositoryService.shared.statusInterval }
        set { RepositoryService.shared.statusInterval = newValue }
    }

    private var activityPollInterval: TimeInterval {
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

    /// Whether this pane was configured for arrangement (B) — the surface
    /// extending under the bar, with the grid's inset coming from padding — at
    /// the moment its chrome was first resolved.
    ///
    /// `lazy`, so the first read freezes this pane's answer for its whole
    /// lifetime rather than re-deriving it from whatever ``resolvedChrome``
    /// becomes later. `ConfigurationCenter.apply(to:)` sets `resolvedChrome`
    /// and reads this property (through ``isSpawnedUnderGlass``, to decide
    /// which `TerminalConfiguration` to hand `applyTerminalConfiguration`)
    /// before this controller's view is ever touched, so in practice this
    /// freezes at spawn; `viewDidLoad`'s `terminalBottom` anchor reads the same
    /// frozen value later, which is what keeps the frame arrangement and the
    /// padding bump agreeing with each other.
    ///
    /// This is the property that stops a live chrome toggle — Reduce
    /// Transparency, a dark/light switch, an edited `chromeStyle` — from
    /// reaching either one: both a frame resize and a `window-padding-y`
    /// change on an already-spawned surface are a live grid resize, the
    /// `SIGWINCH` hazard the footer's fixed, focus-independent height was also
    /// written to close. The arrangement a pane was spawned with is the
    /// arrangement it keeps; a toggle takes effect for the next pane opened.
    private lazy var spawnedUnderGlass: Bool = {
        if case .glass = resolvedChrome { true } else { false }
    }()

    /// Read-only outward face of ``spawnedUnderGlass``, for
    /// `ConfigurationCenter.apply(to:)` to decide whether this pane's
    /// `TerminalConfiguration` needs the glass `background-opacity` zeroing
    /// (the padding bump keys off ``spawnedBottomArrangement`` instead, which
    /// knew whether there was a footer for the bump to clear). See
    /// ``spawnedUnderGlass``'s own doc comment for why the answer is frozen
    /// rather than read fresh from ``resolvedChrome`` on every call.
    var isSpawnedUnderGlass: Bool { spawnedUnderGlass }

    // **`spawnedBottomArrangement` and `bottomArrangementAtSpawn` stood here
    // until 2026-08-13**, freezing a `PaneBottomArrangement` beside
    // ``spawnedUnderGlass`` at the same moment and for the same reason. The
    // arrangement they carried named a bottom anchor and a padding, and two of
    // its three answers named the footer view, which is gone. With the mode
    // dial retired the call could only ever answer `.fullHeightClear`, so the
    // pair froze a value that could not vary; the enum is deleted and this went
    // with it. See `PaneClusterLayout.swift` for the measurement that cleared
    // the padding bump.
    //
    // The freeze itself is unaffected: ``spawnedUnderGlass`` is the fact that
    // could always move under a live toggle, it is still frozen, and
    // `ConfigurationCenter.apply(to:)` now reads it directly through
    // ``isSpawnedUnderGlass`` rather than through an arrangement.

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
    /// colour the capsule already draws the focused pane's name in. One accent in
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
    /// Read off the tracker rather than off ``status``, which is nil until
    /// the anchor first resolves: a pane whose `baia whoami` ran in that window
    /// would otherwise report no activity for a pane that had some.
    /// What is running here, for `PaneRecord.activity` and for the channel's
    /// `activityChanged`.
    ///
    /// Reads the classifier and not `agent?.label`, which substitutes the
    /// attention message when nothing is running. Under the old spelling an idle
    /// pane that rang reported "needs input" as its activity, in the same frame
    /// as it reported "needs input" as what it wanted.
    var activityLabel: String? { activityTracker.revision.activityLabel }

    /// How hard this pane is asking, in the chrome's own vocabulary.
    ///
    /// The tracker's published revision rather than a second derivation, for the
    /// reason `PaneStatus.Attention.init(_:)` exists: two copies of "is this pane
    /// asking" is one copy that can disagree with the chrome the owner is looking
    /// at.
    var attentionState: PaneStatus.Attention { activityTracker.revision.attentionState }

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
            // colour the capsule draws this pane's name in. A shell cannot ask
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
        view.addSubview(terminalView)
        // The whole chrome, above and below the surface, in the stacking the
        // stack's own doc comment records. `resolvedChrome` was set by
        // `ConfigurationCenter.apply(to:)` at registration, before the view
        // loaded, so this is where a glass-spawned pane's plane is created.
        chrome.install(in: view, around: terminalView)

        // Edge pinning alone leaves the hierarchy with no size of its own.
        // TerminalView has no intrinsic content size, so `fittingSize` collapses
        // to zero and a window using this controller as its contentViewController
        // shrinks to a 1x32 sliver. These two constraints supply a preferred size
        // at a priority the window can override when the user resizes.
        let preferredWidth = terminalView.widthAnchor.constraint(equalToConstant: 1024)
        let preferredHeight = terminalView.heightAnchor.constraint(equalToConstant: 680)
        preferredWidth.priority = .defaultLow
        preferredHeight.priority = .defaultLow

        // The surface runs to the view's own bottom edge, unconditionally.
        //
        // **This read a frozen `PaneBottomArrangement` until 2026-08-13, and
        // the ternary it fed is gone with the enum.** The two arms it used to
        // have both named the footer view: one pinned the surface to the bar's
        // top, the other ran full height and let a `window-padding-y` bump
        // clear the bar floating over the surface's last points. With the
        // footer deleted every pane runs clear to the bottom — nothing below it
        // to stop above, nothing over its last points to clear — so there is no
        // longer a choice to freeze here.
        //
        // The freeze this comment used to argue for still matters, it just
        // lives entirely in `ConfigurationCenter.apply(to:)` now, keyed on
        // ``isSpawnedUnderGlass``. The hazard is unchanged and worth restating
        // because this constraint is where it would bite: `viewDidLoad` runs
        // once and `resolvedChrome`'s `didSet` deliberately does not touch this
        // constraint, because re-pinning `terminalView.bottomAnchor` resizes
        // the view, and an `AppTerminalView` resize is the live grid resize
        // (`layout()` in `AppTerminalView+Lifecycle.swift`) that sends
        // `SIGWINCH` to whatever the pane is running. A live toggle — Reduce
        // Transparency, a dark/light switch, an edited `chromeStyle` — takes
        // effect for the next pane opened, never for one already running.
        let terminalBottom = terminalView.bottomAnchor.constraint(
            equalTo: view.bottomAnchor
        )

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalBottom,
            terminalView.heightAnchor.constraint(greaterThanOrEqualToConstant: 1),

            preferredWidth,
            preferredHeight,
        ])

        anchorTracker.onChange = { [weak self] in
            guard let self else { return }
            // Handed the repository root on every change, and the binding
            // returns immediately unless the root actually moved. Without that
            // guard this would release and re-resolve once a second per pane.
            // The root and nothing else: `GitWorkspace` takes URLs, and a plain
            // anchor hands over nil so the pane draws no git rows at all.
            repository.setRepositoryURL(Anchor.repositoryRoot(of: anchorTracker.anchor))
            refreshStatus()
            onAnchorChange?()
        }

        repository.onChange = { [weak self] _ in
            guard let self else { return }
            refreshStatus()
            // Raised after the capsule is rebuilt, so anything drawing the same
            // snapshot elsewhere is redrawing from a publication that has
            // already landed. Fires for the nil the binding publishes on a root
            // change too, which is what clears the sidebar at once.
            onGitChange?()
        }

        // Assigned unconditionally, and live on every pane since the mode dial
        // retired (2026-08-13). It was inert under `.footer`, where the only
        // view that raises it was never added to the hierarchy; no pane can
        // be in that state now.
        clusterView.onSegmentClick = { [weak self] role, segmentRect in
            self?.clusterSegmentClicked(role, segmentRect: segmentRect)
        }

        // A card outlives neither the segment it is anchored to nor the pill it
        // hangs off. Live on every pane with `onSegmentClick` above, and for
        // the same reason: the capsule is in every hierarchy now.
        clusterView.onSegmentsVanished = { [weak self] roles in
            self?.clusterSegmentsVanished(roles)
        }

        activityTracker.onChange = { [weak self] revision in
            guard let self else { return }
            // Unconditional, so the capsule keeps tracking the label.
            refreshStatus(activity: revision)

            // Edge-triggering, the ordering, and the source rule all live in
            // `ObservedPaneState`, which is pure and tested. `onChange` fires on
            // a timer for any change to the pane's whole state, so what escapes
            // to the channel has to be a transition rather than a heartbeat, and
            // that decision was eight lines here where nothing could check it.
            //
            // `activityLabel` is the same property `ControlAdapter.record` reads
            // for `PaneRecord.activity`, so a subscriber's bootstrap and its
            // stream speak one vocabulary.
            for change in publishedState.changes(
                activity: revision.activityReading,
                isAsking: revision.wantsAttention,
                message: revision.attentionMessage,
                report: revision.report.live
            ) {
                onObservableChange?(change.kind, change.message, change.activity, change.source)
            }

            // The upward callback is not. `onChange` fires for any change to the
            // whole agent value, and the label changes as a build walks its
            // targets, so raising attention from here re-bounced the Dock and
            // re-posted the banner on every poll of a pane that was merely
            // compiling. Only a real transition of the attention state escapes.
            //
            // Read from the tracker rather than from ``status``, which is
            // nil until the anchor first resolves. A bell arriving in that window
            // used to leave the level at `.none`, and since `refreshStatus` does
            // not re-enter this block, an idle pane that rang once could sit there
            // asking with nothing drawn and no notification posted.
            let now = revision.attentionState
            guard now != lastAttention else { return }
            lastAttention = now
            // The frame follows the level, so it is pushed here rather than
            // from `refreshStatus`, which fires on every poll of a pane that is
            // merely compiling.
            chrome.attention = now
            onAttentionChange?()
        }
    }

    /// Readable so the channel's read verbs report the same level the capsule
    /// draws, and settable only here.
    private(set) var lastAttention: PaneStatus.Attention = .none

    /// Everything this pane currently says about itself: anchor, git, agent,
    /// and any notice taking the chrome over. Nil until the anchor first
    /// resolves.
    ///
    /// **The pane's store, not a view's (2026-08-13).** This lived on
    /// `statusBar.status` until the footer was scheduled for deletion, which
    /// made a retired view the source of truth for five readers that have
    /// nothing to do with drawing a footer: the window title and subtitle, the
    /// capsule's segments, the approval card's title, ``tabPath`` and
    /// ``tabTitle(project:budget:)``. The bar was already hidden on every pane
    /// (by `chrome.cluster.mode`'s default, and unconditionally since that key
    /// retired the next day), so those readers were reaching into a view the
    /// owner had switched off, and deleting the file would have deleted the
    /// pane's state with it.
    ///
    /// Written at exactly one point, ``refreshStatus()``, which then hands the
    /// value down. `private(set)` so that stays true: a second writer is how
    /// the readers would start disagreeing.
    private(set) var status: PaneStatus?

    /// The last values published to the control channel, held apart from
    /// `lastAttention`.
    ///
    /// `lastAttention` is the chrome's three-level value and drives the capsule.
    /// The channel publishes the boolean the spec defines its events on plus the
    /// activity label, and collapsing the two would turn a chrome change into a
    /// wire event or the reverse.
    private var publishedState = ObservedPaneState()

    /// Records a statement the pane made about itself and publishes at once.
    ///
    /// **Publishes rather than waiting for the next poll.** The tracker fires on
    /// a one-second timer, and a report is a synchronous answer to something that
    /// already happened: an agent that says it is blocked has stopped, and up to a
    /// second of the pane looking busy is the whole latency the verb exists to
    /// remove.
    ///
    /// The tracker owns ordering, expiry and publication as one timeline. This
    /// controller only hands over the report that arrived.
    func accept(report: PaneReport) {
        activityTracker.accept(report: report)
    }

    /// What `baia explain` answers about this pane. Values copied across, no
    /// decision made: the reasons are the packages' own words, the report is
    /// the store's last statement with its liveness read now, and the attention
    /// word is the one `PaneRecord.attention` shows.
    func explain(paneID: String) -> PaneExplanation {
        let now = Date()
        let (activity, revision) = activityTracker.explain()
        let activityReason: String
        if let activity,
           PaneActivityTracker.reading(of: activity.activity) == revision.activityReading {
            activityReason = activity.reason
        } else if activity == nil {
            activityReason = "the pane has no foreground process right now; effective activity "
                + "remains the last published revision rather than being read as idle"
        } else {
            activityReason = "current process evidence differs from the last published activity "
                + "revision; list and explain keep the published value until the activity tracker "
                + "advances it"
        }
        let report = revision.report.last.map { held in
            PaneExplanation.Report(
                state: held.state,
                message: held.message,
                seq: held.seq,
                live: revision.report.live != nil,
                secondsLeft: Int(held.expires.timeIntervalSince(now).rounded(.down))
            )
        }
        return PaneExplanation(
            pane: paneID,
            hasForeground: activity != nil,
            processes: (activity?.processes ?? []).map { verdict in
                PaneExplanation.Process(
                    pid: verdict.pid,
                    parentPid: verdict.parentPid,
                    depth: verdict.depth,
                    matched: verdict.matched,
                    verdict: Self.word(for: verdict.verdict),
                    won: verdict.won
                )
            },
            activity: revision.activityLabel,
            activityReading: revision.activityReading.explained,
            activityReason: activityReason,
            report: report,
            latch: revision.attention.latch.name,
            seen: revision.attention.seen,
            attention: PaneStatus.Attention.name(of: revision.attentionState),
            attentionDecidedBy: revision.attention.authority.rawValue,
            attentionReason: revision.attention.reason
        )
    }

    private static func word(for verdict: ActivityExplanation.Verdict) -> String {
        switch verdict {
        case .paneShell: "pane shell"
        case .shell: "shell"
        case .agent: "agent"
        case .build: "build"
        case .command: "command"
        case .unnameable: "unnameable"
        case .outsidePane: "outside the pane"
        }
    }

    /// Hands authority back to the pollers and publishes whatever they now say.
    func releaseReport() {
        activityTracker.releaseReport()
    }

    /// Set by `PaneTreeController` when the pane has a capability. Nil for a pane
    /// running without a channel, where the diff above is computed and thrown
    /// away, which costs two comparisons per poll.
    var onObservableChange: (
        (ControlEventKind, String?, String?, ControlEventSource?) -> Void
    )?

    /// Rebuilds this pane's ``status`` from the anchor, then hands it to every
    /// surface that draws from it. Git and agent state are left nil until their
    /// subsystems are wired, and `PaneClusterSegments` already suppresses those
    /// segments rather than rendering placeholders.
    ///
    /// **The one write.** ``status`` is `private(set)` and this is the only
    /// place it moves, which is what lets the capsule and the five readers
    /// listed on ``status`` be renderings of one value rather than separate
    /// constructions that agree today.
    private func refreshStatus(activity revision: PaneActivityTracker.Revision? = nil) {
        guard let anchor = anchorTracker.anchor else {
            status = nil
            clusterView.segments = []
            return
        }
        let revision = revision ?? activityTracker.revision
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
        let rebuilt = PaneStatus(
            anchorName: anchor.displayName,
            anchorIsRepository: anchor.kind == .repository,
            isPinned: anchor.source == .pinned,
            workingDirectory: shown,
            git: repository.git,
            agent: revision.agent,
            notice: notice
        )
        status = rebuilt
        // The capsule's segments from the one value that was just built, never
        // from a second construction. This used to read back off
        // `statusBar.status`, which worked but bought it by making the footer
        // the store; the local is the same guarantee without the view in the
        // middle, and it is what survived that view's deletion.
        clusterView.segments = PaneClusterSegments.build(from: rebuilt)
    }

    // MARK: - Cluster cards

    /// Routes a capsule click to its card. Agent and attention share one
    /// card: the two segments describe one thing, the agent in the pane and
    /// how hard it is asking, and two cards would carve that sentence in
    /// half.
    /// Takes the card down when the segment it was anchored to leaves the pill.
    ///
    /// **The one response to "a segment stopped existing", for every way that
    /// can happen.** The rule itself is old and was stated on ``showNotice(_:)``:
    /// a card anchored to a segment that is no longer there hangs beside a pill
    /// that no longer says what it is about, wears no active wash (the pill
    /// washes off the placement, and the role is not in it), and cannot be
    /// dismissed by clicking the segment again because there is no segment to
    /// click — only ⎋ or a click elsewhere takes it down. What was wrong is that
    /// `showNotice` *implemented* that rule as well as stating it, so the rule
    /// held for exactly the one path that remembered it. The fitting pass added
    /// a second path — a divider dragged narrow drops a role
    /// (``PaneChrome/PaneClusterLayout/fitting(segments:widths:budget:)``) — and
    /// the card stayed up.
    ///
    /// So the notice no longer dismisses anything itself: it writes the notice,
    /// `refreshStatus` re-measures, the pill loses every resting segment, and
    /// this fires with them. One concept, one signal
    /// (``PaneClusterView/onSegmentsVanished``), one response.
    ///
    /// ``clusterCardIsShowing`` rather than the panel, for that property's own
    /// reason: reading the lazy controller builds it, and a pane whose capsule
    /// merely re-measured has no business constructing a floating panel.
    private func clusterSegmentsVanished(_ roles: [PaneClusterSegmentRole]) {
        guard clusterCardIsShowing, let open = clusterCardRole, roles.contains(open)
        else { return }
        // `dismiss()` clears `clusterCardRole` and the pill's active wash
        // through the card's `onDismiss`, so the wash cannot outlive the segment
        // it was highlighting.
        clusterCards.dismiss()
    }

    private func clusterSegmentClicked(
        _ role: PaneClusterSegmentRole, segmentRect: NSRect
    ) {
        // The notice opens nothing, on the role's own
        // ``PaneClusterSegmentRole/opensCard``. `PaneClusterView.mouseDown`
        // already stops before raising it, so this is unreachable today and
        // deliberately kept: the predicate lives in one place, and a future
        // caller that raises a click by some other route (a keyboard path, a
        // probe driving the handler directly) meets the same rule here instead
        // of presenting a card anchored to a segment that will vanish in three
        // seconds. Before the toggle, because a notice that arrived while a
        // card was up has already dismissed that card (`showNotice(_:)`).
        guard role.opensCard else { return }

        // The toggle: a second click on the segment whose card is up
        // dismisses instead of reopening. Any other segment falls through and
        // `show` swaps the card, which is the controller's own contract.
        //
        // The role alone, through ``clusterCardIsShowing``, and not the old
        // conjunction with `clusterCards.isShowing`: see that property for why
        // the two could disagree and why this is the half to keep. The
        // conjunction also touched the lazy panel on every click of every
        // segment, which is the build this pane's laziness exists to defer.
        if clusterCardIsShowing, clusterCardRole == role {
            clusterCards.dismiss()
            return
        }
        guard let window = view.window else { return }
        // The view hands the rect in its own coordinates; the controller's
        // contract is host-window coordinates.
        let anchor = clusterView.convert(segmentRect, to: nil)
        // The same derivation `ConfigurationCenter.windowIsDark` feeds the
        // approval popover's `isDark` from, read off this pane's own theme
        // (the center pushes that theme here, so the input is the same
        // value): chrome follows the theme, never the system. Written at
        // presentation rather than from `theme.didSet`, because a property
        // write there would build the lazy panel on every themed pane with
        // the gate off.
        clusterCards.isDark = windowIsDark(paneTheme: theme)
        switch role {
        // The operation shares the place card rather than opening one of its
        // own, the same argument agent and attention share theirs: the two
        // segments describe one thing. A half-finished rebase is a statement
        // about *where this pane is* — it is why the branch reads as a detached
        // hash — so its detail belongs beside the branch it qualifies, not in a
        // second panel the owner would have to compare against the first.
        case .operation, .place: presentPlaceCard(anchoredTo: anchor, in: window)
        case .changes: presentChangesCard(anchoredTo: anchor, in: window)
        case .agent, .attention: presentAttentionCard(role, anchoredTo: anchor, in: window)
        // Unreachable past the `opensCard` guard above, and spelled out rather
        // than swept into a `default`: a role added later gets a compiler error
        // here demanding a card, which is the question worth being asked.
        case .notice: break
        }
    }

    /// Shows a card and records which segment summoned it, the one sequence
    /// every presenter below runs and the only place it is written.
    ///
    /// After `show`, never before: switching cards makes `show` dismiss the
    /// one already up, and that dismissal fires the OLD card's `onDismiss`,
    /// which nils the role. A role assigned first would be consumed by the
    /// old card's teardown and the toggle would go blind, the same
    /// consumed-by-old-teardown race `ClusterCardController`'s
    /// `onDismiss`-as-parameter shape exists to close. `activeRole` — the
    /// capsule's hot wash on the summoning segment (owner ruling, 2026-08-12)
    /// — rides the same rule for the same reason, and is cleared in the same
    /// `onDismiss`, so the wash cannot outlive its card or be wiped by the
    /// outgoing one's teardown.
    private func presentCard(
        _ content: NSView,
        role: PaneClusterSegmentRole,
        anchoredTo anchor: NSRect,
        in window: NSWindow,
        invalidateActions: @escaping () -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        clusterCards.show(
            content: content,
            anchoredTo: anchor,
            in: window,
            invalidateActions: invalidateActions
        ) { [weak self] in
            onDismiss?()
            self?.clusterCardRole = nil
            self?.clusterView.activeRole = nil
        }
        clusterCardRole = role
        clusterView.activeRole = role
    }

    /// Builds and presents the place card from what this pane already holds:
    /// the anchor, and the same `PaneStatus.Git` the capsule's place segment
    /// was built from.
    private func presentPlaceCard(anchoredTo anchor: NSRect, in window: NSWindow) {
        guard let paneAnchor = anchorTracker.anchor else { return }
        // The footer's stale-facts rule, kept: a plain directory renders no
        // git rows. The binding already publishes nil on the way out of a
        // repository, and this keeps the rule legible at the one site it matters.
        let git = paneAnchor.kind == .repository ? repository.git : nil

        let directoryPath = (anchorTracker.workingDirectory ?? paneAnchor.url)
            .path(percentEncoded: false)
        let home = FileManager.default
            .homeDirectoryForCurrentUser
            .path(percentEncoded: false)

        // In a linked worktree the anchor *is* the worktree, so its name fills
        // ``ClusterPlaceCardModel/worktreeName`` and the repository row wants
        // the main checkout's name instead —
        // ``GitWorkspace/GitDirectory/mainCheckoutName(forLinkedWorktreeRoot:)``'s
        // three-components-up walk, or the worktree's own name when the
        // pointer cannot be resolved, which is what the tab already shows.
        let mainCheckoutName = Anchor.repositoryRoot(of: paneAnchor)
            .flatMap { GitDirectory.mainCheckoutName(forLinkedWorktreeRoot: $0) }

        // ``PaneChrome/PaneStatus/Git/displayableOperation``: the same
        // *predicate* the pill's segment is built from, not merely the same
        // field. Sharing the input is not sharing the derivation, and this
        // line proved it — it read `git?.operation` raw while
        // `PaneClusterSegments.build` applied `isBlank`, so a poller handing
        // over `"   "` drew no pill segment and grew a card row captioned
        // `operation` with a blank value in it (found 2026-08-13).
        //
        // What is guaranteed now is narrow and worth stating exactly: both
        // surfaces call one function on one value, so for a given
        // `PaneStatus.Git` either both draw the operation and draw the same
        // string, or neither draws it. The card can still *lack* a row the
        // pill has, and does — the pill takes segments only while a notice is
        // not up, and the stale-facts rule nils `git` here for a plain
        // directory the same way it drops the pill's git segments. Agreement
        // on the blank case is pinned by
        // `PaneClusterSegmentsTests.theCardAndThePillAgreeOnWhatCountsAsAnOperation`.
        let card = ClusterPlaceCardView(model: .make(
            anchorDisplayName: paneAnchor.displayName,
            isLinkedWorktree: git?.isLinkedWorktree == true,
            mainCheckoutName: mainCheckoutName,
            git: git,
            workingDirectoryPath: directoryPath,
            home: home
        ))
        // The effects live here rather than in the card, the sidebar's own
        // split: a row raises a closure, the owner acts. Both act on the full
        // path, never the drawn abbreviation. Copying through
        // `NSPasteboard` is the user's own copy, untouched by the OSC 52
        // denials, which gate the terminal's escape-sequence route only.
        card.onCopyPath = { [weak self] in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(directoryPath, forType: .string)
            self?.clusterCards.dismiss()
        }
        card.onReveal = { [weak self] in
            NSWorkspace.shared.selectFile(directoryPath, inFileViewerRootedAtPath: "")
            self?.clusterCards.dismiss()
        }
        card.onClose = { [weak self] in self?.clusterCards.dismiss() }

        presentCard(
            card,
            role: .place,
            anchoredTo: anchor,
            in: window,
            invalidateActions: { [weak card] in card?.invalidateActions() }
        )
    }

    /// Presents the changes card, then runs the observer's own porcelain read
    /// for a fresh answer. The card opens with only its `Full diff` row and
    /// grows when the result lands; the snapshot's `changes` is deliberately
    /// not used to seed it, because a card is opened to act on what is true
    /// now and the snapshot is up to a poll interval old.
    private func presentChangesCard(anchoredTo anchor: NSRect, in window: NSWindow) {
        guard let root = Anchor.repositoryRoot(of: anchorTracker.anchor) else { return }
        // The diff commands run at the repository root, not the shell's
        // subdirectory: the porcelain's paths are root-relative, and a
        // pathspec handed to a `git diff` running elsewhere in the tree
        // would name a file it cannot match.
        let rootPath = root.path(percentEncoded: false)

        let card = ClusterChangesCardView()
        // The commands are built here, not in the card, because only this
        // controller holds the two facts `DiffSplitCommand` keys on: whether
        // the row is untracked, and whether the repository has a `HEAD` yet.
        card.onFileDiff = { [weak self] change in
            guard let self else { return }
            handOff(
                DiffSplitCommand.file(
                    path: change.path,
                    isUntracked: change.kind == .untracked,
                    headExists: changesCardHeadExists
                ),
                at: rootPath
            )
        }
        card.onFullDiff = { [weak self] in
            guard let self else { return }
            handOff(DiffSplitCommand.fullDiff(headExists: changesCardHeadExists), at: rootPath)
        }
        card.onClose = { [weak self] in self?.clusterCards.dismiss() }

        presentCard(
            card,
            role: .changes,
            anchoredTo: anchor,
            in: window,
            invalidateActions: { [weak card] in card?.invalidateActions() },
            onDismiss: { [weak self, card] in
                guard let self, self.changesCard === card else { return }
                // Every dismissal route tears down the card's read: close,
                // toggle, replacement, and resign-key all enter this one
                // presentation cleanup. The identity guard prevents an old
                // handler from cancelling a replacement card's work.
                self.changesCardCancellation?.cancel()
                self.changesCardCancellation = nil
                self.changesCard = nil
            }
        )
        changesCard = card
        changesCardHeadExists = true

        // The same invocation the observer's status read runs, flags and all
        // (`GitCommand.readStatus` owns them), on a utility queue with the
        // answer hopped back to main. Landing on the weak card means a result
        // that outlives its card updates nothing; a read that failed or was
        // cancelled leaves the card on its `Full diff` row.
        let command = clusterGitCommand
        let cancellation = SubprocessCancellation()
        changesCardCancellation?.cancel()
        changesCardCancellation = cancellation
        clusterCardQueue.async { [weak self, weak card] in
            let read = command.readStatus(ofRepositoryRoot: root, cancellation: cancellation)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let card, self.changesCard === card,
                          case let .success(reading) = read
                    else { return }
                    var headExists = true
                    if case .unborn = reading.status.head { headExists = false }
                    self.changesCardHeadExists = headExists
                    card.changes = reading.changes
                }
            }
        }
    }

    /// Builds and presents the attention card from the same `PaneStatus` the
    /// capsule's segments were built from, read back off the bar the way
    /// `refreshStatus` wrote it. No agent-or-attention guard on purpose: the
    /// two segments only exist while the status carries those facts
    /// (`PaneClusterSegments.build`), so the route is unreachable without
    /// them and the optionals below already make each row absent rather than
    /// blank.
    ///
    /// The model comes from
    /// ``PaneChrome/ClusterAttentionCardModel/make(status:attentionMessage:)``,
    /// which applies `ApprovalPopover.presents(for:)` as its own gate and the
    /// `agent · repo` title rule; this method's job ends at handing over
    /// `status` and `attentionMessage` and wiring the card's effects. There is
    /// no stored pending-approval object anywhere: the model is rebuilt at
    /// click time from the pane's own state and the answer goes straight to
    /// `pane.send(ApprovalPopover.bytes(for:))`, because the pane already owns
    /// `send(_:)`.
    ///
    /// This is the only door onto an approval: the standalone popover and its
    /// controller (design v5 §6) retired in Task 4, and every fact they
    /// carried — the gate, the title rule, the `body(for:)` fallback, the
    /// single answering keystroke — lives in ``PaneChrome/ClusterAttentionCardModel``
    /// and ``PaneChrome/ApprovalPopover`` now, in one copy rather than echoed
    /// between two doors.
    ///
    /// - Parameter role: which of the two segments summoned the card, stored
    ///   as the toggle's memory. Tracking the summoning segment rather than a
    ///   single shared role keeps the toggle per segment: a second click on
    ///   the same segment dismisses, a click on the sibling re-presents the
    ///   card anchored there, the same swap any other segment pair gets.
    private func presentAttentionCard(
        _ role: PaneClusterSegmentRole, anchoredTo anchor: NSRect, in window: NSWindow
    ) {
        let card = ClusterAttentionCardView(
            model: .make(status: status, attentionMessage: attentionMessage),
            theme: theme
        )
        card.onApprovalAction = { [weak self, weak card] action in
            guard let self else { return }
            // One answer only: `card?.onApprovalAction = nil` before acting
            // means a double commit (a button click racing ⏎/⎋) sends
            // nothing the second time.
            card?.onApprovalAction = nil
            // Dismiss before the bytes: key is back with the host window
            // before the keystroke lands in the pane.
            clusterCards.dismiss()
            send(ApprovalPopover.bytes(for: action))
        }
        card.onClose = { [weak self] in self?.clusterCards.dismiss() }

        // `role` here is `.attention` or `.agent`, whichever segment was
        // clicked — ``presentCard(_:role:anchoredTo:in:)`` carries the wash
        // to that same segment, the per-segment memory the toggle keeps.
        presentCard(
            card,
            role: role,
            anchoredTo: anchor,
            in: window,
            invalidateActions: { [weak card] in card?.invalidateActions() }
        )
    }

    /// Hands a card's command to the terminal and dismisses the card.
    ///
    /// Checked against `ControlWire.refusalForCommand` first, though no
    /// card-built command should trip it: the value is rendered into a
    /// ghostty config file parsed line by line, and a filename carrying a
    /// newline would otherwise write a config key of the caller's choosing
    /// (`Diagnostics/split-command/README.md`, the refusal half). A refused
    /// command hands off nothing and the card stays up, which is at least
    /// honest about nothing having happened.
    private func handOff(_ command: String, at directory: String) {
        guard ControlWire.refusalForCommand(command) == nil else { return }
        onSplitCommandRequested?(command, directory)
        clusterCards.dismiss()
    }

    /// The sentence the capsule is showing instead of its segments, and nil the
    /// rest of the time.
    ///
    /// Held here rather than written straight into ``status``, because
    /// the anchor tracker rebuilds that once a second: a notice written directly
    /// would survive for up to one poll and no longer, which is both too short to
    /// read and impossible to predict.
    private var notice: String?

    /// The work the notice timer is waiting to do, kept so a second refusal
    /// restarts the clock rather than inheriting the remains of the first one.
    private var noticeDismissal: DispatchWorkItem?

    /// Shows a sentence in this pane's chrome for a few seconds, then puts the
    /// resting facts back.
    ///
    /// **Three seconds, and the number is the only arbitrary thing here.** Long
    /// enough to read eleven words without hurrying, short enough that a bar
    /// showing stale text is never what the owner is looking at. Two refusals in
    /// a row restart it rather than queueing, since the second is the one being
    /// asked about.
    ///
    /// **One path, and nothing here knows what is on the other end of it.** The
    /// notice is written into ``PaneStatus/notice`` and ``refreshStatus()``
    /// rebuilds the capsule's segments from that one value —
    /// `PaneClusterSegments.build(from:)` returns the notice alone, for the
    /// reason stated there. The takeover used to happen on whichever surface
    /// `chrome.cluster.mode` had installed; since that dial retired
    /// (2026-08-13) the capsule is the only surface on screen, and this path
    /// stays ignorant of that rather than learning it, because a writer that
    /// knows its readers is a writer that has to be edited when they change.
    ///
    /// A card open over this pane's capsule comes down with the segment it was
    /// anchored to, but **not from here** — see
    /// ``clusterSegmentsVanished(_:)``. The notice takes the pill alone, so
    /// every resting segment stops existing for those three seconds, and that is
    /// the same event a divider dragged narrow produces. This function used to
    /// dismiss the card itself, which made the rule true for the notice path and
    /// false for the fitting one: `refreshStatus()` below re-measures the pill,
    /// the resting segments leave the placement, and the view's
    /// ``PaneClusterView/onSegmentsVanished`` raises it once for whatever caused
    /// it. One concept, one response, and a third cause invented later is
    /// covered without editing this comment.
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
        repository.isActive = view.window?.isKeyWindow == true
        if view.window?.isKeyWindow == true {
            anchorTracker.startPolling()
        }
    }

    /// A pane that leaves the window stops presentation-owned reads. Activity and
    /// report expiry stay live because a zoom removes this view while the
    /// workspace still owns its terminal and process.
    override func viewDidDisappear() {
        super.viewDidDisappear()
        anchorTracker.stopPolling()
        repository.isActive = false
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
        // Per pane, which is per subscriber on the shared observer: a root is
        // read while any of its subscribers is in a key window, so one window
        // resigning key cannot silence a repository another window shows.
        repository.isActive = true
        // Activity keeps polling while the window is unfocused. It is the one
        // tracker whose whole purpose is to notice something while the user is
        // looking elsewhere, so gating it on focus would disable the feature
        // exactly when it matters.
        activityTracker.startPolling()
    }

    @objc private func windowDidResignKey() {
        anchorTracker.stopPolling()
        repository.isActive = false
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        activityTracker.stopTracking()
        // The root goes with the pane: the last pane on a repository stops its
        // watch and its polling here rather than when the binding happens to
        // deallocate.
        repository.releaseRoot()
        changesCardCancellation?.cancel()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        terminalView.fitToSize()
        chrome.layoutDidChange()
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
            isWorktree: status?.git?.isLinkedWorktree ?? false
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
        // The stale-facts guard, asked here rather than inherited. Until
        // 2026-08-13 this built the footer's whole segment table and picked the
        // `.indicators` row out of it, which meant the table's own
        // `anchorIsRepository` check suppressed the markers for free on a pane
        // that had `cd`-ed out of a repository while still holding its git
        // facts. The table is gone, so the check is spelled: a marker string on
        // a directory that has no branch is a fact the owner would act on.
        let git = status.flatMap { $0.anchorIsRepository ? $0.git : nil }
        let markers = git.map(PaneGitRuns.markerText(for:)) ?? ""
        return TabTitle.tab(
            project: project,
            branch: git?.head,
            // From the resolver rather than from the name of the branch. A
            // repository whose default is `develop` showed `:develop` on every tab
            // forever, and one defaulting to `main` said nothing at all on a branch
            // called `master`, which is the state worth shouting about.
            isDefaultBranch: repository.isOnDefaultBranch,
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

    /// The chrome follows both directions, because the pane losing focus has to
    /// stop drawing its focus expression. Only the gaining side is reported upward:
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
