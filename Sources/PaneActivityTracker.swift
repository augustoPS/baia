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
    /// One effective pane state, captured at the instant it is published.
    ///
    /// The controller hands this value to chrome, control events and explain.
    /// None of those readers asks the report store or attention state again, so
    /// expiry cannot land between separate reads and make one publication
    /// disagree with itself.
    struct Revision: Equatable {
        let agent: PaneStatus.Agent?
        let activityLabel: String?
        let activityReading: ActivityReading
        let attention: AttentionExplanation
        let report: ReportRevision

        var wantsAttention: Bool { attention.resolved.isRequesting }
        var attentionMessage: String? { attention.resolved.message }
        var attentionState: PaneStatus.Attention { PaneStatus.Attention(agent) }
    }

    var onChange: ((Revision) -> Void)?

    private(set) var revision = Revision(
        agent: nil,
        activityLabel: nil,
        activityReading: .idle,
        attention: PaneAttentionState().explanation,
        report: ReportStore().revision(at: .distantPast)
    )

    /// Supplied by the pane, because reading it means reaching into a terminal
    /// surface and this type never does.
    private let foregroundPid: () -> pid_t?

    private var attention = PaneAttentionState()

    /// The pane's report authority and its only future transition.
    ///
    /// Kept with the attention it overrides, rather than on the controller, so
    /// a single revision decides what UI, events and explain observe. The
    /// deadline timer is separate from process polling because expiry happens
    /// even when no process changes or this pane's view is not visible.
    private lazy var reports: ReportTimeline = {
        let reports = ReportTimeline()
        reports.onExpiry = { [weak self] report in
            self?.publish(report: report)
        }
        return reports
    }()

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

    /// The terminal controller's isolated teardown calls ``stopTracking``.
    /// Keeping the cancellation at that ownership boundary avoids asking this
    /// type's deinitializer to reach a non-Sendable Foundation timer.
    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// What is running now, sampled at the moment of asking rather than taken
    /// from the last poll: a job started a moment ago must still count when the
    /// owner is about to close the pane over it.
    func currentActivity() -> PaneActivity {
        poll()
        return activity
    }

    /// Ends every deadline owned by this pane.
    ///
    /// Visibility never calls this. A zoom-hidden pane is still workspace-owned
    /// and must keep both activity and report expiry current. The terminal
    /// controller calls this only at its own teardown boundary.
    func stopTracking() {
        stopPolling()
        reports.cancel()
    }

    // MARK: - Signals from the surface

    /// A bell. Claude Code emits one when it wants input, if its notification
    /// channel is set to a form that rings, so this is the signal that turns
    /// "which of my four agents needs me" from a guess into a fact.
    func noteBell() {
        let before = attention
        _ = attention.noteBell()
        guard attention != before else { return }
        publish()
    }

    /// OSC 9 or OSC 777. Carries a message, so the capsule can say what is wanted
    /// rather than only that something is.
    func noteNotification(title: String, body: String) {
        let before = attention
        _ = attention.noteNotification(title: title, body: body)
        guard attention != before else { return }
        publish()
    }

    /// Focusing the pane is the acknowledgement. Nothing else clears attention,
    /// because a pane that stops asking on its own was never answered.
    func noteFocused() {
        let before = attention
        _ = attention.noteFocused()
        guard attention != before else { return }
        publish()
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
        let before = attention
        _ = attention.noteFocused() || attention.noteResumed()
        guard attention != before else { return }
        publish()
    }

    /// Records a statement and schedules the exact instant its authority ends.
    func accept(report: PaneReport) {
        _ = reports.accept(report)
        publish(report: reports.revision)
    }

    /// Hands authority back to the pollers now and cancels the obsolete future
    /// transition before publishing the effective revision.
    func releaseReport() {
        reports.release()
        publish(report: reports.revision)
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
        guard let shell = ProcessTree.shellPid(above: foreground, in: tree) else { return }
        let next = PaneActivityClassifier.classify(tree: tree, shellPid: shell)
        guard next != activity else { return }
        let wasIdle = PaneActivity.isIdle(activity)
        activity = next
        // A pane that goes from idle back to running has been answered: whatever
        // it was waiting for arrived and it is working again. This is the only
        // thing that ends a request, and it is deliberately the transition rather
        // than the state, so a bell that arrives after its command already exited
        // is not cleared on the very next tick before anyone has seen it.
        if wasIdle, !PaneActivity.isIdle(next) { _ = attention.noteResumed() }
        publish()
    }

    /// Publishes one time-consistent state through every consumer.
    private func publish(report: ReportRevision? = nil) {
        let report = report ?? reports.revision
        _ = attention.noteReported(
            blocked: report.live.map(\.state.isAsking),
            finished: report.live.map(\.state.isFinished),
            message: report.live?.message
        )
        let explanation = attention.explanation
        let next = Revision(
            agent: paneAgent(attention: explanation.resolved),
            activityLabel: activity.label,
            activityReading: Self.reading(of: activity),
            attention: explanation,
            report: report
        )
        guard next != revision else { return }
        revision = next
        onChange?(next)
    }

    /// Maps process classification onto the control channel's three-way read.
    static func reading(of activity: PaneActivity) -> ActivityReading {
        switch activity {
        case .idleShell: .idle
        case .unnameable: .cannotTell
        case let .agent(name, _): .running(name)
        case let .build(command): .running(command)
        case let .command(name): .running(name)
        }
    }

    /// Current process evidence beside the effective revision consumers observe.
    ///
    /// Process detail is fresh because the poll retains only its conclusion, but
    /// the effective activity/attention/report values are the same immutable
    /// revision chrome and control use. When the process read is unavailable the
    /// detail is nil and the effective activity remains the last published fact;
    /// an unavailable read is not evidence that the pane became idle. Read-only:
    /// nothing here moves `activity`, report authority or the latch.
    func explain() -> (activity: ActivityExplanation?, revision: Revision) {
        let revision = self.revision
        guard let foreground = foregroundPid() else { return (nil, revision) }
        let tree = ProcessTree.snapshot(under: ProcessInfo.processInfo.processIdentifier)
        guard let shell = ProcessTree.shellPid(above: foreground, in: tree) else {
            return (nil, revision)
        }
        let explanation = PaneActivityClassifier.explain(tree: tree, shellPid: shell)
        return (explanation, revision)
    }

    private func paneAgent(attention: PaneAttention) -> PaneStatus.Agent? {
        let label = activity.label
        // A finished pane with nothing running still has something to draw:
        // the ✓ that says it finished unseen. Without the third clause a done
        // pane whose command exited produced no agent at all and the level
        // died at this guard.
        guard label != nil || attention.isRequesting || attention.isDone else { return nil }
        return PaneStatus.Agent(
            label: label ?? attentionLabel(for: attention),
            wantsAttention: attention.isRequesting,
            isAcknowledged: !attention.isUnacknowledged,
            // Busy means an agent is working, not that any command is running. A
            // build or a `sleep` is named by its label and does not earn the dot,
            // which is reserved for the thing the workspace exists to watch.
            isBusy: PaneActivity.isWorkingAgent(activity),
            hasFinishedUnseen: attention.isDone
        )
    }

    /// What an attention request says when nothing is running to name.
    ///
    /// `waiting` rather than `!`: the capsule now carries the glyph, and a bar
    /// reading `! !` said the same thing twice (v5 §3 names the status word).
    /// A finish names nothing, deliberately: `PaneAttention.done` carries no
    /// message, and the empty label makes `PaneClusterSegments` skip the agent
    /// segment while the ✓ still draws from the level itself.
    private func attentionLabel(for attention: PaneAttention) -> String {
        if attention.isDone { return "" }
        return attention.message ?? "waiting"
    }
}
