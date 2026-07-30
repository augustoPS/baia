import Foundation

/// One change a pane's state produced, ready to be emitted.
///
/// A value rather than four loose arguments, so the order the changes come back
/// in is the order they are appended, and a caller cannot reassemble them wrongly
/// on its way to ``PaneGraph/emit(_:pane:createdBy:message:activity:source:)``.
public struct ObservedChange: Sendable, Equatable {
    public var kind: ControlEventKind
    public var message: String?
    public var activity: String?
    public var source: ControlEventSource?
}

/// What the working authority managed to conclude this poll.
///
/// Three answers where there were two, and the third is the point. `String?` used
/// to mean both "nothing is running" and "something is running that I cannot
/// name", and publishing the second as the first is a wrong answer wearing the
/// shape of a right one: the hub records a pane that never labelled anything
/// while running something. A detector that cannot tell must say so rather than
/// conclude.
public enum ActivityReading: Sendable, Equatable {
    case running(String)
    case idle
    case cannotTell
}

/// The last values a pane published, and the rule that turns a poll into events.
///
/// **This is where "edge-triggered, never level-triggered" is actually decided**,
/// which is the spec's third decision and the one a subscriber feels most. The
/// pane's tracker fires on a timer for any change to its whole state, and the
/// label moves as a build walks its targets, so a caller that forwarded every
/// firing would publish a heartbeat and every subscriber would write its own
/// deduplication. Each one would be wrong in a different way.
///
/// **Pure, and in this package, because the alternative was untestable.** It
/// lived as eight lines inside an `onChange` closure in the app target, which has
/// no test target, so the spec's central promise was enforced by a comment. Same
/// move as `ControlWire.cappedWait` and `ControlEventKind.resolve`: a rule that is
/// decidable without a window belongs where `make test` can decide it.
public struct ObservedPaneState: Sendable, Equatable {
    private var activity: String?
    private var isAsking = false

    public init() {}

    /// What changed since the last call, oldest fact first.
    ///
    /// Empty when nothing transitioned, which is the whole point: this is called
    /// on every poll of every pane, and a pane merely compiling transitions
    /// rarely.
    ///
    /// **Activity comes before attention when both moved.** A subscriber that
    /// receives them in one batch then sees what the pane is doing before it sees
    /// it ask, which is the order a supervisor needs to render "claude is asking"
    /// rather than "something is asking, and separately claude is running".
    ///
    /// The message rides on a raise and never on a clear. A clear is the owner
    /// focusing the pane or typing into it, and the text the pane sent when it
    /// asked has been answered by then.
    /// **Authority is resolved before the comparison, never inside it.** The
    /// comparison below is the edge-triggering rule and it is unchanged; the
    /// merge above it is a separate, pure step. Keeping the two apart is what let
    /// three authorities arrive without the spec's third decision moving, and
    /// every test written against that decision still passes untouched.
    ///
    /// The precedence is one rule: a live report decides both fields, and absent
    /// one the two pollers decide as they always did. `report` is already the
    /// live report, so expiry is the caller's business and never a case here.
    public mutating func changes(
        activity reading: ActivityReading,
        isAsking oscAsking: Bool,
        message oscMessage: String?,
        report: PaneReport?
    ) -> [ObservedChange] {
        var changes: [ObservedChange] = []

        // The working authority, and its abstention.
        var nextActivity: String?
        var holdActivity = false
        switch reading {
        case .running(let label): nextActivity = label
        case .idle: nextActivity = nil
        case .cannotTell:
            nextActivity = activity
            holdActivity = true
        }

        // A report reaches the activity in exactly one case. `idle` is a finished
        // agent whose process is still resident, which no poller can see;
        // `working` and `blocked` say nothing the process tree does not already
        // say better, so they leave the label alone.
        if report?.state == .idle {
            nextActivity = nil
            holdActivity = false
        }

        // The blocker authority, overridden wholesale by any live report.
        let nextAsking: Bool
        let nextMessage: String?
        let nextSource: ControlEventSource
        if let report {
            nextAsking = report.state == .blocked
            nextMessage = report.message
            nextSource = .report
        } else {
            nextAsking = oscAsking
            nextMessage = oscMessage
            nextSource = .osc
        }

        if holdActivity == false, nextActivity != activity {
            activity = nextActivity
            changes.append(
                ObservedChange(kind: .activityChanged, message: nil, activity: nextActivity, source: nil)
            )
        }

        if nextAsking != isAsking {
            isAsking = nextAsking
            changes.append(
                ObservedChange(
                    kind: nextAsking ? .attentionRaised : .attentionCleared,
                    message: nextAsking ? nextMessage : nil,
                    activity: nil,
                    // Only a raise names a source. Which source it names is the
                    // one fact a subscriber cannot recover any other way: the
                    // same bytes arrive whether a build script emitted an escape
                    // sequence or an agent asked over an authenticated socket.
                    source: nextAsking ? nextSource : nil
                )
            )
        }

        return changes
    }
}
