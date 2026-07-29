import Foundation
import PaneControl
import WorkspaceLayout

/// The other seam between the control channel and the workspace, and the mirror
/// image of ``ControlWorkspaceBridge``.
///
/// That protocol is what the channel asks of the windows. This one is what a
/// window asks of the channel, and it is deliberately four members: where a
/// pane's shell is told to talk, how a pane's capability is recorded, how it is
/// forgotten, and what a live pane is observed doing. A `PaneTreeController`
/// holding the whole ``ControlServer`` could reach the graph, the pool, and the
/// socket, none of which a window has any business touching.
///
/// **Nothing here hands a capability back.** `registerPane` takes a secret and
/// returns a `Bool`; there is no member that turns a pane into its secret or a
/// secret into a pane, so no read path in the app can accidentally acquire one.
/// Resolving a token is `PaneGraph.authorize`'s job and it is not reachable from
/// this side of the seam.
@MainActor
protocol PaneControlChannel: AnyObject {
    /// Where this instance's panes are told to talk, or nil when it runs without
    /// a channel.
    ///
    /// Nil is the whole point rather than an edge case: an instance that found
    /// the socket already owned injects no `BAIA_SOCK`, because handing its panes
    /// the *first* instance's live socket would answer `badToken` for secrets
    /// that were never registered there, which is a true error with a completely
    /// false story attached.
    var boundSocketPath: String? { get }

    /// Records a live pane, its capability, and the pane that created it.
    ///
    /// False when the registration was refused, which the graph does for a secret
    /// that parses as a pane id, a secret already issued, and a pane already
    /// open. A refused registration leaves nothing half-recorded, so the pane
    /// simply has no capability and its `baia` says so.
    @discardableResult
    func registerPane(
        _ pane: ControlPaneID,
        createdBy: ControlPaneID?,
        secret: PaneSecret
    ) -> Bool

    /// Forgets a closed pane: its capability, its mailbox, its channels, its peer
    /// edges, and its children's parentage.
    ///
    /// Called from every path that drops a pane controller, because a pane whose
    /// registration outlived its shell is a token that still works against a pane
    /// nobody can see.
    func forgetPane(_ pane: ControlPaneID)

    /// Records something observable about a live pane.
    ///
    /// The fourth member of the seam, and it hands nothing back for the reason the
    /// other three do not: a pane telling the channel what it is doing is not a
    /// pane asking the channel for anything.
    ///
    /// Lifecycle is not routed through here. `registerPane` and `forgetPane`
    /// already own the two moments where the parentage exists or is about to stop
    /// existing, and emitting those from a second place would put the ordering
    /// invariant in two hands.
    func noteEvent(
        _ kind: ControlEventKind,
        pane: ControlPaneID,
        message: String?,
        activity: String?
    )
}

/// The server is the channel. Declared here rather than on the type, so
/// `ControlServer` keeps reading as the thing that owns a socket and a graph
/// rather than as the thing a window talks to.
extension ControlServer: PaneControlChannel {}

extension PaneID {
    /// This pane's public display identity, as the wire spells it.
    ///
    /// Two types for one value because `PaneControl` imports Foundation and
    /// nothing else: a wire type that was also a layout type would drag
    /// `WorkspaceLayout` into the CLI that ships in every pane's PATH. The two
    /// map here, in one place, and nowhere else in the app.
    var control: ControlPaneID { ControlPaneID(rawValue: rawValue) }
}

extension ControlPaneID {
    /// The layout package's spelling of the same display id.
    var layout: PaneID { PaneID(rawValue: rawValue) }
}
