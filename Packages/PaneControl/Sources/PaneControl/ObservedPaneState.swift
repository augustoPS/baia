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
    public mutating func changes(
        activity nextActivity: String?,
        isAsking nextAsking: Bool,
        message: String?
    ) -> [ObservedChange] {
        var changes: [ObservedChange] = []

        if nextActivity != activity {
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
                    message: nextAsking ? message : nil,
                    activity: nil,
                    // Only a raise names a source, and today a pane can only ask
                    // by saying so itself: a bell, or an OSC 9 or OSC 777
                    // notification. `report` will produce the other value.
                    source: nextAsking ? .osc : nil
                )
            )
        }

        return changes
    }
}
