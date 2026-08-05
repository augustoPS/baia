import Foundation
import GitWorkspace
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
        // The headline emphasis of a multi-run segment is its loudest run, so a
        // caller that reads only `emphasis` still sees the emergency. A dirty
        // tree on its own is a warning rather than plain state, which is the one
        // marker that costs you if you miss it.
        let dirty = Sample.status(git: Sample.git(dirty: true))
        let conflicted = Sample.status(git: Sample.git(dirty: true, conflicted: 2))
        #expect(segment(.indicators, in: dirty)?.emphasis == .warn)
        #expect(segment(.indicators, in: conflicted)?.emphasis == .alert)
    }

    @Test func eachMarkerCarriesItsOwnMeaningWithoutSplittingTheSegment() {
        // One string, one measured width, dropped whole, four colours inside it.
        // The markers do not mean the same thing as each other, and giving them
        // one colour made the reader parse the glyphs to find that out. Splitting
        // them into segments instead would let width pressure keep the ahead
        // count and drop the dirty marker, which is exactly backwards.
        let status = Sample.status(
            git: Sample.git(ahead: 1, behind: 2, dirty: true, untracked: 3, conflicted: 4)
        )
        let markers = segment(.indicators, in: status)
        #expect(markers?.text == "↑1↓2*?3!4")
        #expect(markers?.runs.map(\.text) == ["↑1", "↓2", "*", "?3", "!4"])
        #expect(markers?.runs.map(\.emphasis) == [.info, .info, .warn, .context, .alert])
    }

    @Test func theRunsOfASegmentAlwaysJoinBackToItsText() {
        // The width solver measures `text`, so a segment whose runs said anything
        // else would measure one string and draw another, and the bar would
        // overflow only on the panes carrying the most state.
        for status in [Sample.everything(), Sample.status(git: Sample.git(isLinkedWorktree: true))] {
            for segment in PaneStatusSegments.build(from: status) {
                #expect(segment.runs.map(\.text).joined() == segment.text)
                #expect(!segment.runs.isEmpty)
            }
        }
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

    @Test func theOperationIsAWarningRatherThanAnAlert() {
        // One alert colour on the bar has to mean one thing. Conflicted files
        // and an agent waiting are worth interrupting for; a rebase in progress
        // is worth noticing, and if both look identical neither gets read. It is
        // no longer `strong` either: strong is identity, and a half-finished
        // rebase changes what every other fact on the bar means, which is the
        // definition of a warning.
        let status = Sample.status(git: Sample.git(conflicted: 1, operation: "REBASE 1/3"))
        #expect(segment(.operation, in: status)?.emphasis == .warn)
        #expect(segment(.indicators, in: status)?.emphasis == .alert)
        #expect(segment(.anchorName, in: status)?.emphasis == .strong)
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
        // A working agent is tier 4. It is the state four panes are in most of
        // the time, so it has to be the calmest thing in the app, and anything
        // louder would spend the reader's attention on the one fact that is
        // never actionable.
        let quiet = Sample.status(agent: .init(label: "claude", wantsAttention: false))
        let waiting = Sample.status(agent: .init(label: "claude", wantsAttention: true))
        #expect(segment(.agent, in: quiet)?.emphasis == .context)
        #expect(segment(.agent, in: waiting)?.emphasis == .alert)
    }

    @Test func noAgentSegmentWithoutAnAgent() {
        #expect(segment(.agent, in: Sample.status()) == nil)
        #expect(segment(.agent, in: Sample.status(agent: .init(label: "", wantsAttention: true))) == nil)
    }

    @Test func anAcknowledgedAgentDimsToContext() {
        let status = PaneStatus(
            anchorName: "baia",
            anchorIsRepository: false,
            isPinned: false,
            workingDirectory: nil,
            git: nil,
            agent: .init(label: "waiting", wantsAttention: true, isAcknowledged: true)
        )
        let agent = PaneStatusSegments.build(from: status).first { $0.role == .agent }
        #expect(agent?.emphasis == .context)
    }

    @Test func anUnacknowledgedAgentStaysAlert() {
        let status = PaneStatus(
            anchorName: "baia",
            anchorIsRepository: false,
            isPinned: false,
            workingDirectory: nil,
            git: nil,
            agent: .init(label: "waiting", wantsAttention: true, isAcknowledged: false)
        )
        let agent = PaneStatusSegments.build(from: status).first { $0.role == .agent }
        #expect(agent?.emphasis == .alert)
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

    /// The widest trailing segment on a line that must not wrap, so it carries
    /// the same shortening the shell prompt and the window subtitle use. A shell
    /// under `$TMPDIR` otherwise spends it on a machine-generated prefix.
    @Test func theWorkingDirectoryIsShortenedToItsLastTwoComponents() {
        let deep = Sample.status(workingDirectory: "/private/var/folders/pp/4p7nc/T/repo/src")
        #expect(segment(.workingDirectory, in: deep)?.text == "../repo/src")

        // Head truncation stays the fallback for a path that is still too wide
        // after shortening, so the two are not alternatives.
        let short = Sample.status(workingDirectory: "~/Projects")
        #expect(segment(.workingDirectory, in: short)?.text == "~/Projects")
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
        //
        // Two statuses rather than one, and the split is the rule rather than a
        // concession to make the assertion pass. Every role is reachable from a
        // status that has everything, except `.notice`, which is reachable only
        // from a status that has one *and* is unreachable from any status that
        // does not, because a notice replaces the bar. Asserting the union alone
        // would let a build that emitted `.notice` beside the branch pass, which
        // is the arrangement `PaneStatus.notice` exists to prevent.
        let ordinary = Set(PaneStatusSegments.build(from: Sample.everything()).map(\.role))
        let noticed = Set(PaneStatusSegments
            .build(from: Sample.everything(notice: "refused"))
            .map(\.role))

        #expect(ordinary == Set(PaneStatusSegmentRole.allCases).subtracting([.notice]))
        #expect(noticed == [.notice])
        #expect(ordinary.union(noticed) == Set(PaneStatusSegmentRole.allCases))
    }

    // MARK: - runs(for:)

    @Test func runsJoinsTheBranchAndIndicatorsWithASpace() {
        // The palette row has no room for a second line, so the two segments
        // `build(from:)` would draw apart are flattened onto one, with a space
        // run standing in for the gap between them.
        let status = RepositoryStatus(head: .branch("main"), upstream: "origin/main", ahead: 1)
        let runs = PaneStatusSegments.runs(for: status)
        #expect(runs.map(\.text).joined() == "main ↑1")
        #expect(runs.map(\.text) == ["main", " ", "↑1"])
    }

    @Test func runsDropsTheSpaceWhenThereAreNoIndicators() {
        let status = RepositoryStatus(head: .branch("main"))
        let runs = PaneStatusSegments.runs(for: status)
        #expect(runs.map(\.text) == ["main"])
    }

    @Test func runsReadsDirtyFromStagedUnstagedOrConflicted() {
        // Three ways a tree can be dirty, none of them `ahead`/`behind`, so a
        // status with only one of the three still has to raise the marker.
        for status in [
            RepositoryStatus(head: .branch("main"), staged: 1),
            RepositoryStatus(head: .branch("main"), unstaged: 1),
            RepositoryStatus(head: .branch("main"), conflicted: 1),
        ] {
            #expect(PaneStatusSegments.runs(for: status).map(\.text).contains("*"))
        }
    }

    @Test func runsDropsAheadAndBehindWithNoUpstream() {
        let status = RepositoryStatus(head: .branch("main"), ahead: 3, behind: 2)
        #expect(PaneStatusSegments.runs(for: status).map(\.text) == ["main"])
    }

    @Test func runsUsesTheDisplayHeadForADetachedCommit() {
        let status = RepositoryStatus(head: .detached(commit: "abc1234567"))
        #expect(PaneStatusSegments.runs(for: status).map(\.text) == ["(abc1234)"])
    }

    // MARK: - The notice

    /// A notice takes the bar alone, and the git segments it displaces are the
    /// point rather than a side effect: a reason competing for width with the
    /// branch would be dropped on exactly the narrow pane where an unexplained
    /// refusal is most confusing.
    @Test func aNoticeReplacesEverySegmentRatherThanJoiningThem() {
        let status = Sample.status(
            isPinned: true,
            workingDirectory: "~/src",
            git: Sample.git(ahead: 2, dirty: true, untracked: 1),
            agent: PaneStatus.Agent(label: "claude", wantsAttention: true),
            notice: "name is not valid UTF-8"
        )
        #expect(roles(status) == [.notice])
        #expect(segment(.notice, in: status)?.text == "name is not valid UTF-8")
    }

    /// The same status without the notice is the control: everything the notice
    /// displaced really was there to displace.
    @Test func theSameStatusWithoutANoticeEmitsItsOrdinarySegments() {
        let ordinary = Sample.status(
            isPinned: true,
            workingDirectory: "~/src",
            git: Sample.git(ahead: 2, dirty: true, untracked: 1),
            agent: PaneStatus.Agent(label: "claude", wantsAttention: true)
        )
        #expect(roles(ordinary).contains(.anchorName))
        #expect(roles(ordinary).contains(.indicators))
        #expect(roles(ordinary) != [.notice])
    }

    /// An empty string is not a notice. A caller clearing one by writing `""`
    /// rather than nil would otherwise blank the whole bar for three seconds,
    /// which reads as the pane having died.
    @Test func anEmptyNoticeIsIgnoredRatherThanBlankingTheBar() {
        let status = Sample.status(git: Sample.git(dirty: true), notice: "")
        #expect(roles(status) == [.anchorName, .branch, .indicators])
    }

    /// Drawn in the alert colour, since it exists to say something was refused,
    /// and never truncated: a clipped reason still names the problem where an
    /// ellipsis does not.
    @Test func aNoticeIsAlertAndIsNotTruncated() {
        let status = Sample.status(notice: "name holds a control character")
        let notice = segment(.notice, in: status)
        #expect(notice?.emphasis == .alert)
        #expect(notice?.truncation == PaneStatusTruncation.none)
        #expect(notice?.alignment == .leading)
    }

    /// The notice does not touch attention. The wash, the frame and the tab
    /// glyph are read from `status.attention`, so a pane that is asking keeps
    /// saying so in colour while the notice occupies the text, which is what lets
    /// the two share a bar with no rule about which wins.
    @Test func aNoticeLeavesAttentionAlone() {
        let asking = Sample.status(
            agent: PaneStatus.Agent(label: "claude", wantsAttention: true),
            notice: "nothing to send"
        )
        #expect(asking.attention == .asking)
    }
}
