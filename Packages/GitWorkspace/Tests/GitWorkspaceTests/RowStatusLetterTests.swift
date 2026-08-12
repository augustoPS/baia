import Testing

@testable import GitWorkspace

/// Design v5 §5: a changed-file row spends one fixed column on a single letter,
/// `M`/`A`/`D`, distinct from ``FileChangeMarks``' collapsed tree glyph (which
/// reduces every kind to one of four *urgency* categories). Drawn by the
/// capsule's changes card; the sidebar's CHANGED rows drew it too until the
/// owner's 2026-08-12 ruling removed that section. This is git's own
/// single-letter status, picked the same way ``FileChangeMark`` already picks
/// which of `index`/`worktree` matters more for one glyph: the worktree column
/// outranks the index column for a file that is both, since that is the half
/// still owed.
@Suite struct RowStatusLetterTests {
    private func change(
        _ path: String,
        index: RepositoryFileChange.State? = nil,
        worktree: RepositoryFileChange.State? = nil,
        kind: RepositoryFileChange.Kind = .ordinary
    ) -> RepositoryFileChange {
        RepositoryFileChange(path: RepositoryPath(path), index: index, worktree: worktree, kind: kind)
    }

    @Test func anUnstagedModificationIsModified() {
        #expect(RowStatusLetter(change("a", worktree: .modified)) == .modified)
    }

    @Test func aStagedAdditionIsAdded() {
        #expect(RowStatusLetter(change("a", index: .added)) == .added)
    }

    @Test func aStagedDeletionIsDeleted() {
        #expect(RowStatusLetter(change("a", index: .deleted)) == .deleted)
    }

    @Test func anUnstagedDeletionIsDeleted() {
        #expect(RowStatusLetter(change("a", worktree: .deleted)) == .deleted)
    }

    /// `MM`: committing now leaves the second `M` behind, so the letter has to be
    /// the half that is still owed. Mirrors
    /// ``FileChangeMarksTests/unstagedOutranksStagedForAFileThatIsBoth()``.
    @Test func theWorktreeColumnOutranksTheIndexColumnForAFileThatIsBoth() {
        #expect(RowStatusLetter(change("a", index: .added, worktree: .modified)) == .modified)
    }

    /// An add staged and then deleted from the worktree before commit: the
    /// worktree's `D` is what is still owed, same rule as above.
    @Test func aWorktreeDeletionOutranksAStagedAddition() {
        #expect(RowStatusLetter(change("a", index: .added, worktree: .deleted)) == .deleted)
    }

    @Test func anUntrackedFileIsAdded() {
        // Nothing has been committed yet either way, and `git status --short`
        // itself prints `??`, not `A`, but the row's own vocabulary is "what
        // would this file's presence do to the tree", and a new file not yet
        // known to git is the same answer as a staged add.
        #expect(RowStatusLetter(change("a", kind: .untracked)) == .added)
    }

    @Test func aConflictIsConflict() {
        #expect(RowStatusLetter(change("a", index: .unmerged, worktree: .unmerged, kind: .unmerged)) == .conflict)
    }

    /// A rename or copy reports through its own state letters (`R`/`C`), which
    /// are not part of this row's three-letter vocabulary. Drawn as modified:
    /// the new path exists and the old one is gone, which is what a modification
    /// already means to this column, and a fourth glyph nobody asked for is worse
    /// than folding it into the nearest one that already reads correctly.
    @Test func aRenameFallsBackToModified() {
        #expect(RowStatusLetter(change("a", index: .renamed, kind: .renamedOrCopied)) == .modified)
    }

    @Test func aTypeChangeFallsBackToModified() {
        #expect(RowStatusLetter(change("a", index: .typeChanged)) == .modified)
    }

    /// Neither column carries a state, which ``FileChangeMark`` also treats as
    /// nothing to draw. `RowStatusLetter` cannot return nil the way that type
    /// does without becoming optional at every call site for a case git itself
    /// never emits, so it falls back to modified rather than crashing or
    /// asserting on a state the parser should never produce.
    @Test func neitherColumnSetFallsBackToModified() {
        #expect(RowStatusLetter(change("a")) == .modified)
    }
}
