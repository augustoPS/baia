import Foundation
import Testing

@testable import PaneChrome

@Suite struct PaneClusterSegmentsTests {
    private func roles(_ status: PaneStatus) -> [PaneClusterSegmentRole] {
        PaneClusterSegments.build(from: status).map(\.role)
    }

    private func segment(
        _ role: PaneClusterSegmentRole,
        in status: PaneStatus
    ) -> PaneClusterSegment? {
        PaneClusterSegments.build(from: status).first { $0.role == role }
    }

    @Test func bareShellPaneWearsNoCapsule() {
        #expect(roles(Sample.status(git: nil, agent: nil)) == [])

        // The footer's stale-facts rule, kept: the caller can hold git facts
        // from before a `cd` out of the repository, so `git` being non-nil is
        // not evidence of a repository and the capsule must not say `main` over
        // a plain directory.
        #expect(roles(Sample.status(anchorIsRepository: false, git: Sample.git(dirty: true))) == [])
    }

    @Test func repoPaneGetsPlaceThenChanges() {
        let status = Sample.status(git: Sample.git(ahead: 1, dirty: true))
        #expect(roles(status) == [.place, .changes])
        #expect(segment(.place, in: status)?.text == "main")
    }

    @Test func cleanRepoDropsChanges() {
        // Absent, never empty: an empty changes segment would still cost a gap
        // beside the place name, and a clean repository is the common case.
        #expect(roles(Sample.status(git: Sample.git())) == [.place])
    }

    @Test func agentAndAttentionAppendInOrder() {
        let status = Sample.status(
            git: Sample.git(dirty: true),
            agent: .init(label: "claude", wantsAttention: true)
        )
        #expect(roles(status) == [.place, .changes, .agent, .attention])

        // The dot draws, not reads: attention carries no text of its own.
        #expect(segment(.attention, in: status)?.text == "")
    }

    @Test func changesTextReusesFooterMarkers() {
        // Asserted against the footer's own built segment, not a copy of its
        // vocabulary: if the footer's marker assembly changes and the capsule's
        // does not follow, this fails. The literal pins both against drifting
        // together away from the owner's statusline prefix.
        let git = Sample.git(ahead: 1, dirty: true, untracked: 3)
        let status = Sample.status(git: git)
        let footer = PaneStatusSegments.build(from: status).first { $0.role == .indicators }
        let changes = segment(.changes, in: status)
        #expect(changes?.text == footer?.text)
        #expect(changes?.text == PaneStatusSegments.markerText(for: git))
        #expect(changes?.text == "↑1*?3")
    }

    // MARK: - The notice

    /// A notice takes the pill alone, and the segments it displaces are the
    /// ones that would otherwise be on it. Asserted against the same status
    /// without the notice, so this cannot pass by the status happening to carry
    /// nothing.
    @Test func aNoticeTakesThePillAlone() {
        let git = Sample.git(ahead: 1, dirty: true)
        let agent = PaneStatus.Agent(label: "claude", wantsAttention: true)

        let resting = Sample.status(git: git, agent: agent)
        #expect(roles(resting) == [.place, .changes, .agent, .attention])

        let noticed = Sample.status(
            git: git,
            agent: agent,
            notice: "name is not valid UTF-8, so the shell cannot hold it: rename the file"
        )
        #expect(roles(noticed) == [.notice])
        #expect(
            segment(.notice, in: noticed)?.text
                == "name is not valid UTF-8, so the shell cannot hold it: rename the file"
        )
    }

    /// The capsule and the footer take a notice on the same input and say the
    /// same sentence. Asserted against the footer's own built segment rather
    /// than a copy of the string, the `changesTextReusesFooterMarkers` shape:
    /// the two surfaces answer one `PaneStatus`, and a refusal explained
    /// differently on each is a refusal explained on neither.
    @Test func theNoticeMatchesTheFootersOwnSentence() {
        let reason = "name holds a control character the shell would act on: rename the file"
        let status = Sample.status(git: Sample.git(dirty: true), notice: reason)
        let footer = PaneStatusSegments.build(from: status).first { $0.role == .notice }
        #expect(segment(.notice, in: status)?.text == footer?.text)
        #expect(footer?.text == reason)

        // Both surfaces take it *alone*, which is the half a text comparison
        // cannot see: a capsule that appended the notice beside the branch
        // would still match the footer's string here.
        #expect(roles(status) == [.notice])
        #expect(PaneStatusSegments.build(from: status).map(\.role) == [.notice])
    }

    /// An empty string is not a notice, the footer's own rule
    /// (`PaneStatusSegmentsTests.anEmptyNoticeIsNotANotice`). A caller clearing
    /// one by writing `""` rather than nil must get the resting pill back, not
    /// a pill wearing an empty segment that has eaten every fact.
    @Test func anEmptyNoticeLeavesTheRestingPill() {
        let status = Sample.status(git: Sample.git(dirty: true), notice: "")
        #expect(roles(status) == [.place, .changes])
    }

    /// A notice on a pane with nothing else to say still wears a pill. The
    /// resting capsule vanishes when it has no facts (`bareShellPaneWearsNoCapsule`),
    /// and a refusal in a bare shell pane is exactly when the owner most needs
    /// the reason: the beep is the only other thing that happened.
    @Test func aNoticeGivesABareShellPaneACapsule() {
        #expect(roles(Sample.status(git: nil, agent: nil)) == [])
        #expect(roles(Sample.status(git: nil, agent: nil, notice: "nothing to send")) == [.notice])
    }

    /// Only the notice declines a card. Written over `allCases` rather than as
    /// four literals so a role added later has to answer the question rather
    /// than inherit an answer.
    @Test func everyRoleButTheNoticeOpensACard() {
        for role in PaneClusterSegmentRole.allCases {
            #expect(role.opensCard == (role != .notice))
        }
    }

    @Test func aFinishedAgentStillEarnsTheAttentionDot() {
        // The footer draws a mark for every attention level except `.none`
        // (`PaneStatusBarView.capsuleGlyph(ink:)`), and `done` is a level. A
        // capsule keyed on `wantsAttention` alone would go quiet on exactly the
        // pane that finished while the owner was elsewhere.
        let status = Sample.status(
            agent: .init(label: "claude", wantsAttention: false, hasFinishedUnseen: true)
        )
        #expect(roles(status) == [.agent, .attention])
    }
}
