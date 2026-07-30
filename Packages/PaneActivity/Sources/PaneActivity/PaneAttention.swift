import Foundation

/// What the pane wants from the user, which is a different question from what
/// is running.
public enum PaneAttention: Sendable, Equatable {
    case none

    /// The pane asked for attention: a bell, or an OSC 9 desktop notification.
    /// `message` is nil for a bare bell.
    case requested(message: String?)

    /// The pane is still waiting, but the user has been here since it asked.
    ///
    /// A third case rather than a flag beside the second, because the whole
    /// requirement (loud enough to find across four panes, quiet enough to work
    /// beside, settled once seen) is contradictory only while asking is one
    /// state. Focusing the pane used to drop straight back to ``none``, which
    /// answered "have you seen it" and threw away "is it still waiting", so a
    /// pane the user glanced at and left became indistinguishable from one that
    /// had gone back to work.
    case acknowledged(message: String?)

    /// True while the pane wants the user at all, at either volume.
    public var isRequesting: Bool {
        switch self {
        case .none: false
        case .requested, .acknowledged: true
        }
    }

    /// True only for an unacknowledged request, which is the loud level.
    public var isUnacknowledged: Bool {
        if case .requested = self { return true }
        return false
    }

    /// Whatever the request carried, at either volume. The message names which
    /// repository asked, which is the entire reason for showing it, so it has to
    /// survive being acknowledged.
    public var message: String? {
        switch self {
        case .none: nil
        case let .requested(message), let .acknowledged(message): message
        }
    }
}

public extension PaneAttention {
    /// This attention once the pane's own statement about itself is taken into
    /// account.
    ///
    /// **The report owns whether the pane is asking; the latch owns how loudly.**
    /// A report answers "does the agent still need me". Acknowledgement answers
    /// "have I been here since it started", which is a different question a
    /// report has no view on, so it passes through untouched.
    ///
    /// A reported block that stayed loud until released was considered and
    /// rejected: it reproduces the failure recorded under the two-level model, a
    /// pane that ever rang staying marked for life, with the owner working in the
    /// very pane that is shouting. Intolerability at four panes is why
    /// ``acknowledged`` exists at all.
    ///
    /// **`blocked` is optional, and that is load-bearing.** Nil is "the pane has
    /// said nothing" and leaves the latch alone; `false` is "the agent says it is
    /// working", which outranks a bell the pane emitted earlier and silences it.
    /// A plain `Bool` folds those together and would make every pane with no
    /// report unable to ring.
    ///
    /// Takes a `Bool?` and a `String?` rather than the channel's own state enum,
    /// because this package imports Foundation and nothing else. The app maps one
    /// onto the other in one place, which is the call ``ActivityReading`` already
    /// makes and the reason `ControlAxis` and `SplitAxis` are separate types.
    func overridden(byReportedBlock blocked: Bool?, message: String?) -> PaneAttention {
        guard let blocked else { return self }
        guard blocked else { return .none }
        // Asking, at whatever volume the latch had already settled on. The
        // report's message wins, because the report is the thing asking and the
        // latch may be holding an hour-old bell from a build.
        switch self {
        case .none, .requested: return .requested(message: message)
        case .acknowledged: return .acknowledged(message: message)
        }
    }
}
