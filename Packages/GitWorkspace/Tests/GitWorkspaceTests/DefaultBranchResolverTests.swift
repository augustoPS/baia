import Foundation
import Testing

@testable import GitWorkspace

/// Real repositories, because the question is what git actually writes into
/// `refs/remotes/*/HEAD` and when. A fixture string can pin the grammar, which
/// ``DefaultBranchParserTests`` does; only a real repository can pin that a clone
/// sets the ref, that `git init` does not, and that a linked worktree sees the
/// same one as its parent.
///
/// The `run` and `repository` helpers repeat ``GitCommandTests``' own, and for the
/// same reasons: the owner's global config is inherited through the environment,
/// so identity, signing and `init.defaultBranch` have to be passed per invocation
/// or these tests answer differently on his machine than on a fresh one.
@Suite final class DefaultBranchResolverTests {
    let fixture: DirectoryFixture
    let git = GitCommand()

    init() throws {
        fixture = try DirectoryFixture()
    }

    @discardableResult
    private func run(_ arguments: [String], in path: String = "") -> String? {
        git.output(
            of: [
                "-c", "user.name=baia",
                "-c", "user.email=baia@example.invalid",
                "-c", "commit.gpgsign=false",
            ] + arguments,
            in: path.isEmpty ? fixture.root : fixture.root.appending(path: path)
        )
    }

    /// A repository at `path` with one commit, checked out on `branch`.
    @discardableResult
    private func repository(_ path: String, branch: String = "main") throws -> URL {
        let root = try fixture.directory(path)
        run(["-c", "init.defaultBranch=\(branch)", "init", "--quiet"], in: path)
        try fixture.file("\(path)/c.txt", contents: "base\n")
        run(["add", "-A"], in: path)
        run(["commit", "--quiet", "--no-verify", "-m", "base"], in: path)
        return root
    }

    /// Writes the remote-tracking branch and the HEAD pointer a clone would have
    /// written, without paying for a clone.
    private func setRemoteHead(in path: String, remote: String = "origin", branch: String) {
        run(["update-ref", "refs/remotes/\(remote)/\(branch)", "HEAD"], in: path)
        run(
            ["symbolic-ref", "refs/remotes/\(remote)/HEAD", "refs/remotes/\(remote)/\(branch)"],
            in: path
        )
    }

    @Test func hidesTheBranchOnARepositoryWhoseDefaultIsDevelop() throws {
        // The first half of the bug: a repository whose default is `develop` used
        // to show `:develop` in its tab permanently, on the branch the owner never
        // leaves.
        let root = try repository("proj", branch: "develop")
        setRemoteHead(in: "proj", branch: "develop")
        let resolver = DefaultBranchResolver()

        #expect(resolver.defaultBranch(ofRepositoryRoot: root) == "develop")
        #expect(resolver.isDefaultBranch(.branch("develop"), ofRepositoryRoot: root))
        #expect(!resolver.isDefaultBranch(.branch("feature/x"), ofRepositoryRoot: root))
    }

    @Test func showsMasterInARepositoryWhoseDefaultIsMain() throws {
        // The other half, which the name test got backwards: a branch called
        // `master` in a repository defaulting to `main` is somewhere unusual, and
        // the tab said nothing at all.
        let root = try repository("proj", branch: "main")
        setRemoteHead(in: "proj", branch: "main")
        let resolver = DefaultBranchResolver()

        #expect(resolver.isDefaultBranch(.branch("main"), ofRepositoryRoot: root))
        #expect(!resolver.isDefaultBranch(.branch("master"), ofRepositoryRoot: root))
    }

    @Test func readsTheDefaultARealCloneWroteDown() throws {
        // A clone rather than a hand-written ref, so the format, the location and
        // the fact that cloning sets it at all are git's answer and not this
        // suite's assumption.
        try repository("origin-repo", branch: "develop")
        run(["clone", "--quiet", fixture.root.appending(path: "origin-repo").path(percentEncoded: false), "clone"])
        let clone = fixture.root.appending(path: "clone")

        #expect(DefaultBranchResolver().defaultBranch(ofRepositoryRoot: clone) == "develop")
    }

    @Test func fallsBackToTheNameTestInARepositoryWithNoRemote() throws {
        // `git init` writes no `refs/remotes` at all, and the owner's vault is
        // deliberately local-only. There is no real answer here, so the name test
        // is the honest fallback: `main` is hidden, anything else is shown. The
        // failure this pins is the pair of tempting wrong answers, hiding every
        // branch or showing every branch.
        let root = try repository("vault", branch: "main")
        let resolver = DefaultBranchResolver()

        #expect(resolver.defaultBranch(ofRepositoryRoot: root) == nil)
        #expect(resolver.isDefaultBranch(.branch("main"), ofRepositoryRoot: root))
        #expect(resolver.isDefaultBranch(.branch("master"), ofRepositoryRoot: root))
        #expect(!resolver.isDefaultBranch(.branch("develop"), ofRepositoryRoot: root))
    }

    @Test func fallsBackWhenARemoteWasAddedButNeverFetched() throws {
        // `git remote add` writes a config entry and no refs. The repository has a
        // remote and still no answer, which is why the fallback is keyed on the ref
        // being there rather than on the remote being configured.
        let root = try repository("proj", branch: "main")
        run(["remote", "add", "origin", "https://example.invalid/proj.git"], in: "proj")

        #expect(DefaultBranchResolver().defaultBranch(ofRepositoryRoot: root) == nil)
    }

