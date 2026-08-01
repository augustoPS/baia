import Foundation
import Testing

@testable import GitWorkspace

/// The per-file half of `git status --porcelain=v2 -z`.
///
/// Every fixture here was captured from git 2.50.1 on a repository built to
/// produce each record type, not written from the documentation, which is the same
/// standard `GitStatusParserTests` holds itself to. `PorcelainFixture.zeroed`
/// turns the readable listing back into the NUL separated bytes git printed.
///
/// Three of the names are hostile on purpose: a non-ASCII one, one carrying a
/// tab, and one carrying a double quote. Without `-z` git renders all three
/// C-quoted, so the panel drew `"caf\303\251.txt"` and any consumer of these
/// paths was handed a name no filesystem holds.
@Suite struct GitStatusChangesTests {
    /// One repository holding every ordinary shape at once: a file staged and then
    /// edited again, a staged delete, a rename out of a path with a space, a
    /// staged-only change, a worktree-only change, three hostile untracked names
    /// and two ordinary ones, one of them nested.
    private let everyShape = PorcelainFixture.zeroed("""
    # branch.oid 362d6fae33462c0809e46d9d4514979cb13fe847
    # branch.head main
    1 MM N... 100644 100644 100644 49f33a8c6e8bb31f5d7c68f9c298cac55ec7cd85 61780798228d17af2d34fce4cfbdf35556832472 both.txt
    1 D. N... 100644 000000 000000 286c5f5776916d7d7d5849988ca9d83e722cf9c2 0000000000000000000000000000000000000000 gone.txt
    2 R. N... 100644 100644 100644 5dc887d0128750b3996ab29578a483e4139b8eaa 5dc887d0128750b3996ab29578a483e4139b8eaa R100 new name.txt
    old name.txt
    1 M. N... 100644 100644 100644 19d9cc8584ac2c7dcf57d2680375e80f099dc481 61780798228d17af2d34fce4cfbdf35556832472 staged.txt
    1 .M N... 100644 100644 100644 b8d041e39da713592693a6e2d6af4a02a9c7a265 b8d041e39da713592693a6e2d6af4a02a9c7a265 unstaged.txt
    ? café.txt
    ? ctrl\tname.txt
    ? quo"te.txt
    ? sub/nested.txt
    ? untracked.txt

    """)

    private let conflicted = PorcelainFixture.zeroed("""
    # branch.oid 572d474a01c1fba4cbc3bc4e84a005527ed0322e
    # branch.head main
    u UU N... 100644 100644 100644 100644 df967b96a579e45a18b8251732d16804b2e56a55 b19a1e93bec1317dc6097229e12afaffbfa74dc2 950b81b7eee953d050aa05a641f8e056c85dd1bd conflicted.txt

    """)

    /// A header and nothing else, so a record built from bytes can be appended to
    /// it. `? café.txt` above is the same name spelled in UTF-8, which a fixture can
    /// hold; this one is the Latin-1 spelling, which no `String` can.
    private let headerOnly = PorcelainFixture.zeroed("""
    # branch.oid 362d6fae33462c0809e46d9d4514979cb13fe847
    # branch.head main

    """)

    /// `café.txt` as a filesystem that is not APFS may hold it: eight bytes, the
    /// fourth of which is not a UTF-8 sequence.
    private let latin1 = PorcelainFixture.bytes("caf") + [0xE9] + PorcelainFixture.bytes(".txt")

    @Test func emptyOutputHasNoChanges() {
        #expect(GitStatusParser.changes([]).isEmpty)
    }

    /// The path the picker would have to send, for a name with no text spelling.
    /// `rawPath` is what the file is called and `path` is what the row draws, and
    /// the second cannot name the file: every byte that is not UTF-8 draws as the
    /// same replacement character. The picker still sends the second one.
    @Test func aPathThatIsNotUTF8KeepsItsBytes() {
        let output = headerOnly + PorcelainFixture.bytes("? ") + latin1 + [0]

        let changes = GitStatusParser.changes(output)

        #expect(changes.map(\.rawPath) == [RepositoryPath(latin1)])
        #expect(changes.map(\.path) == ["caf\u{FFFD}.txt"])
    }

    /// The same for the entry a rename carries, which is a whole path of its own
    /// under `-z` rather than a field after a tab. A rename *out of* a name the
    /// filesystem holds and Swift cannot spell is exactly the case a caller needs
    /// the bytes for: it is the path `git checkout --` would be given.
    @Test func aRenameOutOfAPathThatIsNotUTF8KeepsItsBytes() {
        let record = "2 R. N... 100644 100644 100644 4156d35 4156d35 R100 renamed.txt"
        let output = headerOnly + PorcelainFixture.bytes(record) + [0] + latin1 + [0]

        let changes = GitStatusParser.changes(output)

        #expect(changes.map(\.rawPath) == ["renamed.txt"])
        #expect(changes.map(\.rawOriginalPath) == [RepositoryPath(latin1)])
        #expect(changes.map(\.originalPath) == ["caf\u{FFFD}.txt"])
    }

