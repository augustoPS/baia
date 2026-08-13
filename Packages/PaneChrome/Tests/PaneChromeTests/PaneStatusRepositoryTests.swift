import GitWorkspace
import Testing

@testable import PaneChrome

@Suite struct PaneStatusRepositoryTests {
    private func status(
        head: RepositoryStatus.Head = .branch("main"),
        upstream: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        staged: Int = 0,
        unstaged: Int = 0,
        untracked: Int = 0,
        conflicted: Int = 0,
        inProgress: RepositoryStatus.InProgress? = nil
    ) -> RepositoryStatus {
        RepositoryStatus(
            head: head,
            upstream: upstream,
            ahead: ahead,
            behind: behind,
            staged: staged,
            unstaged: unstaged,
            untracked: untracked,
            conflicted: conflicted,
            inProgress: inProgress
        )
    }

    // MARK: - The dirty rule

    /// The three counts each mean dirty on their own. Asserted one at a time
    /// rather than together, because a mapping that read only `staged` would
    /// satisfy any test that always sets all three.
    @Test func eachOfTheThreeCountsMeansDirtyOnItsOwn() {
        #expect(PaneStatus.Git(status(staged: 1), operation: nil, isLinkedWorktree: false).dirty)
        #expect(PaneStatus.Git(status(unstaged: 1), operation: nil, isLinkedWorktree: false).dirty)
        #expect(PaneStatus.Git(status(conflicted: 1), operation: nil, isLinkedWorktree: false).dirty)
    }

    /// Untracked files alone are not dirty, which is the one count that does not
    /// join the rule. `git diff --quiet` says nothing about them, and the capsule
    /// draws them as their own indicator.
    @Test func untrackedFilesAloneAreNotDirty() {
        #expect(!PaneStatus.Git(status(untracked: 3), operation: nil, isLinkedWorktree: false).dirty)
    }

    @Test func aCleanTreeIsNotDirty() {
        #expect(!PaneStatus.Git(status(), operation: nil, isLinkedWorktree: false).dirty)
    }

    // MARK: - Fields that are not a straight copy

    /// `hasUpstream` is the presence of the string, never its content. A branch
    /// tracking a remote whose name happens to be empty still has one.
    @Test func upstreamIsPresenceRatherThanContent() {
        #expect(!PaneStatus.Git(status(upstream: nil), operation: nil, isLinkedWorktree: false)
            .hasUpstream)
        #expect(PaneStatus.Git(status(upstream: ""), operation: nil, isLinkedWorktree: false)
            .hasUpstream)
        #expect(PaneStatus.Git(
            status(upstream: "origin/main"),
            operation: nil,
            isLinkedWorktree: false
        ).hasUpstream)
    }

    /// Ahead and behind are distinct fields and must not be crossed. A mapping
    /// that swapped them would pass any test giving them the same value.
    @Test func aheadAndBehindAreNotCrossed() {
        let git = PaneStatus.Git(status(ahead: 2, behind: 7), operation: nil, isLinkedWorktree: false)
        #expect(git.ahead == 2)
        #expect(git.behind == 7)
    }

    /// Untracked and conflicted likewise. Both are counts of files and both feed
    /// the indicators segment, so a crossed pair draws a plausible bar.
    @Test func untrackedAndConflictedAreNotCrossed() {
        let git = PaneStatus.Git(
            status(untracked: 4, conflicted: 9),
            operation: nil,
            isLinkedWorktree: false
        )
        #expect(git.untracked == 4)
        #expect(git.conflicted == 9)
    }

    @Test func theHeadIsTheStatusDisplayHead() {
        #expect(PaneStatus.Git(
            status(head: .detached(commit: "abc1234")),
            operation: nil,
            isLinkedWorktree: false
        ).head == status(head: .detached(commit: "abc1234")).displayHead)
    }

    // MARK: - The two fields the status does not carry

    /// Neither is derivable from `status`, so both must arrive from the caller
    /// unchanged. The poller passes the anchor's answer and the palette passes
    /// false; a mapping that hardcoded either would show a pane in a linked
    /// worktree as if it were in the main checkout.
    @Test func theWorktreeFlagAndOperationComeFromTheCallerUntouched() {
        let inWorktree = PaneStatus.Git(status(), operation: "REBASE", isLinkedWorktree: true)
        #expect(inWorktree.isLinkedWorktree)
        #expect(inWorktree.operation == "REBASE")

        let plain = PaneStatus.Git(status(inProgress: .rebase), operation: nil, isLinkedWorktree: false)
        #expect(!plain.isLinkedWorktree)
        // Nil even though the status names an operation: the mapping never reads
        // `inProgress` itself, which is what lets the palette drop the label.
        #expect(plain.operation == nil)
    }

    // MARK: - The operation label

    @Test func everyInProgressStateHasItsOwnLabel() {
        #expect(PaneStatus.Git.operationLabel(for: nil) == nil)
        #expect(PaneStatus.Git.operationLabel(for: .rebase) == "REBASE")
        #expect(PaneStatus.Git.operationLabel(for: .merge) == "MERGE")
        #expect(PaneStatus.Git.operationLabel(for: .cherryPick) == "CHERRY-PICK")
        #expect(PaneStatus.Git.operationLabel(for: .revert) == "REVERT")
        #expect(PaneStatus.Git.operationLabel(for: .bisect) == "BISECT")
    }

    /// The five labels are distinct. Without this a mapping collapsing two
    /// states onto one string passes every assertion above that it happens to
    /// agree with, and the capsule says MERGE during a revert.
    @Test func noTwoOperationsShareALabel() {
        let states: [RepositoryStatus.InProgress] = [.rebase, .merge, .cherryPick, .revert, .bisect]
        let labels = states.compactMap { PaneStatus.Git.operationLabel(for: $0) }
        #expect(labels.count == states.count)
        #expect(Set(labels).count == states.count)
    }

    /// Upper case is the rule, not an accident of the five strings chosen. The
    /// chrome is otherwise all lower case, which is what makes an operation
    /// readable at a glance.
    @Test func everyLabelIsUpperCase() {
        for state in [
            RepositoryStatus.InProgress.rebase, .merge, .cherryPick, .revert, .bisect
        ] {
            let label = PaneStatus.Git.operationLabel(for: state)
            #expect(label == label?.uppercased())
        }
    }

    // MARK: - Every surface reads the dirty rule through this mapping

    /// The palette's line and the marker assembly reach the same dirty answer,
    /// because both reach it through this one mapping. It is the duplicate the
    /// move collapsed: two copies agreed by luck for as long as nobody corrected
    /// one of them.
    ///
    /// The second surface was the footer's indicators segment until 2026-08-13.
    /// `PaneGitRuns.markers(for:)` took over as the assembly the tab title and
    /// the capsule both read, so it is the one compared against now — the same
    /// test with the surviving reader in the dead one's place.
    @Test func thePaletteSeesTheSameDirtyAnswerTheMarkersDo() {
        // Conflicted alone. It is the count whose membership in the dirty rule is
        // a judgement rather than an obvious fact, so it is the one a second copy
        // of the rule would have got wrong.
        let conflicted = status(conflicted: 1)
        let fromMapping = PaneStatus.Git(conflicted, operation: nil, isLinkedWorktree: false)
        #expect(fromMapping.dirty)

        let markers = PaneGitRuns.markerText(for: fromMapping)
        #expect(markers.contains("*"))

        // The palette's line carries those same markers rather than assembling
        // its own, so the two render identically for one status.
        let runs = PaneGitRuns.runs(for: conflicted)
        #expect(runs.map(\.text).joined().contains(markers))
    }
}
