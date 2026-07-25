import Foundation

/// What the pane wants from the user, which is a different question from what
/// is running.
public enum PaneAttention: Sendable, Equatable {
    case none
    /// The pane asked for attention: a bell, or an OSC 9 desktop notification.
    /// `message` is nil for a bare bell.
    case requested(message: String?)
}
