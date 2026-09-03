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
/// Describing a pane, moving one, reading one, and the two layout-document verbs.
/// Everything here needs a window; nothing here decides anything.
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

    /// Every logical line a pane holds, scrollback included, or nil before its
    /// surface exists.
    ///
    /// **Logical lines and not screen rows.** A line wider than the pane comes
    /// back whole, so a caller grepping the output never meets a match cut in half
    /// by a soft wrap. `find-in-pane` reads the same way and the hub records the
    /// trap that makes it necessary: the whole-screen read returns logical lines
    /// while an exact-coordinate read returns rows, so a line index is not a row
    /// index. One reader here, so there is no second one to disagree.
    ///
    /// Deciding which of the lines fit is not this function's job; that is
    /// `ScreenRead.tail`, which is pure and tested.
    func readLines(from pane: ControlPaneID) -> [String]?

    /// Why `list` says what it says about `pane`, or nil when no window holds it.
    ///
    /// Scoped before the call, like ``record(for:)``: the server resolved the
    /// target through the one resolver and an implementation explains whatever
    /// it is asked about.
    func explain(_ pane: ControlPaneID) -> PaneExplanation?

    /// Puts one pane beside another, and answers with the frame the caller gets.
    ///
    /// **Both ids arrive authorised**, each one run past the resolver separately,
    /// because a move names two panes and reaching either of them is reaching into
    /// somebody's window. Nothing here re-checks that, for the reason
    /// ``record(for:)`` does not: half the scope rule in a second place is half a
    /// rule with no test on it.
    ///
    /// Its own method rather than another arm of ``applyLayout(_:to:args:)``,
    /// which takes one target and is called after one authorization. A move that
    /// went through there would have to pull its second pane out of `args` past a
    /// signature saying there was only one, which is exactly the wiring mistake
    /// `.selfOnly` exists to make impossible.
    ///
    /// An implementation opens nothing and closes nothing. The pane keeps its id,
    /// so the parentage graph is not consulted and cannot change.
    func move(
        _ pane: ControlPaneID,
        beside target: ControlPaneID,
        axis: ControlAxis
    ) -> ControlResponse

    /// The arrangement of the window `pane` sits in, or nil when no window holds
    /// it any more.
    ///
    /// **`disclosing` is the scope rule and it arrives decided.** The server
    /// computes it the way `list` computes its own subjects, through the one
    /// resolver, and an implementation puts a working directory on a leaf only
    /// when that leaf's pane is in the set. Every other leaf exports bare, and
    /// `applyLayout(_:createdBy:)` opens those at the default directory.
    ///
    /// The *shape* is not filtered, and that is deliberate rather than an
    /// omission: the document carries no pane ids, so what crosses for a pane the
    /// caller cannot see is a divider and a fraction. The argument is on
    /// ``ControlVerb/layoutExport``.
    func layout(
        of pane: ControlPaneID,
        disclosingDirectoriesFor visible: Set<ControlPaneID>
    ) -> ControlLayout?

    /// Opens a new window from a document, and answers with the caller's frame.
    ///
    /// **Never touches an existing pane**, which is what keeps this verb inside
    /// v1: it creates, and cross-pane mutation is v2. An implementation that
    /// reshaped the caller's window would be that verb under this name.
    ///
    /// Every pane it opens records `pane` as its creator, so they land in the
    /// caller's scope the same way a `split` does and their `paneOpened` events
    /// reach the caller's `subscribe`.
    ///
    /// The document has already been through ``ControlLayout/refusal()`` twice, at
    /// the CLI and again at the server, so an implementation may treat its caps
    /// and its version as settled. What is left is translation.
    func applyLayout(_ layout: ControlLayout, createdBy pane: ControlPaneID) -> ControlResponse
}
