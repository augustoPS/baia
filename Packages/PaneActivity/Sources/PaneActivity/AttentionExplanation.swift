import Foundation

/// Which authority decided a pane's attention, and why.
///
/// `PaneAttentionState.attention` resolves three facts on every read: the latch
/// (a bell or an OSC notification), the pane's own report, and the visit. The
/// resolution is right and it is silent; a pane that reads `asking` when the
/// owner expected `acknowledged` leaves nothing to look at. This is the same
/// resolution with its inputs and its winner kept.
public struct AttentionExplanation: Sendable, Equatable {
    /// Who had the last word.
    public enum Authority: String, Sendable, Equatable {
        /// A live report from the pane over the channel.
        case report
        /// A bell or an OSC notification, with no report to override it.
        case latch
        /// Nobody asked.
        case none
    }

    public var latch: PaneAttention
    public var reportedBlock: Bool?
    public var reportedFinish: Bool?
    public var reportedMessage: String?
    public var seen: Bool
    /// What the chrome draws: `PaneAttentionState.attention`, by definition.
    public var resolved: PaneAttention
    public var authority: Authority
    public var reason: String

    public init(
        latch: PaneAttention, reportedBlock: Bool?, reportedFinish: Bool?, reportedMessage: String?,
        seen: Bool, resolved: PaneAttention, authority: Authority, reason: String
    ) {
        self.latch = latch
        self.reportedBlock = reportedBlock
        self.reportedFinish = reportedFinish
        self.reportedMessage = reportedMessage
        self.seen = seen
        self.resolved = resolved
        self.authority = authority
        self.reason = reason
    }
}
