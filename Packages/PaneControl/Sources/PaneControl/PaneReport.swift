import Foundation

/// What a pane says it is doing, in the only three answers the channel accepts.
///
/// Three rather than herdr's six, because the other three of theirs are about
/// authority handover rather than state, and this channel expresses handover with
/// `--release` instead of a state. Design v4's four-state model is a separate
/// decision and is not this enum.
public enum ReportedState: String, Sendable, Hashable, Codable, CaseIterable {
    /// Busy, and not waiting on a human.
    case working

    /// Waiting on a human. The one state that raises attention.
    case blocked

    /// Done. **The reason this case exists**: a resident agent's process never
    /// exits, so the process-tree poller reports it running forever and no
    /// observer can tell a finished agent from a working one. This is how a
    /// finished agent says so when its process cannot.
    case idle
}

/// One statement a pane made about itself, with the two facts that decide whether
/// it is still the one in force.
public struct PaneReport: Sendable, Equatable {
    public var state: ReportedState

    /// Carried on `blocked` alone. A message rides a raise and never a clear,
    /// which is the rule ``ObservedPaneState`` already follows for OSC messages.
    public var message: String?

    /// The reporter's ordering claim, or nil for a reporter making none.
    public var seq: UInt64?

    /// When authority falls back to the pollers without anybody saying so.
    public var expires: Date

    public init(state: ReportedState, message: String? = nil, seq: UInt64? = nil, expires: Date) {
        self.state = state
        self.message = message
        self.seq = seq
        self.expires = expires
    }
}

/// The live report for one pane, and the rules that decide which statement wins.
///
/// **Pure, and in this package, for the reason every other rule here is.** Seq
/// comparison and expiry need no descriptor and no `NSWindow` to decide, and the
/// app target has no test target. Five rules that lived over there were found one
/// at a time and three of the five were wrong when they moved.
///
/// The store holds the last accepted report whether or not it is still live, so
/// that ``accept(_:)`` can compare sequences across an expiry. Liveness is asked
/// for separately by ``live(at:)``.
public struct ReportStore: Sendable, Equatable {
    /// Whether a statement took effect. Never an error: a hook that fires twice
    /// for one transition must not look broken, because a non-zero answer reaches
    /// a `set -e` script with no way to tell a duplicate from a failure.
    public enum Acceptance: Sendable, Equatable {
        case accepted
        case superseded
    }

    private var held: PaneReport?

    public init() {}

    /// Records a statement, unless its ordering claim is stale.
    ///
    /// **Ordering survives expiry and release**, so sequence numbers are
    /// monotonic for a whole run. That is what makes a replayed old report
    /// harmless, and it is why the hook derives its sequence from a clock rather
    /// than from a counter it would restart on every session.
    ///
    /// A nil sequence after a numbered one is refused rather than treated as
    /// unordered, because accepting it would restart the ordering and let the
    /// next replay win.
    public mutating func accept(_ report: PaneReport) -> Acceptance {
        if let heldSeq = held?.seq {
            guard let incoming = report.seq, incoming > heldSeq else { return .superseded }
        }
        held = report
        return .accepted
    }

    /// Hands authority back to the pollers now. herdr's `HookAuthorityCleared`.
    ///
    /// Expires the statement in place rather than dropping it, so the sequence
    /// survives exactly as it does across a lapse. Dropping it would rewind the
    /// ordering and let the next replayed report win, which is the same trap
    /// ``accept(_:)`` refuses a nil sequence to avoid.
    public mutating func release() {
        held?.expires = .distantPast
    }

    /// The statement in force at an instant, or nil when the pollers have it.
    public func live(at now: Date) -> PaneReport? {
        guard let held, held.expires > now else { return nil }
        return held
    }
}
