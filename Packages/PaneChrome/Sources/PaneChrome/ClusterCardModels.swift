import Foundation
import GitWorkspace

/// What the place card shows, assembled once from the same facts the capsule's
/// place segment reads.
///
/// Lifted out of ``ClusterPlaceCardView``'s own nested `Model` (`Task 4`) so the
/// derivation — the branch marker string, the linked-worktree repository name,
/// the abbreviated path — lives in this package and can be tested without
/// AppKit, rather than inside the view's `init` where only a live pane could
/// exercise it.
public struct ClusterPlaceCardModel: Sendable, Equatable {
    public var repositoryName: String

    /// The linked worktree's name, or nil for a main checkout, where the row
    /// is absent rather than restating ``repositoryName``.
    public var worktreeName: String?

    /// `head ↑a↓b`, the footer's own spelling, or nil outside a repository.
    public var branch: String?

    /// The operation the repository is halfway through (`REBASE`,
    /// `CHERRY-PICK`, …), or nil when it is not.
    ///
    /// **The pill says this too, and that is the stated exception to one
    /// home per fact.** The capsule's own rule is that a fact lives in one
    /// place, and the linked-worktree prefix obeys it by living here alone.
    /// This one is drawn twice on purpose, because the two draws answer
    /// different questions: the pill's segment is the *alarm* — it must be
    /// readable without a click, since it is what explains why the branch
    /// beside it has become a bare commit hash — and this row is the
    /// *caption*, the operation named next to the branch and the repository
    /// it applies to, where a reader who clicked through to understand the
    /// hash finds the two facts adjacent. Dropping the row would leave the
    /// place card describing a checkout while silently omitting the reason
    /// it is in the state it is in; dropping the segment would put the fact
    /// behind a click, which is exactly what a fact that changes the meaning
    /// of the pill's other facts cannot be.
    ///
    /// **Twice drawn, once decided.** ``make(anchorDisplayName:isLinkedWorktree:mainCheckoutName:git:workingDirectoryPath:home:)``
    /// fills this from ``PaneStatus/Git/displayableOperation``, the predicate
    /// the pill's segment is also built from, so "is there an operation to
    /// show" is answered in one place for both. Nil here therefore means the
    /// same thing it means on the pill, blanks included — this row read the
    /// raw field until 2026-08-13 and drew a captioned empty box for `"   "`.
    public var operation: String?

    /// The pane's working directory, tilde-abbreviated for display. The full
    /// path stays with the caller, whose Copy path closure is the one place
    /// that needs it.
    public var workingDirectory: String

    public init(
        repositoryName: String,
        worktreeName: String?,
        branch: String?,
        operation: String?,
        workingDirectory: String
    ) {
        self.repositoryName = repositoryName
        self.worktreeName = worktreeName
        self.branch = branch
        self.operation = operation
        self.workingDirectory = workingDirectory
    }

    /// Assembles the place card's facts exactly as
    /// `TerminalPaneController.presentPlaceCard` built them before this type
    /// existed.
    ///
    /// - Parameters:
    ///   - anchorDisplayName: The pane's anchor name (`Anchor.displayName`).
    ///     In a linked worktree the anchor *is* the worktree, so this fills
    ///     ``worktreeName`` there and ``repositoryName`` gets the main
    ///     checkout's name instead, when it can be resolved.
    ///   - isLinkedWorktree: `git?.isLinkedWorktree`, gating the worktree row
    ///     and the repository-name substitution.
    ///   - mainCheckoutName: ``GitDirectory/mainCheckoutName(forLinkedWorktreeRoot:)``'s
    ///     answer for the pane's repository root, or nil when the pointer
    ///     could not be resolved — in which case the worktree's own name
    ///     stands for ``repositoryName``, the same fallback the tab already
    ///     shows.
    ///   - git: The same `PaneStatus.Git` the capsule's segments are built
    ///     from, or nil for a plain (non-repository) anchor.
    ///   - workingDirectoryPath: The full, unabbreviated working directory.
    ///   - home: The home directory path ``PaneStatus/abbreviated(_:home:)``
    ///     shortens against.
    public static func make(
        anchorDisplayName: String,
        isLinkedWorktree: Bool,
        mainCheckoutName: String?,
        git: PaneStatus.Git?,
        workingDirectoryPath: String,
        home: String
    ) -> ClusterPlaceCardModel {
        // In a linked worktree the anchor *is* the worktree, so its name fills
        // that row and the repository row wants the main checkout's name
        // instead; when the pointer cannot be resolved the worktree's own
        // name stands, which is what the tab already shows.
        var repositoryName = anchorDisplayName
        var worktreeName: String?
        if isLinkedWorktree {
            worktreeName = anchorDisplayName
            if let mainCheckoutName {
                repositoryName = mainCheckoutName
            }
        }

        // `head ↑a↓b`, the marker spelling exactly: the counts joined
        // unspaced the way `PaneGitRuns.markerText` joins its runs, one space
        // between the head and the group, and the same no-upstream
        // suppression, because stale counts against a branch with nowhere to
        // push are worse than none. Composed from `PaneGitRuns.markerText(for:)`
        // rather than hand-spelled, so the card and the pill cannot drift on
        // what a marker looks like.
        let branch: String? = git.flatMap { git in
            guard !git.head.isEmpty else { return nil }
            let markers = PaneGitRuns.markerText(for: git)
            return markers.isEmpty ? git.head : "\(git.head) \(markers)"
        }

        return ClusterPlaceCardModel(
            repositoryName: repositoryName,
            worktreeName: worktreeName,
            branch: branch,
            operation: git?.displayableOperation,
            workingDirectory: PaneStatus.abbreviated(workingDirectoryPath, home: home)
        )
    }
}

