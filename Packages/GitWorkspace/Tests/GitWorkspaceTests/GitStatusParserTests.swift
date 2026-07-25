import Foundation
import Testing

@testable import GitWorkspace

/// Every fixture string here was captured from `git status --porcelain=v2` on git
/// 2.50.1, not written from the documentation. The rename record in particular has
/// a real tab in it, which is the field the grammar is easiest to get wrong on.
@Suite struct GitStatusParserTests {
    @Test func returnsNilForEmptyOutput() {
        #expect(GitStatusParser.parse("") == nil)
    }

    @Test func returnsNilWhenThereIsNoBranchHeader() {
        // `git status` outside a work tree writes nothing to stdout, and a caller
        // must be able to tell that from a clean repository. A zeroed status would
        // render an empty branch name with no indicators, which looks like a clean
        // repository rather than like no repository.
        #expect(GitStatusParser.parse("? notes.txt\n") == nil)
    }

    @Test func returnsNilWhenTheHeadHeaderIsMissing() {
        // The oid alone cannot say whether the head is a branch or detached, and
        // guessing would name every truncated capture detached.
        #expect(GitStatusParser.parse("# branch.oid ed1d41d\n") == nil)
    }

    @Test func readsACleanBranchWithNoUpstream() {
        let status = GitStatusParser.parse("""
        # branch.oid ed1d41d21c1540a4b34d59e9a720d4f4383ed3cd
        # branch.head main
        """)
        #expect(status == RepositoryStatus(head: .branch("main")))
    }

