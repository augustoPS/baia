import AppKit
import PaneActivity
import PaneChrome
import PaneControl

/// One pane's answer to "what is running here, and does it want me?"
///
/// Those are two questions with two sources, deliberately kept apart. What is
/// running comes from the kernel and is always available. Whether the pane wants
/// the user cannot be read from a process tree at all: an agent thinking and an
/// agent waiting at a prompt are both a live `node` doing very little, and a CPU
/// threshold would give a confident answer that is wrong about half the time.
/// That second question is answered only when the pane says so, through a bell
/// or an OSC 9 notification.
@MainActor
final class PaneActivityTracker {
    var onChange: (() -> Void)?

    private(set) var agent: PaneStatus.Agent?

    /// Supplied by the pane, because reading it means reaching into a terminal
    /// surface and this type never does.
    private let foregroundPid: () -> pid_t?

    private var attention = PaneAttentionState()

    /// Whether the pane has said it is blocked, and what it said, or nil when it
    /// has made no statement.
    ///
    /// **Here rather than only on the controller, so one place still answers
    /// "does this pane want the owner".** That is the rule
    /// `PaneStatus.Attention.init` states about itself, being "the only copy of
    /// that derivation anywhere", and the bug this fixes is what happens when a
    /// second answer exists: `report` reached the channel's comparator and not
    /// this, so a reported block published `attentionRaised` and drew nothing.
    ///
    /// Set by the controller before it publishes, never polled from here. The
    /// store that decides liveness and expiry lives with the controller beside
    /// the rest of the pane's per-run state.
    private var reportedBlock: Bool?
    private var reportedMessage: String?
    private var activity: PaneActivity = .idleShell
    private var timer: Timer?

    /// Seconds between reads, from `activityPollSeconds`.
    ///
    /// Slower than the anchor's poll by default. Walking every process on the
    /// machine is more expensive than one `proc_pidinfo` call, and a label naming
    /// what is running does not need to be current to the second.
    ///
    /// Restarted in place when it changes, so a live config edit takes effect
    /// rather than waiting for the window to lose and regain key.
    var pollInterval: TimeInterval = defaultPollInterval {
        didSet {
            guard pollInterval != oldValue, timer != nil else { return }
            stopPolling()
            startPolling()
        }
    }

    static let defaultPollInterval: TimeInterval = 2

    init(foregroundPid: @escaping () -> pid_t?) {
        self.foregroundPid = foregroundPid
    }

