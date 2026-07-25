import Foundation
import Testing

@testable import GitWorkspace

/// The stanzas here were captured from `git worktree list --porcelain` on git
/// 2.50.1 against a repository with one branch worktree and one detached one.
@Suite struct GitWorktreeParserTests {
    @Test func returnsNothingForEmptyOutput() {
        #expect(GitWorktreeParser.parse("").isEmpty)
    }

    @Test func returnsNothingForOutputWithNoWorktreeLine() {
        // A stanza with no path cannot be opened. Emitting a worktree with an
        // empty URL would put a palette row that opens `/` next to the real ones.
        #expect(GitWorktreeParser.parse("HEAD 5a52ecc\nbranch refs/heads/main\n").isEmpty)
    }

    @Test func readsTheMainWorktreeFirstAndOnlyIt() {
        // `isMain` comes from position and nothing else: git marks the main
        // working tree's stanza no differently from any other. Discovery relies on
        // this to avoid emitting the repository twice.
        let worktrees = GitWorktreeParser.parse("""
        worktree /Users/x/Projects/baia
        HEAD 5a52ecc41fdbe0180f8b91becefde9826db7f360
        branch refs/heads/workspace-shell

        worktree /Users/x/Projects/baia/.worktrees/feature-0725-1200
        HEAD 5a52ecc41fdbe0180f8b91becefde9826db7f360
        branch refs/heads/feature-0725-1200
        """)
        #expect(worktrees.count == 2)
        #expect(worktrees.first?.isMain == true)
        #expect(worktrees.last?.isMain == false)
    }

    @Test func shortensTheBranchRefToItsName() {
        let worktrees = GitWorktreeParser.parse("""
        worktree /Users/x/Projects/baia
        HEAD 5a52ecc41fdbe0180f8b91becefde9826db7f360
        branch refs/heads/workspace-shell
        """)
        #expect(worktrees.first?.branch == "workspace-shell")
        #expect(worktrees.first?.head == "5a52ecc41fdbe0180f8b91becefde9826db7f360")
    }

    @Test func keepsABranchNameThatIsNotUnderRefsHeads() {
        // A stanza whose ref is not a local branch is passed through rather than
        // having eleven characters cut off the front of it, which is what an
        // unconditional `dropFirst` would do.
        let worktrees = GitWorktreeParser.parse("""
        worktree /Users/x/Projects/baia
        branch refs/remotes/origin/main
        """)
        #expect(worktrees.first?.branch == "refs/remotes/origin/main")
    }

    @Test func readsADetachedWorktree() {
        let worktrees = GitWorktreeParser.parse("""
        worktree /Users/x/Projects/baia/.worktrees/spike
        HEAD 5a52ecc41fdbe0180f8b91becefde9826db7f360
        detached
        """)
        #expect(worktrees.first?.isDetached == true)
        #expect(worktrees.first?.branch == nil)
    }

    @Test func readsABareMainRepositoryWithNoHead() {
        // A bare repository's stanza is a path and the word `bare`, with no `HEAD`
        // line at all. Requiring a head would drop it and the palette would show
        // nothing for a repository the owner can still fetch into.
        let worktrees = GitWorktreeParser.parse("""
        worktree /Users/x/mirrors/baia.git
        bare
        """)
        #expect(worktrees.first?.isBare == true)
        #expect(worktrees.first?.head == nil)
    }

    @Test func readsLockedAndPrunableWithNoReason() {
        let worktrees = GitWorktreeParser.parse("""
        worktree /Users/x/Projects/baia/.worktrees/old
        HEAD 5a52ecc
        detached
        locked
        prunable
        """)
        #expect(worktrees.first?.isLocked == true)
        #expect(worktrees.first?.isPrunable == true)
    }

    @Test func readsLockedAndPrunableWithAReasonAfterTheFlag() {
        // git appends a reason to either flag, and an equality test against the
        // bare word reports the worktree as unlocked exactly when there is
        // something to say about why it is locked. Three stale agent worktrees are
        // registered in admin right now, and `prunable` with a reason is how they
        // present.
        let worktrees = GitWorktreeParser.parse("""
        worktree /Users/x/Projects/admin/.claude/worktrees/agent-4f21
        HEAD 5a52ecc
        detached
        locked because the branch is still under review
        prunable gitdir file points to non-existent location
        """)
        #expect(worktrees.first?.isLocked == true)
        #expect(worktrees.first?.isPrunable == true)
    }

    @Test func rendersBothWorktreeLayoutsOnThisMachine() {
        // superpowers writes `.worktrees/<branch>-MMDD-HHMM` and the Agent tool
        // writes `.claude/worktrees/agent-<hex>`. Both are in use, so a display
        // name derived from the branch would collapse the second into
        // `worktree-agent-4f21` and lose the timestamp off the first.
        let worktrees = GitWorktreeParser.parse("""
        worktree /Users/x/Projects/baia
        branch refs/heads/main

        worktree /Users/x/Projects/baia/.worktrees/feature-0725-1200
        branch refs/heads/feature

        worktree /Users/x/Projects/baia/.claude/worktrees/agent-4f21
        branch refs/heads/worktree-agent-4f21
        """)
        #expect(worktrees.map(\.displayName) == ["baia", "feature-0725-1200", "agent-4f21"])
    }

    @Test func keepsAPathThatContainsSpaces() {
        // `git worktree add` accepts one, and cutting the path at the space points
        // a pane at a directory that is not there.
        let worktrees = GitWorktreeParser.parse("worktree /Users/x/my projects/baia\nbranch refs/heads/main")
        #expect(worktrees.first?.displayName == "baia")
        #expect(worktrees.first?.url.path(percentEncoded: false) == "/Users/x/my projects/baia/")
    }

    @Test func startsANewWorktreeWhenTheBlankLineIsLost() {
        // Output that went through a log or an editor can lose the separator, and
        // without the flush on a second `worktree` line the two stanzas collapse
        // into one entry carrying the second path and the first branch.
        let worktrees = GitWorktreeParser.parse("""
        worktree /Users/x/Projects/baia
        branch refs/heads/main
        worktree /Users/x/Projects/baia/.worktrees/spike
        detached
        """)
        #expect(worktrees.count == 2)
        #expect(worktrees.first?.branch == "main")
        #expect(worktrees.last?.isDetached == true)
        #expect(worktrees.last?.branch == nil)
    }

    @Test func toleratesCarriageReturnsAtTheEndsOfLines() {
        // An unstripped return lands inside the path, so the URL points at a
        // directory that cannot exist, and inside the branch name, where it is
        // invisible and compares unequal to everything.
        let worktrees = GitWorktreeParser.parse(
            "worktree /Users/x/Projects/baia\r\nbranch refs/heads/main\r\n"
        )
        #expect(worktrees.first?.branch == "main")
        #expect(worktrees.first?.displayName == "baia")
    }
}