    @Test func readsTheUpstreamAndTheDivergence() {
        let status = GitStatusParser.parse("""
        # branch.oid 5a52ecc41fdbe0180f8b91becefde9826db7f360
        # branch.head other
        # branch.upstream origin/main
        # branch.ab +1 -1
        """)
        #expect(status == RepositoryStatus(
            head: .branch("other"),
            upstream: "origin/main",
            ahead: 1,
            behind: 1
        ))
    }

    @Test func hasNoUpstreamAndNoDivergenceWhenTheHeaderIsAbsent() {
        // The absent upstream must not become a fabricated zero one. A pane on a
        // local-only branch has nothing to push to, and `↑0` beside it invites the
        // owner to look for a remote that is not configured.
        let status = GitStatusParser.parse("""
        # branch.oid ed1d41d21c1540a4b34d59e9a720d4f4383ed3cd
        # branch.head local-only
        """)
        #expect(status?.upstream == nil)
        #expect(status?.ahead == 0)
        #expect(status?.behind == 0)
    }

    @Test func discardsADivergenceReportedWithoutAnUpstream() {
        // Would pass with the forced reset deleted only if `branch.ab` never
        // appeared alone, and this fixture is exactly that case: a truncated
        // capture or a hand-built pipe that dropped the upstream line.
        let status = GitStatusParser.parse("""
        # branch.oid ed1d41d21c1540a4b34d59e9a720d4f4383ed3cd
        # branch.head main
        # branch.ab +3 -4
        """)
        #expect(status?.ahead == 0)
        #expect(status?.behind == 0)
    }

    @Test func readsAheadAndBehindWhateverOrderTheSignsArriveIn() {
        // Read by sign rather than by position. The two counts look identical on a
        // synced branch, so a swap between them is invisible until the owner is
        // about to push and the bar tells him to pull.
        let status = GitStatusParser.parse("""
        # branch.oid ed1d41d
        # branch.head main
        # branch.upstream origin/main
        # branch.ab -7 +2
        """)
        #expect(status?.ahead == 2)
        #expect(status?.behind == 7)
    }

    @Test func reportsAnUnbornHeadAsUnbornRatherThanDetached() {
        // Real output of `git status` in a repository straight out of `git init`.
        // The oid is the literal `(initial)`, which any code reading it as a
        // commit would then render as a detached head.
        let status = GitStatusParser.parse("""
        # branch.oid (initial)
        # branch.head main
        """)
        #expect(status?.head == .unborn("main"))
    }

    @Test func reportsADetachedHeadWithItsCommit() {
        let status = GitStatusParser.parse("""
        # branch.oid ed1d41d21c1540a4b34d59e9a720d4f4383ed3cd
        # branch.head (detached)
        """)
        #expect(status?.head == .detached(commit: "ed1d41d21c1540a4b34d59e9a720d4f4383ed3cd"))
    }

    @Test func toleratesAHeaderItDoesNotKnow() {
        // `# stash 2` arrives with `--show-stash`, and git adds headers over time.
        // Treating an unknown one as a parse failure would blank the status bar on
        // a git upgrade.
        let status = GitStatusParser.parse("""
        # branch.oid ed1d41d
        # branch.head main
        # stash 2
        """)
        #expect(status?.head == .branch("main"))
    }

    @Test func countsAFileThatIsBothStagedAndUnstagedInBothColumns() {
        // `MM` is a file staged and then edited again, which is the most common
        // state a pane is in when the owner is about to commit. Counting each
        // record once is the obvious implementation and it reports one change
        // where there are two.
        let status = GitStatusParser.parse("""
        # branch.oid ed1d41d
        # branch.head main
        1 MM N... 100644 100644 100644 78981922613b2afb6025042ff6bd878ac1994e85 78981922613b2afb6025042ff6bd878ac1994e85 c.txt
        """)
        #expect(status?.staged == 1)
        #expect(status?.unstaged == 1)
    }

    @Test func countsAStagedOnlyChangeInTheIndexColumnOnly() {
        // The mirror of the both-columns test. Either one alone passes whichever
        // way the column reading goes; the pair is what pins that `.` means
        // unmodified in that column and nothing else.
        let status = GitStatusParser.parse("""
        # branch.oid ed1d41d
        # branch.head main
        1 M. N... 100644 100644 100644 7898192 7898192 c.txt
        1 .M N... 100644 100644 100644 7898192 7898192 d.txt
        """)
        #expect(status?.staged == 1)
        #expect(status?.unstaged == 1)
    }

    @Test func keepsCountingAPathThatContainsSpaces() {
        // The bounded split is what this pins. An unbounded one turns
        // `untracked with space.txt` into three extra fields, the record fails its
        // field count, and a file the owner can see in Finder never reaches the
        // count.
        let status = GitStatusParser.parse("""
        # branch.oid ed1d41d
        # branch.head main
        1 .M N... 100644 100644 100644 7898192 7898192 old name.txt
        ? untracked with space.txt
        """)
        #expect(status?.unstaged == 1)
        #expect(status?.untracked == 1)
    }

    @Test func countsARenameWhoseOriginalPathFollowsATab() {
        // Captured verbatim from `git mv` followed by an edit: ten space separated
        // fields where the tenth is `<path>TAB<origPath>`. Splitting on whitespace
        // rather than on a literal space yields eleven, the record is rejected as
        // malformed, and every rename silently stops counting.
        let status = GitStatusParser.parse("""
        # branch.oid ed1d41d21c1540a4b34d59e9a720d4f4383ed3cd
        # branch.head main
        2 RM N... 100644 100644 100644 78981922613b2afb6025042ff6bd878ac1994e85 78981922613b2afb6025042ff6bd878ac1994e85 R100 new name.txt\told name.txt
        """)
        #expect(status?.staged == 1)
        #expect(status?.unstaged == 1)
    }

    @Test func countsUnmergedFilesAsConflictedAndNothingElse() {
        // Captured from a real merge conflict. `UU` in the two columns would read
        // as staged and unstaged to the ordinary-change path, so a single
        // conflicted file would report three separate problems.
        let status = GitStatusParser.parse("""
        # branch.oid 1779e805306dfb37077b1ff6fda76b1164cec42b
        # branch.head main
        u UU N... 100644 100644 100644 100644 df967b96a579e45a18b8251732d16804b2e56a55 ba2906d0666cf726c7eaadd2cd3db615dedfdf3a e45c9c2666d44e0327c1f9c239a74c508336053e c.txt
        """)
        #expect(status?.conflicted == 1)
        #expect(status?.staged == 0)
        #expect(status?.unstaged == 0)
    }

    @Test func countsIgnoredFilesAsNothingAtAll() {
        // `!` records only appear with `--ignored`, which the composed command
        // does not pass, but a caller is free to. Counting one as untracked puts a
        // permanent `?` on every repository with a build directory.
        let status = GitStatusParser.parse("""
        # branch.oid ed1d41d
        # branch.head main
        ! ig.log
        ? real.txt
        """)
        #expect(status?.untracked == 1)
    }

    @Test func ignoresAMalformedRecordRatherThanCountingIt() {
        // A record short of its fields is not counted from whatever happened to
        // line up. Both of these look like a change to a lenient parser.
        let status = GitStatusParser.parse("""
        # branch.oid ed1d41d
        # branch.head main
        1 MM
        2 RM N... 100644 100644 100644 7898192 7898192 R100
        """)
        #expect(status?.staged == 0)
        #expect(status?.unstaged == 0)
    }

    @Test func neverReportsAnInProgressOperation() {
        // Porcelain v2 says nothing about a half-finished rebase, so anything the
        // parser put here would be invented. `InProgressProbe` is the only source,
        // and `GitCommand.status(ofRepositoryRoot:)` is what joins them.
        let status = GitStatusParser.parse("""
        # branch.oid ed1d41d
        # branch.head main
        u UU N... 100644 100644 100644 100644 df967b9 ba2906d e45c9c2 c.txt
        """)
        #expect(status?.inProgress == nil)
    }

    @Test func toleratesCarriageReturnsAtTheEndsOfLines() {
        // Output that has been through a text editor or a Windows pipe carries
        // CRLF, and an unstripped return rides along inside the branch name, where
        // it renders as nothing and compares unequal to everything.
        let status = GitStatusParser.parse("# branch.oid ed1d41d\r\n# branch.head main\r\n? a.txt\r\n")
        #expect(status?.head == .branch("main"))
        #expect(status?.untracked == 1)
    }
}