/// What the attention card shows, assembled once from the same
/// `PaneStatus.Agent` and `PaneStatus.Attention` the capsule's agent and
/// attention segments read.
///
/// Lifted out of ``ClusterAttentionCardView``'s own nested `Model` (`Task 4`),
/// for ``ClusterPlaceCardModel``'s own reason: the `agent · repo` title rule
/// and the approval gate belong in a package a test can reach without AppKit.
public struct ClusterAttentionCardModel: Sendable, Equatable {
    /// The agent's label, or nil when it is empty, where the row is absent
    /// rather than blank.
    public var agentLabel: String?

    /// `working` or `waiting`, from `PaneStatus.Agent.isBusy`.
    public var state: String?

    /// `asking`, `acknowledged` or `done`, from `PaneStatus.Attention.name(of:)`,
    /// or nil when the pane is not asking, where the row is absent.
    public var attention: String?

    /// Present exactly when `ApprovalPopover.presents(for:)` says the card
    /// should offer one; the caller applies no gate of its own.
    public var approval: Approval?

    public struct Approval: Sendable, Equatable {
        /// `agent · repo`, or the bare repo name when no agent is running.
        public var title: String

        /// The attention message verbatim, or ``ApprovalPopover/body(for:)``'s
        /// fallback.
        public var message: String

        public init(title: String, message: String) {
            self.title = title
            self.message = message
        }
    }

    public init(
        agentLabel: String?,
        state: String?,
        attention: String?,
        approval: Approval?
    ) {
        self.agentLabel = agentLabel
        self.state = state
        self.attention = attention
        self.approval = approval
    }

    /// Assembles the attention card's facts exactly as
    /// `TerminalPaneController.presentAttentionCard` built them before this
    /// type existed.
    ///
    /// - Parameters:
    ///   - status: The pane's current `PaneStatus`, or nil.
    ///   - attentionMessage: The pane's reported attention message, fed to
    ///     ``ApprovalPopover/body(for:)`` for the approval's fallback body.
    public static func make(
        status: PaneStatus?,
        attentionMessage: String?
    ) -> ClusterAttentionCardModel {
        let agent = status?.agent
        let attention = status?.attention ?? .none

        var approval: Approval?
        if ApprovalPopover.presents(for: attention) {
            // `agent · repo`, or the bare repo name when nothing is running
            // under this pane to give the card an agent half of the title.
            // The same emptiness check the fact row below applies to
            // `agentLabel`: an agent that has reported no name yet is "no
            // agent" for a title exactly as it is for a row.
            let anchorName = status?.anchorName ?? "baia"
            let agentLabel = agent.flatMap { $0.label.isEmpty ? nil : $0.label }
            approval = .init(
                title: agentLabel.map { "\($0) · \(anchorName)" } ?? anchorName,
                message: ApprovalPopover.body(for: attentionMessage)
            )
        }

        return ClusterAttentionCardModel(
            agentLabel: agent.flatMap { $0.label.isEmpty ? nil : $0.label },
            state: agent.map { $0.isBusy ? "working" : "waiting" },
            attention: PaneStatus.Attention.name(of: attention),
            approval: approval
        )
    }
}
