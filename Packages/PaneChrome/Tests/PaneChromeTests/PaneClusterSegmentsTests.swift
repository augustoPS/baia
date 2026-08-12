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
