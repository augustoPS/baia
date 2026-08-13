import Foundation
import GitWorkspace
import Testing

@testable import PaneChrome

/// The git marker vocabulary, which is what survived `PaneStatusSegmentsTests`
/// when the footer's segment table was deleted on 2026-08-13.
///
/// Most of the suite this replaces graded the table rather than the vocabulary:
/// priorities, alignments, truncation ends, which roles a status emits and in
/// what order. All of that was the bar's placement contract and went with the
/// bar. What is asserted here is what three surfaces still read — the marker
/// glyphs, their tiers, and the branch beside them.
@Suite struct PaneGitRunsTests {
    private func markerText(_ git: PaneStatus.Git) -> String {
        PaneGitRuns.markerText(for: git)
    }

    // MARK: - The markers

    @Test func noUpstreamDropsAheadBehindEvenWhenTheCountsAreNonZero() {
        // The counts are non-zero on purpose. A detached HEAD or a deleted
        // upstream leaves the last successful ahead and behind in place, and an
        // implementation that only zeroed them when they were already zero
        // would pass a test built on a clean branch.
        let git = Sample.git(hasUpstream: false, ahead: 3, behind: 7, dirty: true)
        #expect(markerText(git) == "*")
    }

    @Test func upstreamCountsUseTheOwnersStatuslineVocabulary() {
        // The mirror of noUpstreamDropsAheadBehindEvenWhenTheCountsAreNonZero:
        // same counts, an upstream present. Either test alone passes whichever
        // way the upstream check goes.
        let git = Sample.git(ahead: 1, behind: 2, dirty: true, untracked: 3)
        #expect(markerText(git) == "↑1↓2*?3")
    }

    @Test func aCleanRepositoryEmitsNoMarkersAtAll() {
        // Empty rather than a placeholder. Both remaining readers of the string
        // branch on `isEmpty` to decide whether to draw anything at all: the
        // capsule would otherwise pay a segment gap to draw nothing in it
        // (`PaneClusterSegments.build`), and the tab title would spend budget on
        // a separator with no markers behind it.
        #expect(markerText(Sample.git()).isEmpty)
        #expect(PaneGitRuns.markers(for: Sample.git()).isEmpty)
    }

    @Test func eachMarkerCarriesItsOwnTierWithoutSplittingTheWord() {
        // One string, four colours inside it. The markers do not mean the same
        // thing as each other, and giving them one colour made the reader parse
        // the glyphs to find that out: a count to act on eventually, a dirty
        // tree that costs you if you miss it, untracked files that are a fact,
        // and a conflict that is an emergency.
        let git = Sample.git(ahead: 1, behind: 2, dirty: true, untracked: 3, conflicted: 4)
        let runs = PaneGitRuns.markers(for: git)
        #expect(runs.map(\.text) == ["↑1", "↓2", "*", "?3", "!4"])
        #expect(runs.map(\.emphasis) == [.info, .info, .warn, .context, .alert])
    }

    @Test func conflictedFilesAreCountedAfterTheOwnersOwnMarkers() {
        // The prefix stays byte for byte what his prompt shows, so the string
        // is still recognisable at a glance with a conflict count on the end.
        #expect(markerText(Sample.git(ahead: 1, dirty: true, conflicted: 2)) == "↑1*!2")
    }

    @Test func theMarkerTextIsTheMarkerRunsJoinedUnspaced() {
        // `TerminalPaneController.tabTitle` budgets the title's width against
        // this string and draws the same glyphs, so a text form that spaced or
        // reordered what the runs say would measure one thing and draw another.
        for git in [
            Sample.git(ahead: 1, behind: 2, dirty: true, untracked: 3, conflicted: 4),
            Sample.git(dirty: true),
            Sample.git(),
        ] {
            #expect(markerText(git) == PaneGitRuns.markers(for: git).map(\.text).joined())
        }
    }

    // MARK: - The palette's line

    @Test func runsJoinsTheBranchAndMarkersWithASpace() {
        // The palette row has no room for a second line, so what the bar drew as
        // two separated cells is flattened onto one with a space run standing in
        // for the gap.
        let status = RepositoryStatus(head: .branch("main"), upstream: "origin/main", ahead: 1)
        let runs = PaneGitRuns.runs(for: status)
        #expect(runs.map(\.text) == ["main", " ", "↑1"])
        #expect(runs.map(\.text).joined() == "main ↑1")
    }

