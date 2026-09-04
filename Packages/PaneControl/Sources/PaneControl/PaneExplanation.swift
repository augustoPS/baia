import Foundation

/// What `explain` answers: `list`'s two derived fields with their evidence.
///
/// Strings and numbers only, flattened through ``ControlText/oneLine(_:)-(String)``
/// wherever a pane chose the text. The reasons are prose written by the packages
/// that own the rules (`PaneActivity`), and the app copies them across; nothing
/// here decides anything.
public struct PaneExplanation: Sendable, Equatable, Codable {
    /// The three-way answer of the classifier: whether something is running,
    /// nothing is, or it ran and could not be named.
    public enum Reading: String, Sendable, Equatable, Codable {
        case running
        case idle
        case cannotTell = "cannot tell"
    }

    /// One process the snapshot saw, and what the classifier made of it.
    public struct Process: Sendable, Equatable, Codable {
        public var pid: Int32
        public var parentPid: Int32
        /// Steps below the pane's shell; 0 for the shell; nil for a process that
        /// never reaches it.
        public var depth: Int?
        /// The identifying token that decided the verdict. Never argv.
        public var matched: String?
        /// `pane shell`, `shell`, `agent`, `build`, `command`, `unnameable`,
        /// `outside the pane`.
        public var verdict: String
        public var won: Bool

        public init(pid: Int32, parentPid: Int32, depth: Int?, matched: String?, verdict: String, won: Bool) {
            self.pid = pid
            self.parentPid = parentPid
            self.depth = depth
            self.matched = ControlText.oneLine(matched)
            self.verdict = verdict
            self.won = won
        }
    }

    /// The pane's last statement about itself, whether or not it is still in
    /// force. An expired one is still the evidence for why the pollers have
    /// authority now.
    public struct Report: Sendable, Equatable, Codable {
        public var state: ReportedState
        public var message: String?
        public var seq: UInt64?
        public var live: Bool
        /// Seconds until expiry, 0 once expired.
        public var secondsLeft: Int

        public init(state: ReportedState, message: String?, seq: UInt64?, live: Bool, secondsLeft: Int) {
            self.state = state
            self.message = ControlText.oneLine(message)
            self.seq = seq
            self.live = live
            self.secondsLeft = max(0, secondsLeft)
        }
    }

    public var pane: String
    /// False when the pane has no foreground process, which is the window the
    /// poll skips rather than reading as idle. `processes` is empty then.
    public var hasForeground: Bool
    public var processes: [Process]
    /// The label `list` shows, nil when it shows none.
    public var activity: String?
    /// The three-way answer of the classifier: `running`, `idle`, or `cannot tell`.
    public var activityReading: Reading
    public var activityReason: String
    public var report: Report?
    /// The latch: `none`, `asking`, `acknowledged`, `done`.
    public var latch: String
    public var seen: Bool
    /// The word `list` shows, nil when it shows none.
    public var attention: String?
    /// `report`, `latch`, or `none`.
    public var attentionDecidedBy: String
    public var attentionReason: String

    public init(
        pane: String, hasForeground: Bool, processes: [Process], activity: String?,
        activityReading: Reading, activityReason: String, report: Report?, latch: String,
        seen: Bool, attention: String?, attentionDecidedBy: String, attentionReason: String
    ) {
        self.pane = ControlText.oneLine(pane)
        self.hasForeground = hasForeground
        self.processes = processes
        self.activity = ControlText.oneLine(activity)
        self.activityReading = activityReading
        self.activityReason = ControlText.oneLine(activityReason)
        self.report = report
        self.latch = latch
        self.seen = seen
        self.attention = ControlText.oneLine(attention)
        self.attentionDecidedBy = attentionDecidedBy
        self.attentionReason = ControlText.oneLine(attentionReason)
    }
}
