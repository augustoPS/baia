import Foundation
import Testing

@testable import GitWorkspace

/// The equality rule that decides when a surface redraws.
@Suite struct RepositorySnapshotTests {
    private let root = RepositoryRoot(URL(filePath: "/tmp/repo"))

    private func snapshot(
        generation: UInt64 = 1,
        readAt: Date? = nil,
        status: RepositoryStatus? = RepositoryStatus(head: .branch("main"), unstaged: 1),
        changes: [RepositoryFileChange] = [RepositoryFileChange(path: "a.txt", worktree: .modified, kind: .ordinary)],
        defaultBranch: RepositorySnapshot.DefaultBranchState = .known(nil),
        tree: RepositorySnapshot.TreeState = .unread,
        health: RepositorySnapshot.ReadHealth = .ok
    ) -> RepositorySnapshot {
        RepositorySnapshot(
            root: root,
            generation: generation,
            readAt: readAt,
            status: status,
            changes: changes,
            defaultBranch: defaultBranch,
            isLinkedWorktree: false,
            tree: tree,
            health: health
        )
    }

    /// A poll that found nothing new moves only the counters, and that is not a
    /// change.
    @Test func generationAndReadTimeAreNotRenderedFields() {
        let first = snapshot(generation: 1, readAt: Date(timeIntervalSince1970: 1))
        let second = snapshot(generation: 2, readAt: Date(timeIntervalSince1970: 2))

        #expect(first == second)
    }

    /// **The R07 case.** A rename keeps every count and the branch, and changes
    /// the paths. The paths are rendered, so the snapshots differ.
    @Test func equalCountsWithDifferentPathsAreDifferentSnapshots() {
        let before = snapshot(changes: [RepositoryFileChange(path: "a.txt", worktree: .modified, kind: .ordinary)])
        let after = snapshot(changes: [RepositoryFileChange(path: "b.txt", worktree: .modified, kind: .ordinary)])

        #expect(before.status == after.status)
        #expect(before != after)
    }

    @Test func treeHealthAndDefaultBranchAreRenderedFields() {
        let base = snapshot()

        #expect(base != snapshot(tree: .empty))
        #expect(base != snapshot(health: .failed(.timedOut, attempts: 1)))
        #expect(base != snapshot(defaultBranch: .known("develop")))
    }

    @Test func onlyALoadedTreeHasRows() {
        let node = FileTreeNode(name: "a", path: "a", isDirectory: false, children: [])

        #expect(RepositorySnapshot.TreeState.unread.nodes.isEmpty)
        #expect(RepositorySnapshot.TreeState.empty.nodes.isEmpty)
        #expect(RepositorySnapshot.TreeState.failed(.timedOut, attempts: 2).nodes.isEmpty)
        #expect(RepositorySnapshot.TreeState.loaded([node]).nodes == [node])
    }

    /// The tab label's rule, kept exactly: true while nothing is known, never for
    /// a detached head, by the recorded default when there is one, and by the
    /// conventional names when no remote has ever said.
    @Test func isOnDefaultBranchFollowsTheResolverRule() {
        #expect(snapshot(status: nil).isOnDefaultBranch)
        #expect(!snapshot(status: RepositoryStatus(head: .detached(commit: "abc1234"))).isOnDefaultBranch)
        #expect(snapshot(status: RepositoryStatus(head: .branch("develop")), defaultBranch: .known("develop")).isOnDefaultBranch)
        #expect(!snapshot(status: RepositoryStatus(head: .branch("main")), defaultBranch: .known("develop")).isOnDefaultBranch)
        #expect(snapshot(status: RepositoryStatus(head: .branch("master")), defaultBranch: .known(nil)).isOnDefaultBranch)
        #expect(!snapshot(status: RepositoryStatus(head: .branch("topic")), defaultBranch: .known(nil)).isOnDefaultBranch)
        #expect(snapshot(status: RepositoryStatus(head: .unborn("main")), defaultBranch: .unresolved).isOnDefaultBranch)
    }

    @Test func goneMeansTheRootIsNoLongerARepository() {
        #expect(snapshot(status: nil, changes: [], health: .failed(.notARepository, attempts: 1)).isGone)
        #expect(!snapshot(health: .failed(.timedOut, attempts: 1)).isGone)
        #expect(!snapshot().isGone)
    }
}
