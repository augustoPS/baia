import Foundation
import Testing

@testable import PaneChrome

@Suite struct PaneStatusSegmentsTests {
    /// The roles the builder produced, in the order it produced them. Every
    /// ordering assertion goes through this rather than through indices, so a new
    /// suppression rule that changes how many segments a status yields does not
    /// silently move what an index means.
    private func roles(_ status: PaneStatus) -> [PaneStatusSegmentRole] {
        PaneStatusSegments.build(from: status).map(\.role)
    }

    private func segment(
        _ role: PaneStatusSegmentRole,
        in status: PaneStatus
    ) -> PaneStatusSegment? {
        PaneStatusSegments.build(from: status).first { $0.role == role }
    }

    @Test func aRepositoryEmitsItsNameThenTheBranchThenTheIndicators() {
        let status = Sample.status(git: Sample.git(ahead: 1, dirty: true))
        #expect(roles(status) == [.anchorName, .branch, .indicators])
    }

    @Test func aPlainAnchorEmitsNoGitSegmentsEvenWhenGitDataIsSupplied() {
        // The caller legitimately holds git facts from before a `cd` out of the
        // repository, so `git` being non-nil is not evidence of a repository. A
        // branch drawn on a plain directory is a fact the owner would act on,
        // and acting on the wrong repository is a recorded, thrice-repeated
        // mistake here.
        let status = Sample.status(
            anchorIsRepository: false,
            git: Sample.git(ahead: 4, dirty: true, untracked: 2, operation: "REBASE 1/3")
        )
        #expect(roles(status) == [.anchorName])
    }

    @Test func noUpstreamDropsAheadBehindEvenWhenTheCountsAreNonZero() {
        // The counts are non-zero on purpose. A detached HEAD or a deleted
        // upstream leaves the last successful ahead and behind in place, and an
        // implementation that only zeroed them when they were already zero
        // would pass a test built on a clean branch.
        let status = Sample.status(
            git: Sample.git(hasUpstream: false, ahead: 3, behind: 7, dirty: true)
        )
        #expect(segment(.indicators, in: status)?.text == "*")
    }

    @Test func upstreamCountsUseTheOwnersStatuslineVocabulary() {
        // The mirror of noUpstreamDropsAheadBehindEvenWhenTheCountsAreNonZero:
        // same counts, an upstream present. Either test alone passes whichever
        // way the upstream check goes.
        let status = Sample.status(
            git: Sample.git(ahead: 1, behind: 2, dirty: true, untracked: 3)
        )
        #expect(segment(.indicators, in: status)?.text == "↑1↓2*?3")
    }

    @Test func aCleanRepositoryEmitsNoIndicatorsSegment() {
        // An empty indicators segment still costs a spacing gap, so the branch
        // name in a clean pane would sit one gap left of where it sits in a
        // dirty one and the panes would look mis-aligned against each other.
        let status = Sample.status(git: Sample.git())
        #expect(roles(status) == [.anchorName, .branch])
    }

    @Test func conflictedFilesRaiseTheIndicatorsToAlert() {
        let clean = Sample.status(git: Sample.git(dirty: true))
        let conflicted = Sample.status(git: Sample.git(dirty: true, conflicted: 2))
        #expect(segment(.indicators, in: clean)?.emphasis == .normal)
        #expect(segment(.indicators, in: conflicted)?.emphasis == .alert)
    }

    @Test func conflictedFilesAreCountedAfterTheOwnersOwnMarkers() {
        // The prefix stays byte for byte what his prompt shows, so the string
        // is still recognisable at a glance with a conflict count on the end.
        let status = Sample.status(git: Sample.git(ahead: 1, dirty: true, conflicted: 2))
        #expect(segment(.indicators, in: status)?.text == "↑1*!2")
    }

    @Test func theAnchorNameOutranksEveryOtherSegment() {
        let segments = PaneStatusSegments.build(from: Sample.everything())
        let name = segments.first { $0.role == .anchorName }
        let others = segments.filter { $0.role != .anchorName }
        #expect(others.allSatisfy { $0.priority < (name?.priority ?? 0) })
    }

    @Test func theIndicatorsOutrankTheBranchName() {
        // Deliberate, and the reason the two are separate segments at all. A
        // pane that has lost its branch name still says there is uncommitted
        // work; one that has lost the markers says nothing about it, and
        // uncommitted work found too late is what the wrap-up guard hook exists
        // to patch.
        let status = Sample.status(git: Sample.git(dirty: true))
        let indicators = segment(.indicators, in: status)?.priority ?? 0
        let branch = segment(.branch, in: status)?.priority ?? 0
        #expect(indicators > branch)
    }

    @Test func theWorkingDirectoryIsTheFirstThingToGo() {
        let segments = PaneStatusSegments.build(from: Sample.everything())
        let directory = segments.first { $0.role == .workingDirectory }
        let others = segments.filter { $0.role != .workingDirectory }
        #expect(others.allSatisfy { $0.priority > (directory?.priority ?? 0) })
    }

