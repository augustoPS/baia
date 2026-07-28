import Foundation
import Testing

@testable import GitWorkspace

/// The per-file half of `git status --porcelain=v2`.
///
/// Every fixture here was captured from git 2.50.1 on a repository built to
/// produce each record type, not written from the documentation, which is the same
/// standard `GitStatusParserTests` holds itself to. The rename record carries a
/// real tab and a real space in the original path, because those are the two
/// characters this grammar is easiest to get wrong on.
@Suite struct GitStatusChangesTests {
    /// One repository holding every ordinary shape at once: a file staged and then
    /// edited again, a staged delete, a rename out of a path with a space, a
    /// staged-only change, a worktree-only change, and two untracked files one of
    /// which is nested.
    private let everyShape = """
    # branch.oid 0d897c553a72e6eb993a44dcd926806831909bda
    # branch.head main
    1 MM N... 100644 100644 100644 61780798228d17af2d34fce4cfbdf35556832472 5ae8f0041f029cd7686c98cc966d98385c25050e both.txt
    1 D. N... 100644 000000 000000 d905d9da82c97264ab6f4920e20242e088850ce9 0000000000000000000000000000000000000000 gone.txt
    2 R. N... 100644 100644 100644 4bcfe98e640c8284511312660fb8709b0afa888e 4bcfe98e640c8284511312660fb8709b0afa888e R100 new name.txt\told name.txt
    1 M. N... 100644 100644 100644 78981922613b2afb6025042ff6bd878ac1994e85 aa00f2f88ff89db044b6fc48a329fcbf59632cf5 staged.txt
    1 .M N... 100644 100644 100644 f2ad6c76f0115a6ba5b00456a849810e7ec0af20 f2ad6c76f0115a6ba5b00456a849810e7ec0af20 unstaged.txt
    ? sub/nested.txt
    ? untracked.txt

    """

    private let conflicted = """
    # branch.oid 572d474a01c1fba4cbc3bc4e84a005527ed0322e
    # branch.head main
    u UU N... 100644 100644 100644 100644 df967b96a579e45a18b8251732d16804b2e56a55 b19a1e93bec1317dc6097229e12afaffbfa74dc2 950b81b7eee953d050aa05a641f8e056c85dd1bd conflicted.txt

    """

    @Test func emptyOutputHasNoChanges() {
        #expect(GitStatusParser.changes("").isEmpty)
    }

    /// A clean repository is not the same as no repository here, unlike
    /// ``GitStatusParser/parse(_:)``, which answers nil for both. An empty list is
    /// the honest answer for a repository with nothing to show, and the caller
    /// already learned whether it is a repository at all from the status.
    @Test func aCleanRepositoryHasNoChanges() {
        let output = """
        # branch.oid 0d897c553a72e6eb993a44dcd926806831909bda
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +0 -0

        """
        #expect(GitStatusParser.changes(output).isEmpty)
    }