    /// A clean repository is not the same as no repository here, unlike
    /// ``GitStatusParser/parse(_:)``, which answers nil for both. An empty list is
    /// the honest answer for a repository with nothing to show, and the caller
    /// already learned whether it is a repository at all from the status.
    @Test func aCleanRepositoryHasNoChanges() {
        let output = PorcelainFixture.zeroed("""
        # branch.oid 0d897c553a72e6eb993a44dcd926806831909bda
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +0 -0

        """)
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
            "café.txt",
            "ctrl\tname.txt",
            "quo\"te.txt",
            "sub/nested.txt",
            "untracked.txt",
        ])
    }

    /// The reason `-z` is passed at all. Without it git C-quotes any path holding
    /// a non-ASCII byte, a double quote, a backslash or a control byte, and the
    /// panel drew that rendering verbatim: `café.txt` reached the surface as the
    /// fifteen ASCII characters `"caf\303\251.txt"`.
    @Test func aHostileNameArrivesAsItsOwnBytes() {
        let paths = GitStatusParser.changes(everyShape).map(\.path)
        #expect(paths.contains("café.txt"))
        #expect(paths.contains("ctrl\tname.txt"))
        #expect(paths.contains("quo\"te.txt"))
        #expect(paths.contains { $0.contains("\\303") } == false)
    }

    /// A newline is legal in a filename on macOS, and under `-z` it arrives inside
    /// the record. A parser still splitting records on newlines reads this as an
    /// untracked file called `two` followed by a junk line, so the surface shows a
    /// path that does not exist and drops the one that does.
    @Test func aNewlineInsideAPathStaysInsideThePath() {
        // Written out rather than through `PorcelainFixture.zeroed`, because this
        // is the one fixture whose path contains the character that helper treats
        // as a line break.
        let output = PorcelainFixture.bytes("# branch.oid 4fd88ea\0# branch.head main\0? two\nlines.txt\0")
        let changes = GitStatusParser.changes(output)
        #expect(changes.map(\.path) == ["two\nlines.txt"])
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

    /// The record this grammar is easiest to get wrong on. Under `-z` the original
    /// path is not a trailing field after a tab but a NUL terminated entry of its
    /// own, so a parser reading entries one at a time sees it as a record.
    @Test func aRenameKeepsBothPathsAcrossTheSeparator() {
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

    /// A rename out of a path that is itself shaped like a record. Captured from
    /// git after `git mv '? evil.txt' renamed.txt`: the entry following the rename
    /// is the literal text `? evil.txt`, so a parser that reads every entry as a
    /// record invents an untracked file called `evil.txt` that nothing on disk
    /// matches. The original path has to be consumed by the record that owns it.
    @Test func anOriginalPathShapedLikeARecordIsNotReadAsOne() {
        let output = PorcelainFixture.zeroed("""
        # branch.oid 4fd88ea353187db47cc2b5f78f216385e7b484f3
        # branch.head main
        2 R. N... 100644 100644 100644 4156d35e8856e08f2f46f1950821b1e55bd4792c 4156d35e8856e08f2f46f1950821b1e55bd4792c R100 renamed.txt
        ? evil.txt

        """)
        let changes = GitStatusParser.changes(output)
        #expect(changes.map(\.path) == ["renamed.txt"])
        #expect(changes.first?.originalPath == "? evil.txt")
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
        let output = everyShape + PorcelainFixture.bytes("! build/artifact.o\0")
        #expect(GitStatusParser.changes(output).contains { $0.path == "build/artifact.o" } == false)
    }

    @Test func aMalformedRecordIsSkippedRatherThanGuessedAt() {
        let output = PorcelainFixture.zeroed("""
        # branch.oid abc
        # branch.head main
        1 MM N... 100644
        ? kept.txt

        """)
        #expect(GitStatusParser.changes(output).map(\.path) == ["kept.txt"])
    }

    /// A rename record truncated before its original path keeps the path it does
    /// have. The alternative is dropping a file the owner can see, to report a
    /// field that only a capture cut in half is missing.
    @Test func aRenameMissingItsOriginalPathKeepsTheNewOne() {
        let output = PorcelainFixture.zeroed("""
        # branch.oid abc
        # branch.head main
        2 R. N... 100644 100644 100644 4156d35 4156d35 R100 renamed.txt
        """)
        let changes = GitStatusParser.changes(output)
        #expect(changes.map(\.path) == ["renamed.txt"])
        #expect(changes.first?.originalPath == nil)
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
