import Testing

@testable import GitWorkspace

@Suite struct RepositoryFileChangeOrderTests {
    private func change(
        _ path: String,
        index: RepositoryFileChange.State? = nil,
        worktree: RepositoryFileChange.State? = nil,
        kind: RepositoryFileChange.Kind = .ordinary
    ) -> RepositoryFileChange {
        RepositoryFileChange(
            path: RepositoryPath(path),
            index: index,
            worktree: worktree,
            kind: kind
        )
    }

    private var conflict: RepositoryFileChange {
        change("z-conflict", index: .unmerged, worktree: .unmerged, kind: .unmerged)
    }

    private var staged: RepositoryFileChange { change("y-staged", index: .modified) }
    private var unstaged: RepositoryFileChange { change("x-unstaged", worktree: .modified) }
    private var untracked: RepositoryFileChange { change("a-untracked", kind: .untracked) }

    /// The whole policy in one assertion, and every path deliberately sorts
    /// against the band it is in: the conflict's path is last alphabetically and
    /// the untracked file's is first, so an implementation that fell back to
    /// git's own path order would produce exactly the reverse of this.
    @Test func theFourBandsComeInCommitOrderRegardlessOfPath() {
        let ordered = [untracked, unstaged, staged, conflict].inCommitOrder()
        #expect(ordered.map(\.path) == ["z-conflict", "y-staged", "x-unstaged", "a-untracked"])
    }

    /// Each neighbouring pair on its own. Without these a single reordering of
    /// two adjacent bands still passes any test that only checks the extremes.
    @Test func aConflictComesBeforeAStagedChange() {
        #expect([staged, conflict].inCommitOrder().map(\.path) == ["z-conflict", "y-staged"])
    }

    @Test func aStagedChangeComesBeforeAnUnstagedOne() {
        #expect([unstaged, staged].inCommitOrder().map(\.path) == ["y-staged", "x-unstaged"])
    }

    @Test func anUnstagedChangeComesBeforeAnUntrackedFile() {
        #expect([untracked, unstaged].inCommitOrder().map(\.path) == ["x-unstaged", "a-untracked"])
    }

    /// A file staged and then modified again is staged. Part of it is going into
    /// the commit, which is the question this order answers; the row's own
    /// two-column marker says the rest is not.
    @Test func aFileStagedAndModifiedSinceRanksAsStaged() {
        let both = change("m-both", index: .modified, worktree: .modified)
        #expect([unstaged, both].inCommitOrder().map(\.path) == ["m-both", "x-unstaged"])
        #expect(both.commitRank == staged.commitRank)
    }

    /// A rename ranks by whether it is staged, like any other change, rather than
    /// getting a band of its own. `.renamedOrCopied` is a separate `Kind` and an
    /// implementation switching on kind alone would drop it into the wrong band.
    @Test func aRenameRanksByWhetherItIsStaged() {
        let stagedRename = change("r-staged", index: .renamed, kind: .renamedOrCopied)
        let unstagedRename = change("r-unstaged", worktree: .renamed, kind: .renamedOrCopied)
        #expect(stagedRename.commitRank == staged.commitRank)
        #expect(unstagedRename.commitRank == unstaged.commitRank)
    }

    /// Within one band the order is by path. Asserted inside a band rather than
    /// across the list, because a comparison that ignored the tie-break entirely
    /// would still pass every band test above.
    @Test func pathBreaksTiesWithinOneBand() {
        let ordered = [change("c"), change("a"), change("b")].inCommitOrder()
        #expect(ordered.map(\.path) == ["a", "b", "c"])
    }

    /// The tie-break applies in every band, not only the first. An implementation
    /// sorting by path once and then partitioning by rank would pass the band
    /// tests and fail this.
    @Test func pathBreaksTiesInsideTheUntrackedBandToo() {
        let ordered = [
            change("z", kind: .untracked),
            change("a", kind: .untracked),
            staged,
        ].inCommitOrder()
        #expect(ordered.map(\.path) == ["y-staged", "a", "z"])
    }

    @Test func anEmptyListStaysEmpty() {
        #expect([RepositoryFileChange]().inCommitOrder().isEmpty)
    }
}
