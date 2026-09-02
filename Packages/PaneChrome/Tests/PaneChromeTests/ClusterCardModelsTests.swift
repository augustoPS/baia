import Foundation
import GitWorkspace
import Testing

@testable import PaneChrome

@Suite struct ClusterCardModelsTests {
    // MARK: - Place card: branch markers agree with the pill

    /// The card's branch line and the pill's own marker string
    /// (``PaneGitRuns/markerText(for:)``) for ahead, behind, both and no
    /// upstream — the same shape as
    /// `PaneClusterSegmentsTests.theCardAndThePillAgreeOnWhatCountsAsAnOperation`,
    /// against the marker vocabulary instead of the operation predicate.
    @Test func theCardAndThePillAgreeOnBranchMarkers() {
        let cases: [(name: String, git: PaneStatus.Git, expected: String)] = [
            ("ahead", Sample.git(head: "main", hasUpstream: true, ahead: 2), "main ↑2"),
            ("behind", Sample.git(head: "main", hasUpstream: true, behind: 3), "main ↓3"),
            ("both", Sample.git(head: "main", hasUpstream: true, ahead: 1, behind: 4), "main ↑1↓4"),
            // No upstream: the counts are suppressed even when non-zero, the
            // same stale-numbers rule `PaneGitRuns.markers(for:)` states.
            ("no upstream", Sample.git(head: "main", hasUpstream: false, ahead: 5, behind: 6), "main"),
        ]

        for (name, git, expected) in cases {
            let model = ClusterPlaceCardModel.make(
                anchorDisplayName: "baia",
                isLinkedWorktree: false,
                mainCheckoutName: nil,
                git: git,
                workingDirectoryPath: "/Users/gu/Projects/baia",
                home: "/Users/gu"
            )
            #expect(model.branch == expected, "branch for \(name)")

            // The pill's own spelling of the same git value, so a change to the
            // marker vocabulary that the card missed would show up as a
            // disagreement here rather than as two silently different strings.
            let pillMarkers = PaneGitRuns.markerText(for: git)
            let expectedFromPill = pillMarkers.isEmpty ? git.head : "\(git.head) \(pillMarkers)"
            #expect(model.branch == expectedFromPill, "\(name): card vs pill markers")
        }
    }

    @Test func branchIsNilWhenTheHeadIsEmpty() {
        let model = ClusterPlaceCardModel.make(
            anchorDisplayName: "baia",
            isLinkedWorktree: false,
            mainCheckoutName: nil,
            git: Sample.git(head: ""),
            workingDirectoryPath: "/Users/gu/Projects/baia",
            home: "/Users/gu"
        )
        #expect(model.branch == nil)
    }

    @Test func branchIsNilOutsideARepository() {
        let model = ClusterPlaceCardModel.make(
            anchorDisplayName: "notes",
            isLinkedWorktree: false,
            mainCheckoutName: nil,
            git: nil,
            workingDirectoryPath: "/Users/gu/notes",
            home: "/Users/gu"
        )
        #expect(model.branch == nil)
    }

    // MARK: - Place card: a linked worktree names the main checkout

    /// In a linked worktree the anchor *is* the worktree: ``worktreeName``
    /// takes the anchor's own display name, and ``repositoryName`` takes the
    /// main checkout's name resolved through
    /// ``GitDirectory/mainCheckoutName(forLinkedWorktreeRoot:)`` rather than
    /// restating the worktree.
    @Test func aLinkedWorktreeYieldsTheMainCheckoutAsRepositoryNameAndTheWorktreeAsWorktreeName() {
        let model = ClusterPlaceCardModel.make(
            anchorDisplayName: "wave2-card-models",
            isLinkedWorktree: true,
            mainCheckoutName: "baia",
            git: Sample.git(head: "augustoPS/wave2-card-models", isLinkedWorktree: true),
            workingDirectoryPath: "/Users/gu/orca/workspaces/baia/wave2-card-models",
            home: "/Users/gu"
        )
        #expect(model.repositoryName == "baia")
        #expect(model.worktreeName == "wave2-card-models")
    }