    @Test func thePinMarkerAppearsOnlyWhenPinned() {
        #expect(segment(.pin, in: Sample.status(isPinned: true)) != nil)
        #expect(segment(.pin, in: Sample.status(isPinned: false)) == nil)
    }

    @Test func theOperationLabelIsPassedThroughVerbatim() {
        // Formatted by the caller, which is the only side that can read
        // `.git/rebase-merge/msgnum`. Reformatting it here could only lose the
        // position, and `REBASE` without `1/3` is the half-fact that makes
        // someone continue the wrong rebase.
        let status = Sample.status(git: Sample.git(operation: "REBASE 1/3"))
        #expect(segment(.operation, in: status)?.text == "REBASE 1/3")
    }

    @Test func theOperationIsStrongRatherThanAlert() {
        // One alert colour on the bar has to mean one thing. Conflicted files
        // and an agent waiting are worth interrupting for; a rebase in progress
        // is worth noticing, and if both look identical neither gets read.
        let status = Sample.status(git: Sample.git(conflicted: 1, operation: "REBASE 1/3"))
        #expect(segment(.operation, in: status)?.emphasis == .strong)
        #expect(segment(.indicators, in: status)?.emphasis == .alert)
    }

    @Test func theOperationLeadsTheBranchItIsHappeningTo() {
        let status = Sample.status(git: Sample.git(dirty: true, operation: "REBASE 1/3"))
        #expect(roles(status) == [.anchorName, .operation, .branch, .indicators])
    }

    @Test func aBlankOperationLabelEmitsNoSegment() {
        // A caller that read an empty `.git/rebase-merge` file hands over
        // whitespace rather than nil, and whitespace still draws as an empty
        // box with a spacing gap on either side.
        let status = Sample.status(git: Sample.git(operation: "  "))
        #expect(segment(.operation, in: status) == nil)
    }

    @Test func aLinkedWorktreeMarksItsBranch() {
        // Both worktree layouts in use here put a checkout of the same
        // repository at a second path, so the anchor name and the branch alone
        // cannot tell a worktree pane from the main checkout, and running the
        // wrong one is the recorded mistake. The marker leads the branch so
        // tail truncation eats the branch name before it eats the warning.
        let main = Sample.status(git: Sample.git(head: "feature"))
        let linked = Sample.status(git: Sample.git(head: "feature", isLinkedWorktree: true))
        #expect(segment(.branch, in: main)?.text == "feature")
        #expect(segment(.branch, in: linked)?.text == "wt:feature")
    }

    @Test func anAgentSegmentIsAlertOnlyWhenItWantsAttention() {
        let quiet = Sample.status(agent: .init(label: "claude", wantsAttention: false))
        let waiting = Sample.status(agent: .init(label: "claude", wantsAttention: true))
        #expect(segment(.agent, in: quiet)?.emphasis == .normal)
        #expect(segment(.agent, in: waiting)?.emphasis == .alert)
    }

    @Test func noAgentSegmentWithoutAnAgent() {
        #expect(segment(.agent, in: Sample.status()) == nil)
        #expect(segment(.agent, in: Sample.status(agent: .init(label: "", wantsAttention: true))) == nil)
    }

    @Test func namesTruncateFromTheTailAndPathsFromTheHead() {
        // A path cut at the tail leaves every deep directory in one project
        // looking identical, which is the opposite of what the segment is for.
        // A name cut at the head loses the project.
        let status = Sample.everything()
        #expect(segment(.anchorName, in: status)?.truncation == .tail)
        #expect(segment(.branch, in: status)?.truncation == .tail)
        #expect(segment(.workingDirectory, in: status)?.truncation == .head)
    }

    @Test func theWorkingDirectorySitsAtTheTrailingEdgeWithTheAgent() {
        let status = Sample.everything()
        #expect(segment(.workingDirectory, in: status)?.alignment == .trailing)
        #expect(segment(.agent, in: status)?.alignment == .trailing)
        #expect(segment(.anchorName, in: status)?.alignment == .leading)
    }

    @Test func noWorkingDirectorySegmentWhenTheShellSitsAtTheAnchor() {
        #expect(segment(.workingDirectory, in: Sample.status(workingDirectory: nil)) == nil)
    }

    @Test func aBlankWorkingDirectoryEmitsNoSegment() {
        #expect(segment(.workingDirectory, in: Sample.status(workingDirectory: " ")) == nil)
    }

    @Test func anEmptyAnchorNameEmitsNoSegment() {
        // A pane's first poll legitimately finds no anchor: no ghostty surface
        // exists until the view is in a window with non-zero bounds, so
        // `foregroundPid` returns nil and nothing has resolved yet. An empty
        // name segment would draw as a gap where the name is about to appear.
        #expect(roles(Sample.status(anchorName: "", git: nil)) == [])
    }

    @Test func everyRoleIsReachable() {
        // Guards a role added to the enum and then never built, which compiles
        // cleanly and presents as a fact the bar silently never shows.
        let built = Set(PaneStatusSegments.build(from: Sample.everything()).map(\.role))
        #expect(built == Set(PaneStatusSegmentRole.allCases))
    }
}
