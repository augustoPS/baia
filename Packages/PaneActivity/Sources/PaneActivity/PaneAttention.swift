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
