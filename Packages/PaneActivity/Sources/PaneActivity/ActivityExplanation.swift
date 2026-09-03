import Foundation

/// Why ``PaneActivityClassifier`` answered what it did, one verdict per process.
///
/// **The answer is the classifier's answer, by definition and not by
/// agreement.** `classify(tree:shellPid:)` is `explain(tree:shellPid:).activity`,
/// so there is no second loop to drift. What this adds is the evidence the poll
/// throws away: which process each verdict came from, the token that decided
/// it, its depth below the pane's shell, and which one won.
///
/// Built for `baia explain`, which exists because the hub records a pane that
/// labelled nothing while running something and nobody could see why. A
/// detector that abstains has to be able to show its work, or "cannot tell" is
/// just a second way of being wrong.
public struct ActivityExplanation: Sendable, Equatable {
    /// What one process classified as on its own.
    public enum Verdict: Sendable, Equatable {
        /// The pane's own shell, excluded by pid before any token is read.
        case paneShell
        /// A nested shell or ghostty's spawn plumbing, idle by definition.
        case shell
        case agent(name: String)
        case build(command: String)
        case command(name: String)
        /// Something ran and yielded no identifying token at all.
        case unnameable
        /// Never reaches `shellPid`: a process of some other pane, or of the app.
        case outsidePane
    }

    public struct ProcessVerdict: Sendable, Equatable {
        public var pid: pid_t
        public var parentPid: pid_t
        /// Steps below the pane's shell; 0 for the shell itself; nil for a
        /// process that never reaches it.
        public var depth: Int?
        /// The token that decided the verdict, or nil when none did.
        public var matched: String?
        public var verdict: Verdict
        /// True for the one process whose verdict became the answer.
        public var won: Bool

        public init(pid: pid_t, parentPid: pid_t, depth: Int?, matched: String?, verdict: Verdict, won: Bool) {
            self.pid = pid
            self.parentPid = parentPid
            self.depth = depth
            self.matched = matched
            self.verdict = verdict
            self.won = won
        }
    }

    /// Ordered by depth then pid, outsiders last, so a renderer prints top down.
    public var processes: [ProcessVerdict]
    public var activity: PaneActivity
    /// One sentence naming the rule that produced ``activity``.
    public var reason: String

    public init(processes: [ProcessVerdict], activity: PaneActivity, reason: String) {
        self.processes = processes
        self.activity = activity
        self.reason = reason
    }
}