    @Test func degradesWhenOriginsHeadPointsAtABranchThatIsGone() throws {
        // A stale pointer, left by a remote that renamed or deleted its default.
        // `for-each-ref` omits a symref whose target is missing, so this degrades to
        // the name test rather than comparing every branch against one that does
        // not exist, and rather than trapping on a half-resolved ref.
        let root = try repository("proj", branch: "main")
        run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/gone"], in: "proj")
        let resolver = DefaultBranchResolver()

        #expect(resolver.defaultBranch(ofRepositoryRoot: root) == nil)
        #expect(resolver.isDefaultBranch(.branch("main"), ofRepositoryRoot: root))
        #expect(!resolver.isDefaultBranch(.branch("gone"), ofRepositoryRoot: root))
    }

    @Test func answersNothingForADirectoryThatIsNotARepository() throws {
        // git exits 128 and ``GitCommand`` reads that as nil. The resolver must
        // hand that through as "no answer" rather than as an empty branch name.
        let plain = try fixture.directory("notes")
        let resolver = DefaultBranchResolver()

        #expect(resolver.defaultBranch(ofRepositoryRoot: plain) == nil)
        #expect(resolver.isDefaultBranch(.branch("main"), ofRepositoryRoot: plain))
    }

    @Test func readsARemoteThatIsNotCalledOrigin() throws {
        // Supported rather than refused: `git clone --origin` and `git remote
        // rename` are both in reach, and the answer is unambiguous with one remote.
        let root = try repository("proj", branch: "main")
        setRemoteHead(in: "proj", remote: "upstream", branch: "trunk")

        #expect(DefaultBranchResolver().defaultBranch(ofRepositoryRoot: root) == "trunk")
    }

    @Test func prefersOriginInARepositoryWithTwoRemotes() throws {
        let root = try repository("proj", branch: "main")
        setRemoteHead(in: "proj", remote: "upstream", branch: "trunk")
        setRemoteHead(in: "proj", remote: "origin", branch: "main")

        #expect(DefaultBranchResolver().defaultBranch(ofRepositoryRoot: root) == "main")
    }

    @Test func readsTheSameDefaultInsideALinkedWorktree() throws {
        // `refs/remotes` lives in the common git directory, so a worktree shares its
        // parent's answer. Pinned because the alternative would be a worktree whose
        // tab disagrees with the tab of the repository it belongs to.
        let root = try repository("proj", branch: "develop")
        setRemoteHead(in: "proj", branch: "develop")
        run(["worktree", "add", "--quiet", ".worktrees/spike", "-b", "spike"], in: "proj")
        let tree = root.appending(path: ".worktrees/spike")
        let resolver = DefaultBranchResolver()

        #expect(resolver.defaultBranch(ofRepositoryRoot: tree) == "develop")
        #expect(!resolver.isDefaultBranch(.branch("spike"), ofRepositoryRoot: tree))
    }

    @Test func treatsADetachedHeadAsSomewhereUnusual() throws {
        let root = try repository("proj", branch: "main")
        setRemoteHead(in: "proj", branch: "main")

        #expect(!DefaultBranchResolver().isDefaultBranch(
            .detached(commit: "0123456789abcdef"),
            ofRepositoryRoot: root
        ))
    }

    @Test func treatsAnUnbornDefaultBranchAsTheDefault() throws {
        // A fresh `git init` has no commits and still names a branch. Reading that
        // as "not the default" would put `:main` on every repository the moment it
        // is created and take it off again at the first commit.
        let root = try repository("fresh", branch: "main")

        #expect(DefaultBranchResolver().isDefaultBranch(.unborn("main"), ofRepositoryRoot: root))
    }

    @Test func remembersTheAnswerRatherThanRunningGitAgain() throws {
        // The cost guard. The poll runs every two seconds per pane, so a second read
        // must not reach git. Proved by moving the ref underneath the resolver: a
        // resolver that re-read would report the new value, and the fresh resolver
        // at the end proves the ref really did move rather than the write having
        // silently failed.
        let root = try repository("proj", branch: "main")
        setRemoteHead(in: "proj", branch: "main")
        let resolver = DefaultBranchResolver()
        #expect(resolver.defaultBranch(ofRepositoryRoot: root) == "main")

        setRemoteHead(in: "proj", branch: "trunk")

        #expect(resolver.defaultBranch(ofRepositoryRoot: root) == "main")
        #expect(resolver.isDefaultBranch(.branch("main"), ofRepositoryRoot: root))
        #expect(DefaultBranchResolver().defaultBranch(ofRepositoryRoot: root) == "trunk")
    }

    @Test func remembersThatARepositoryHasNoAnswer() throws {
        // The negative is cached too. Retrying a repository with no remote would put
        // one `for-each-ref` per pane per poll on exactly the repositories that can
        // never answer, which is the whole set of local-only ones.
        let root = try repository("vault", branch: "main")
        let resolver = DefaultBranchResolver()
        #expect(resolver.defaultBranch(ofRepositoryRoot: root) == nil)

        setRemoteHead(in: "vault", branch: "trunk")

        #expect(resolver.defaultBranch(ofRepositoryRoot: root) == nil)
        #expect(DefaultBranchResolver().defaultBranch(ofRepositoryRoot: root) == "trunk")
    }

    @Test func keepsOneAnswerPerRepository() throws {
        // One cache, several repositories: the second must not inherit the first's
        // answer. A single stored value would make every pane in the window agree
        // with whichever repository was read first.
        let alpha = try repository("alpha", branch: "develop")
        setRemoteHead(in: "alpha", branch: "develop")
        let beta = try repository("beta", branch: "main")
        setRemoteHead(in: "beta", branch: "main")
        let resolver = DefaultBranchResolver()

        #expect(resolver.defaultBranch(ofRepositoryRoot: alpha) == "develop")
        #expect(resolver.defaultBranch(ofRepositoryRoot: beta) == "main")
        #expect(resolver.defaultBranch(ofRepositoryRoot: alpha) == "develop")
    }
}