    func startPolling() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
    }

    /// No `deinit` counterpart, for the same reason as the other trackers: Swift
    /// 6 forbids touching a non-Sendable `Timer` from a nonisolated deinit, and a
    /// scheduled timer is retained by the run loop, so a pane relying on
    /// deallocation would leave it firing against a nil target forever.
    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Signals from the surface

    /// A bell. Claude Code emits one when it wants input, if its notification
    /// channel is set to a form that rings, so this is the signal that turns
    /// "which of my four agents needs me" from a guess into a fact.
    func noteBell() {
        guard attention.noteBell() else { return }
        rebuild()
    }

    /// OSC 9 or OSC 777. Carries a message, so the footer can say what is wanted
    /// rather than only that something is.
    func noteNotification(title: String, body: String) {
        guard attention.noteNotification(title: title, body: body) else { return }
        rebuild()
    }

    /// Focusing the pane is the acknowledgement. Nothing else clears attention,
    /// because a pane that stops asking on its own was never answered.
    func noteFocused() {
        guard attention.noteFocused() else { return }
        rebuild()
    }

    /// A keystroke reached this pane.
    ///
    /// This is the other half of acknowledgement, and without it a pane running
    /// a resident agent stays marked for the rest of its life. `noteResumed` is
    /// driven from the idle-to-running transition in `poll`, and for a resident
    /// agent that transition never happens: `PaneActivityClassifier` ranks the
    /// agent above every child it spawns, so the classification stays
    /// `.agent(claude)` while it thinks, while it waits, and after it is
    /// answered. `isIdle` is only ever true for a bare shell, so `wasIdle` is
    /// false at every transition that can occur while the agent is alive.
    ///
    /// The two calls in order give the two levels their meaning: the first key
    /// drops a request from loud to quiet, the next ends it. `||` short circuits,
    /// so a single keystroke never does both.
    func noteInput() {
        guard attention.noteFocused() || attention.noteResumed() else { return }
        rebuild()
    }

    /// What the pane asked for, through OSC 9 or OSC 777 or its own report.
    var attentionMessage: String? {
        resolvedAttention.message
    }

    var wantsAttention: Bool {
        resolvedAttention.isRequesting
    }

    /// The latch once the pane's own statement is taken into account.
    ///
    /// Every reader of "is this pane asking" goes through here, so the footer,
    /// the frame, the window title, the Dock badge and `PaneRecord.attention`
    /// cannot disagree with each other or with the channel.
    private var resolvedAttention: PaneAttention {
        attention.attention.overridden(byReportedBlock: reportedBlock, message: reportedMessage)
    }

    /// Records what the pane says about itself. The caller publishes.
    ///
    /// Deliberately does not fire `onChange`: the controller sets this and then
    /// publishes, so a single report produces one pass rather than two, and the
    /// ordering is visible at the call site rather than buried here.
    func setReportedBlock(_ blocked: Bool?, message: String?) {
        reportedBlock = blocked
        reportedMessage = message
        // Recomputed here, announced by the caller. See ``refreshAgent()``.
        refreshAgent()
    }

    // MARK: - Polling

    /// A pane with no foreground process is mid-exec and reports nothing rather
    /// than falling back to idle, which would make every command launch flicker
    /// the label.
    private func poll() {
        guard let foreground = foregroundPid() else { return }
        // Rooted at the app rather than at the pane's foreground process.
        // `foregroundPid` is `tcgetpgrp`, so it names the running command, not
        // the shell, and a tree rooted there cannot see the shell above it.
        let tree = ProcessTree.snapshot(under: ProcessInfo.processInfo.processIdentifier)
        guard let shell = shellPid(above: foreground, in: tree) else { return }
        let next = PaneActivityClassifier.classify(tree: tree, shellPid: shell)
        guard next != activity else { return }
        let wasIdle = Self.isIdle(activity)
        activity = next
        // A pane that goes from idle back to running has been answered: whatever
        // it was waiting for arrived and it is working again. This is the only
        // thing that ends a request, and it is deliberately the transition rather
        // than the state, so a bell that arrives after its command already exited
        // is not cleared on the very next tick before anyone has seen it.
        if wasIdle, !Self.isIdle(next) { _ = attention.noteResumed() }
        rebuild()
    }

    /// True for a pane sitting at a prompt with nothing under it.
    private static func isIdle(_ activity: PaneActivity) -> Bool {
        activity == .idleShell
    }

    /// The pane's shell: the nearest shell at or above the foreground process.
    ///
    /// Passing the foreground pid as the shell instead is the obvious mistake
    /// and it fails silently. `classify` excludes the shell by pid and looks only
    /// below it, so a pane running `sleep` would report the sleep as its own
    /// shell, find nothing beneath, and read as idle forever. The tell is a pane
    /// that never labels anything while plainly running something.
    private func shellPid(above pid: pid_t, in tree: [ProcessSnapshot]) -> pid_t? {
        let byPid = Dictionary(tree.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var current = pid
        // Bounded rather than trusting the parent chain to terminate. These
        // pointers come from one kernel snapshot and should form a tree, but a
        // loop here would hang the main thread on a poll timer.
        for _ in 0 ..< 64 {
            guard let process = byPid[current] else { return nil }
            if PaneActivityClassifier.shellNames.contains(Self.normalized(process.name)) {
                return process.pid
            }
            current = process.parentPid
        }
        return nil
    }

    /// A login shell presents itself as `-zsh`, and the leading hyphen is a
    /// convention rather than part of the name.
    private static func normalized(_ name: String) -> String {
        name.hasPrefix("-") ? String(name.dropFirst()) : name
    }

    private func rebuild() {
        guard refreshAgent() else { return }
        onChange?()
    }

    /// Recomputes ``agent`` and says whether it moved, without telling anybody.
    ///
    /// **Split from ``rebuild()`` because a report needs the recompute and not
    /// the notification.** The controller sets a report and then publishes once,
    /// deriving both the wire event and the footer level from that single pass;
    /// if this fired `onChange` too, one report would publish twice, and if it
    /// did not recompute at all the publish would read a stale `agent` and the
    /// chrome would stay dark. The second is exactly the bug this file is being
    /// changed to fix, one layer further in.
    @discardableResult
    private func refreshAgent() -> Bool {
        let next = paneAgent()
        guard next != agent else { return false }
        agent = next
        return true
    }

    /// An idle shell with nothing to say contributes no segment at all, so a pane
    /// sitting at a prompt shows its project and git state and nothing else.
    /// What is running, with no attention substitution anywhere near it.
    ///
    /// The footer reads ``agent`` instead, whose label falls back to the
    /// attention message so a pane that rang while idle still has something to
    /// draw. That fallback is a display decision and it stays inside the display:
    /// anything answering "what is running" for the control channel or for a
    /// `PaneRecord` reads this, or it reports the message as the process.
    var classifiedLabel: String? { activity.label }

    /// The same conclusion as ``classifiedLabel``, keeping the case a `String?`
    /// cannot carry.
    ///
    /// **Mapped here rather than by giving `PaneActivity` the wire type**, which
    /// is the move `ControlAxis` and `SplitAxis` already make: a package that
    /// imports Foundation and nothing else does not gain a dependency so another
    /// package can spell one enum, and the app translates in one place.
    ///
    /// `classifiedLabel` folds `idleShell` and `unnameable` together, which is
    /// right for the chrome because it draws nothing either way, and wrong for
    /// the control channel, where "running nothing" and "running something I
    /// cannot name" are different claims about the pane.
    var activityReading: ActivityReading {
        switch activity {
        case .idleShell: .idle
        case .unnameable: .cannotTell
        case let .agent(name, _): .running(name)
        case let .build(command): .running(command)
        case let .command(name): .running(name)
        }
    }

    private func paneAgent() -> PaneStatus.Agent? {
        let label = activity.label
        guard label != nil || wantsAttention else { return nil }
        return PaneStatus.Agent(
            label: label ?? attentionLabel,
            wantsAttention: wantsAttention,
            isAcknowledged: !resolvedAttention.isUnacknowledged,
            // Busy means an agent is working, not that any command is running. A
            // build or a `sleep` is named by its label and does not earn the dot,
            // which is reserved for the thing the workspace exists to watch.
            isBusy: Self.isWorkingAgent(activity)
        )
    }

    /// What an attention request says when nothing is running to name. A bell
    /// from a pane whose command already exited still deserves a marker.
    private var attentionLabel: String {
        resolvedAttention.message ?? "!"
    }

    /// True while an agent is running in this pane.
    private static func isWorkingAgent(_ activity: PaneActivity) -> Bool {
        if case .agent = activity { return true }
        return false
    }

}
