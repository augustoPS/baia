import Foundation
import PaneControl

/// The one seam between the control channel and the workspace.
///
/// `ControlServer` owns the socket, the frames, the budgets, and the single
/// scope resolver; it does not own a window, a tab, or a `Workspace`. Everything
/// it cannot answer without AppKit comes through here, and everything it *can*
/// answer stays on its side of this line. **No policy lives behind this
/// protocol**: by the time either method runs, `PaneGraph.authorize` has already
/// said yes, the settings gate has already run, and the pane named is one the
/// caller is allowed to touch.
///
/// Two methods and no more, because the two things the channel cannot do without
/// the app are describing a pane and moving one.
///
/// Implemented by `ControlAdapter` in the app, which holds the pane-to-window
/// index. Main-actor isolated because everything it touches is.
@MainActor
protocol ControlWorkspaceBridge: AnyObject {
    /// What `whoami`, `list`, and `peers` say about one pane, or nil when the app
    /// no longer has it.
    ///
    /// Display ids and human-readable strings only. **No response path may read
    /// the token registry**, and the shape of this method is part of why: it is
    /// handed a resolved `ControlPaneID` and has no way to ask about a secret,
    /// so a record cannot carry one even by accident.
    ///
    /// The scope is decided before the call. The server asks for exactly the
    /// panes the caller may see, each one already run past the resolver, so an
    /// implementation that returned a record for anything it was asked about is
    /// correct: filtering is not its job and doing it twice would put half the
    /// scope rule somewhere with no test on it.
    func record(for pane: ControlPaneID) -> PaneRecord?

    /// Applies one authorised layout verb to one pane, and answers with the frame
    /// the caller gets.
    ///
    /// A whole `ControlResponse` rather than a `Bool`, because a `Workspace`
    /// mutator returning false is `refused` with a reason the workspace knows and
    /// the server does not: the last pane of the last tab, a split into a tab
    /// another pane has zoomed, a zoom from a caller that is not focused.
    ///
    /// **`close` must write before it kills.** The pane this verb closes is the
    /// pane whose shell is waiting on the response, so an implementation closes
    /// on the next main-loop turn and returns the success frame now. A client
    /// that loses that race sees EOF and treats it as success, which is what the
    /// CLI does; a client that closed the pane synchronously would see nothing
    /// else.
    ///
    /// A `split` that opens a pane registers it with the server, so the new pane
    /// gets its own capability and its `createdBy` edge in the same step that
    /// puts it on screen.
    func applyLayout(
        _ verb: ControlVerb,
        to pane: ControlPaneID,
        args: ControlArgs
    ) -> ControlResponse
}