    @Test func runsDropsTheSpaceWhenThereAreNoMarkers() {
        // The separator is paid for by the markers, not by the branch: a clean
        // repository must not leave a trailing space the palette then draws.
        let status = RepositoryStatus(head: .branch("main"))
        #expect(PaneGitRuns.runs(for: status).map(\.text) == ["main"])
    }

    @Test func runsDropsTheSpaceWhenThereIsNoBranch() {
        // The mirror of the above, and the arm the old implementation got right
        // only by accident: it appended the separator when the accumulator was
        // non-empty, so an empty head made the markers the first entry and the
        // space never appeared. Asserted directly, because the branch and the
        // markers are now assembled by two functions rather than filtered out of
        // one list, and a separator emitted unconditionally between them would
        // put a leading space in front of the markers here.
        let status = RepositoryStatus(head: .branch(""), staged: 1)
        #expect(PaneGitRuns.runs(for: status).map(\.text) == ["*"])
    }

    @Test func runsReadsDirtyFromStagedUnstagedOrConflicted() {
        // Three ways a tree can be dirty, none of them `ahead`/`behind`, so a
        // status with only one of the three still has to raise the marker.
        for status in [
            RepositoryStatus(head: .branch("main"), staged: 1),
            RepositoryStatus(head: .branch("main"), unstaged: 1),
            RepositoryStatus(head: .branch("main"), conflicted: 1),
        ] {
            #expect(PaneGitRuns.runs(for: status).map(\.text).contains("*"))
        }
    }

    @Test func runsDropsAheadAndBehindWithNoUpstream() {
        let status = RepositoryStatus(head: .branch("main"), ahead: 3, behind: 2)
        #expect(PaneGitRuns.runs(for: status).map(\.text) == ["main"])
    }

    @Test func runsUsesTheDisplayHeadForADetachedCommit() {
        let status = RepositoryStatus(head: .detached(commit: "abc1234567"))
        #expect(PaneGitRuns.runs(for: status).map(\.text) == ["(abc1234)"])
    }

    @Test func thePaletteRowNeverClaimsAWorktree() {
        // A palette row names a project rather than a pane, and nothing there has
        // been anchored to a checkout yet, so `runs(for:)` passes the flag false
        // rather than defaulting it. Asserted against a repository whose branch
        // would carry the prefix if the flag ever went the other way.
        let status = RepositoryStatus(head: .branch("feature"))
        #expect(PaneGitRuns.runs(for: status).map(\.text) == ["feature"])
    }

    // MARK: - The branch

    @Test func aLinkedWorktreeMarksItsBranchWithoutOutshoutingIt() {
        // Both worktree layouts in use here put a checkout of the same
        // repository at a second path, so the branch name alone cannot tell a
        // worktree pane from the main checkout, and running the wrong one is the
        // recorded mistake. The prefix leads the branch so a caller truncating
        // from the tail eats the branch name before the warning, and it is drawn
        // one tier quieter so the branch still reads first.
        let git = Sample.git(head: "feature", isLinkedWorktree: true)
        let runs = PaneGitRuns.branch(for: git)
        #expect(runs.map(\.text) == ["wt:", "feature"])
        #expect(runs.map(\.emphasis) == [.context, .normal])
    }

    @Test func theMainCheckoutCarriesNoPrefix() {
        let runs = PaneGitRuns.branch(for: Sample.git(head: "feature"))
        #expect(runs.map(\.text) == ["feature"])
        #expect(runs.map(\.emphasis) == [.normal])
    }

    @Test func anEmptyHeadEmitsNoBranchRunRatherThanAnEmptyOne() {
        // An empty run is not free: it makes `runs(for:)` pay a separator for a
        // branch that is not there, and it would draw as a zero-width stretch the
        // palette still advances its pen past.
        #expect(PaneGitRuns.branch(for: Sample.git(head: "")).isEmpty)
        #expect(PaneGitRuns.branch(for: Sample.git(head: "", isLinkedWorktree: true)).isEmpty)
    }

    // MARK: - The blankness predicate

    @Test func whitespaceIsBlankButContentIsNot() {
        // A poller that formatted an operation label from an empty git file hands
        // over `" "`, which is neither nil nor `isEmpty` and still draws as an
        // empty box. This is the predicate `PaneStatus.Git.displayableOperation`
        // asks so that no surface has to spell its own.
        #expect(PaneGitRuns.isBlank(""))
        #expect(PaneGitRuns.isBlank("   "))
        #expect(PaneGitRuns.isBlank("\n\t"))
        #expect(!PaneGitRuns.isBlank("REBASE 1/3"))
        #expect(!PaneGitRuns.isBlank(" REBASE "))
    }
}