    @Test func aMainCheckoutHasNoWorktreeRow() {
        let model = ClusterPlaceCardModel.make(
            anchorDisplayName: "baia",
            isLinkedWorktree: false,
            mainCheckoutName: nil,
            git: Sample.git(head: "main"),
            workingDirectoryPath: "/Users/gu/Projects/baia",
            home: "/Users/gu"
        )
        #expect(model.repositoryName == "baia")
        #expect(model.worktreeName == nil)
    }

    @Test func aLinkedWorktreeWhosePointerCannotBeResolvedFallsBackToItsOwnName() {
        // `mainCheckoutName: nil` is what
        // `GitDirectory.mainCheckoutName(forLinkedWorktreeRoot:)` answers for a
        // pointer it could not resolve (a pruned worktree, for example). The
        // worktree's own name stands for `repositoryName` then, the same
        // fallback the tab already shows, rather than the row going blank.
        let model = ClusterPlaceCardModel.make(
            anchorDisplayName: "orphaned-worktree",
            isLinkedWorktree: true,
            mainCheckoutName: nil,
            git: Sample.git(head: "some-branch", isLinkedWorktree: true),
            workingDirectoryPath: "/Users/gu/orphaned-worktree",
            home: "/Users/gu"
        )
        #expect(model.repositoryName == "orphaned-worktree")
        #expect(model.worktreeName == "orphaned-worktree")
    }

    // MARK: - Attention card: the title rule

    @Test func theAttentionTitleIsAgentDotRepoWithAnAgentRunning() {
        let status = Sample.status(
            anchorName: "baia",
            git: nil,
            agent: PaneStatus.Agent(label: "claude", wantsAttention: true)
        )
        let model = ClusterAttentionCardModel.make(status: status, attentionMessage: "Run the migration?")
        #expect(model.approval?.title == "claude · baia")
    }

    @Test func theAttentionTitleIsTheBareAnchorNameWithNoAgentLabel() {
        // `PaneStatus.attention` derives solely from `agent`
        // (`Attention.init(_:)`), so reaching the gate at all needs a
        // non-nil, `wantsAttention` agent: there is no status shape with
        // `agent == nil` whose attention is `.asking`. An agent that is
        // running but has reported no label yet — the moment right after a
        // process starts, before its first name arrives — is what "no agent"
        // means for the title rule in a status that can still gate the
        // approval open.
        let status = Sample.status(
            anchorName: "baia",
            git: nil,
            agent: PaneStatus.Agent(label: "", wantsAttention: true)
        )
        let model = ClusterAttentionCardModel.make(status: status, attentionMessage: nil)
        #expect(model.approval?.title == "baia")
    }

    // MARK: - Attention card: no approval below the gate

    /// `ApprovalPopover.presents(for:)` is the one gate: below it (``.none``
    /// and ``.done``) the model carries no approval at all, whatever the
    /// agent or the message say.
    @Test func noApprovalModelBelowTheGate() {
        for attention in PaneStatus.Attention.allCases where !ApprovalPopover.presents(for: attention) {
            let agent = PaneStatus.Agent(
                label: "claude",
                wantsAttention: attention == .asking || attention == .acknowledged,
                isAcknowledged: attention == .acknowledged,
                hasFinishedUnseen: attention == .done
            )
            let status = Sample.status(agent: agent)
            #expect(PaneStatus.Attention(status.agent) == attention)

            let model = ClusterAttentionCardModel.make(status: status, attentionMessage: "anything")
            #expect(model.approval == nil, "attention \(attention) should carry no approval")
        }
    }

    @Test func noApprovalModelWithNoStatusAtAll() {
        let model = ClusterAttentionCardModel.make(status: nil, attentionMessage: "anything")
        #expect(model.approval == nil)
    }

    @Test func anApprovalModelIsPresentAtOrAboveTheGate() {
        for attention in PaneStatus.Attention.allCases where ApprovalPopover.presents(for: attention) {
            let agent = PaneStatus.Agent(
                label: "claude",
                wantsAttention: true,
                isAcknowledged: attention == .acknowledged
            )
            let status = Sample.status(agent: agent)
            #expect(PaneStatus.Attention(status.agent) == attention)

            let model = ClusterAttentionCardModel.make(status: status, attentionMessage: "Run it?")
            #expect(model.approval != nil, "attention \(attention) should carry an approval")
            #expect(model.approval?.message == "Run it?")
        }
    }
}
