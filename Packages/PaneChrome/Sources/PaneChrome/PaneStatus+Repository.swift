import GitWorkspace

/// The one translation from `GitWorkspace`'s vocabulary into the chrome's.
///
/// It lived twice before this file: once in the app target, where the poller
/// built it and nothing could test it, and once inside
/// ``PaneGitRuns/runs(for:)``, which needed the same eight fields for the
/// command palette and wrote them out again. The two agreed, which is luck
/// rather than a guarantee: the dirty rule below is a judgement, and a judgement
/// held in two places drifts the first time one of them is corrected.
extension PaneStatus.Git {
    /// Maps a repository's status onto ``PaneStatus/Git``'s fields.
    ///
    /// Neither `operation` nor `isLinkedWorktree` comes from `status`, so both
    /// are asked for rather than defaulted. The palette passes nil and false and
    /// says why; defaulting them would let a third caller take the palette's
    /// answers by accident and show a pane in a linked worktree as if it were in
    /// the main checkout, which is the confusion the flag exists to prevent.
    public init(
        _ status: RepositoryStatus,
        operation: String?,
        isLinkedWorktree: Bool
    ) {
        self.init(
            head: status.displayHead,
            hasUpstream: status.upstream != nil,
            ahead: status.ahead,
            behind: status.behind,
            // Conflicts count as dirty, matching how the owner's own statusline
            // derives its asterisk from `git diff --quiet`, which reports an
            // unmerged path as a difference.
            dirty: status.staged > 0 || status.unstaged > 0 || status.conflicted > 0,
            untracked: status.untracked,
            conflicted: status.conflicted,
            operation: operation,
            isLinkedWorktree: isLinkedWorktree
        )
    }

    /// The label for an operation the repository is halfway through, or nil.
    ///
    /// Upper case because these are the states where the next command does
    /// something other than what it usually does, and the chrome is otherwise
    /// all lower case.
    ///
    /// Separate from the mapping above rather than folded into it, because the
    /// palette drops the operation on purpose and the capsule keeps it. A caller
    /// that wants both writes both.
    public static func operationLabel(for operation: RepositoryStatus.InProgress?) -> String? {
        switch operation {
        case .none: nil
        case .rebase: "REBASE"
        case .merge: "MERGE"
        case .cherryPick: "CHERRY-PICK"
        case .revert: "REVERT"
        case .bisect: "BISECT"
        }
    }
}