    @Test func everyRecordIsReadAndGitsOrderIsKept() {
        let changes = GitStatusParser.changes(everyShape)
        #expect(changes.map(\.path) == [
            "both.txt",
            "gone.txt",
            "new name.txt",
            "staged.txt",
            "unstaged.txt",
            "sub/nested.txt",
            "untracked.txt",
        ])
    }

    /// `MM` is one file in two states: staged, then edited again. The panel has to
    /// show both, which is the whole reason the two columns are separate fields
    /// rather than one summary.
    @Test func bothColumnsAreKeptForAFileStagedAndThenEditedAgain() {
        let change = GitStatusParser.changes(everyShape).first { $0.path == "both.txt" }
        #expect(change?.index == .modified)
        #expect(change?.worktree == .modified)
        #expect(change?.kind == .ordinary)
    }

    @Test func anUnmodifiedColumnIsNilRatherThanADot() {
        let changes = GitStatusParser.changes(everyShape)
        let staged = changes.first { $0.path == "staged.txt" }
        #expect(staged?.index == .modified)
        #expect(staged?.worktree == nil)

        let unstaged = changes.first { $0.path == "unstaged.txt" }
        #expect(unstaged?.index == nil)
        #expect(unstaged?.worktree == .modified)
    }

    @Test func aStagedDeleteIsReadAsDeleted() {
        let change = GitStatusParser.changes(everyShape).first { $0.path == "gone.txt" }
        #expect(change?.index == .deleted)
        #expect(change?.worktree == nil)
    }

    /// The record this grammar is easiest to get wrong on: the two paths are
    /// separated by a tab, and the original path contains a space. Splitting the
    /// record on whitespace, or forgetting the tab, loses the rename entirely.
    @Test func aRenameKeepsBothPathsAcrossTheTab() {
        let change = GitStatusParser.changes(everyShape).first { $0.path == "new name.txt" }
        #expect(change?.originalPath == "old name.txt")
        #expect(change?.kind == .renamedOrCopied)
        #expect(change?.index == .renamed)
        #expect(change?.worktree == nil)
    }

    @Test func onlyARenameCarriesAnOriginalPath() {
        let changes = GitStatusParser.changes(everyShape)
        #expect(changes.filter { $0.originalPath != nil }.map(\.path) == ["new name.txt"])
    }

    @Test func anUntrackedFileHasNoStateInEitherColumn() {
        let changes = GitStatusParser.changes(everyShape)
        for path in ["sub/nested.txt", "untracked.txt"] {
            let change = changes.first { $0.path == path }
            #expect(change?.kind == .untracked)
            #expect(change?.index == nil)
            #expect(change?.worktree == nil)
        }
    }

    /// Unmerged paths are their own kind rather than a file that is both staged and
    /// unstaged, for the reason ``GitStatusParser/parse(_:)`` counts them
    /// separately: reading `UU` as two ordinary columns claims two problems where
    /// there is one.
    @Test func anUnmergedPathIsItsOwnKind() {
        let changes = GitStatusParser.changes(conflicted)
        #expect(changes.count == 1)
        #expect(changes[0].path == "conflicted.txt")
        #expect(changes[0].kind == .unmerged)
        #expect(changes[0].index == .unmerged)
        #expect(changes[0].worktree == .unmerged)
    }

    /// An ignored path appears only under `--ignored`, which the shipped command
    /// does not pass, and it must not arrive as untracked if it ever does.
    @Test func anIgnoredRecordIsNotAChange() {
        let output = everyShape + "! build/artifact.o\n"
        #expect(GitStatusParser.changes(output).contains { $0.path == "build/artifact.o" } == false)
    }

    @Test func aMalformedRecordIsSkippedRatherThanGuessedAt() {
        let output = """
        # branch.oid abc
        # branch.head main
        1 MM N... 100644
        ? kept.txt

        """
        #expect(GitStatusParser.changes(output).map(\.path) == ["kept.txt"])
    }

    /// CRLF for the same reason the status parse splits on `isNewline`: a CRLF pair
    /// is one `Character`, so splitting on "\\n" would return the whole capture as a
    /// single line and find nothing at all.
    @Test func crlfOutputIsSplitCorrectly() {
        let output = everyShape.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(GitStatusParser.changes(output).count == 7)
    }

    /// The two parses read the same bytes and must not disagree. This is the test
    /// that would catch one of them being taught about a record type the other
    /// never learned.
    @Test func theChangesAgreeWithTheCountsTheStatusReports() {
        let status = GitStatusParser.parse(everyShape)
        let changes = GitStatusParser.changes(everyShape)
        #expect(status?.staged == changes.filter { $0.kind != .untracked && $0.index != nil }.count)
        #expect(status?.unstaged == changes.filter { $0.kind != .untracked && $0.worktree != nil }.count)
        #expect(status?.untracked == changes.filter { $0.kind == .untracked }.count)
        #expect(status?.conflicted == changes.filter { $0.kind == .unmerged }.count)
    }

    @Test func theCountsAndTheChangesAgreeOnAConflictToo() {
        let status = GitStatusParser.parse(conflicted)
        let changes = GitStatusParser.changes(conflicted)
        #expect(status?.conflicted == 1)
        #expect(changes.filter { $0.kind == .unmerged }.count == 1)
    }
}
