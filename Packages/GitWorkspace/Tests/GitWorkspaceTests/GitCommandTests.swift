import Foundation
import Testing

@testable import GitWorkspace

/// The only tests here that build real repositories. Everything about the grammars
/// is covered on fixture strings, which is why these can stay few: a real
/// `git init` plus commit is two process spawns, and the suite is meant to stay in
/// the range where the owner runs it on every save.
@Suite final class GitCommandTests {
    let fixture: DirectoryFixture
    let git = GitCommand()

    init() throws {
        fixture = try DirectoryFixture()
    }

    /// Runs git against `path` under the fixture with the identity and safety flags
    /// every write needs.
    ///
    /// `init.defaultBranch` and `user.*` are passed per invocation rather than
    /// written into a config file, because the owner's global config is inherited
    /// through the environment: without them a machine with no `user.email` cannot
    /// commit and a machine with a different `init.defaultBranch` gets a branch
    /// name these tests do not expect. `commit.gpgsign=false` and `--no-verify`
    /// cover a global signing key and a global `core.hooksPath`.
    @discardableResult
    private func run(_ arguments: [String], in path: String = "") -> String? {
        git.output(
            of: [
                "-c", "user.name=baia",
                "-c", "user.email=baia@example.invalid",
                "-c", "commit.gpgsign=false",
                "-c", "init.defaultBranch=main",
            ] + arguments,
            in: path.isEmpty ? fixture.root : fixture.root.appending(path: path)
        )
    }

    /// A repository at `path` with one commit on `main`.
    @discardableResult
    private func repository(_ path: String) throws -> URL {
        let root = try fixture.directory(path)
        run(["init", "--quiet"], in: path)
        try fixture.file("\(path)/c.txt", contents: "base\n")
        run(["add", "-A"], in: path)
        run(["commit", "--quiet", "--no-verify", "-m", "base"], in: path)
        return root
    }

    @Test func readsStandardOutputOfARealGitCommand() {
        // Proves the pipe is wired and drained at all. Everything below depends on
        // it, and `--version` needs no repository, so a failure here separates a
        // broken spawn from a broken repository setup.
        #expect(git.output(of: ["--version"], in: fixture.root)?.hasPrefix("git version") == true)
    }

    @Test func returnsNilForANonZeroExit() {
        // `git status` outside a work tree exits 128. Returning its stdout, which
        // is empty, would parse as a repository with no branch header, and the
        // status bar would show a blank branch instead of nothing.
        #expect(git.output(of: ["status"], in: fixture.root) == nil)
    }

    @Test func returnsNilForADirectoryThatIsNotThere() {
        // `-C` on a missing directory makes git exit non-zero rather than run
        // somewhere else, which is the whole reason the working directory is passed
        // as an argument and not as an inherited chdir.
        #expect(git.output(of: ["status"], in: fixture.root.appending(path: "gone")) == nil)
    }

    @Test func returnsNilForASubcommandThatDoesNotExist() {
        #expect(git.output(of: ["not-a-subcommand"], in: fixture.root) == nil)
    }

    @Test func readsOutputLargerThanThePipeBuffer() throws {
        // The pipe buffer is 64 KiB and this is roughly 300 KiB. Reaping the child
        // before draining the pipe deadlocks here and nowhere else, which is why
        // the failure mode only ever shows up on the owner's largest repository.
        try repository("big")
        let payload = String(repeating: "0123456789abcdef\n", count: 20000)
        try fixture.file("big/blob.txt", contents: payload)
        run(["add", "blob.txt"], in: "big")

        let output = git.output(of: ["cat-file", "-p", ":blob.txt"], in: fixture.root.appending(path: "big"))

        #expect(payload.utf8.count > 1 << 16)
        #expect(output?.utf8.count == payload.utf8.count)
    }

    @Test func readsTheStatusOfARealCleanRepository() throws {
        let root = try repository("proj")
        #expect(git.status(ofRepositoryRoot: root) == RepositoryStatus(head: .branch("main")))
    }

    @Test func readsTheStatusOfARealUnbornRepository() throws {
        // The `(initial)` oid is only reachable from a repository with no commits,
        // and a fixture string cannot prove git still spells it that way.
        let root = try fixture.directory("fresh")
        run(["init", "--quiet"], in: "fresh")
        #expect(git.status(ofRepositoryRoot: root)?.head == .unborn("main"))
    }

    @Test func countsRealStagedUnstagedAndUntrackedFiles() throws {
        let root = try repository("proj")
        try fixture.file("proj/c.txt", contents: "staged\n")
        run(["add", "c.txt"], in: "proj")
        try fixture.file("proj/c.txt", contents: "staged then edited\n")
        try fixture.file("proj/new note.txt", contents: "x\n")

        let status = git.status(ofRepositoryRoot: root)

        #expect(status?.staged == 1)
        #expect(status?.unstaged == 1)
        #expect(status?.untracked == 1)
        #expect(status?.indicators == "*?")
    }

    @Test func reportsARealMergeInProgressWithItsConflict() throws {
        // The composition that neither half can do alone: porcelain v2 reports the
        // conflict and says nothing about the merge, while the probe reports the
        // merge and cannot count anything. A caller wiring up the parser on its own
        // gets a permanently nil `inProgress`.
        let root = try repository("proj")
        run(["checkout", "--quiet", "-b", "other"], in: "proj")
        try fixture.file("proj/c.txt", contents: "other\n")
        run(["commit", "--quiet", "--no-verify", "-am", "other"], in: "proj")
        run(["checkout", "--quiet", "main"], in: "proj")
        try fixture.file("proj/c.txt", contents: "main\n")
        run(["commit", "--quiet", "--no-verify", "-am", "main"], in: "proj")
        run(["merge", "--no-edit", "other"], in: "proj")

        let status = git.status(ofRepositoryRoot: root)

        #expect(status?.inProgress == .merge)
        #expect(status?.conflicted == 1)
        #expect(status?.indicators == "*")
    }

    @Test func returnsNoStatusForADirectoryThatIsNotARepository() throws {
        let plain = try fixture.directory("notes")
        #expect(git.status(ofRepositoryRoot: plain) == nil)
    }

    @Test func readsTheWorktreesOfARealRepository() throws {
        // Both layouts the workspace uses, created by git rather than by hand, so
        // the `.git` file, the registry under `.git/worktrees`, and the porcelain
        // stanzas are all the real thing.
        let root = try repository("proj")
        run(["worktree", "add", "--quiet", ".worktrees/feature-0725-1200", "-b", "feature"], in: "proj")
        run(["worktree", "add", "--quiet", "--detach", ".claude/worktrees/agent-4f21"], in: "proj")

        let worktrees = git.worktrees(ofRepositoryRoot: root)

        #expect(worktrees.count == 3)
        #expect(worktrees.first?.isMain == true)
        #expect(worktrees.first?.branch == "main")
        #expect(worktrees.map(\.displayName) == ["proj", "agent-4f21", "feature-0725-1200"])
        #expect(worktrees.last?.branch == "feature")
        #expect(worktrees.dropFirst().first?.isDetached == true)
    }

    @Test func resolvesTheGitDirectoryOfARealLinkedWorktree() throws {
        // A worktree git made, not a hand-written pointer file. It is also what
        // proves the in-progress probe looks in the right place for a worktree: the
        // markers live under `.git/worktrees/<name>`, not under the main `.git`.
        let root = try repository("proj")
        run(["worktree", "add", "--quiet", ".worktrees/spike", "-b", "spike"], in: "proj")
        let tree = root.appending(path: ".worktrees/spike")

        #expect(GitDirectory.isLinkedWorktree(repositoryRoot: tree))
        #expect(GitDirectory.url(forRepositoryRoot: tree)?.lastPathComponent == "spike")
        #expect(!GitDirectory.isLinkedWorktree(repositoryRoot: root))
    }

    /// The test that justifies asking git rather than walking the directory
    /// ourselves. `build/` is ignored by a `.gitignore`, `secret.env` by
    /// `.git/info/exclude`, and `keep.log` is un-ignored by a negation, which is the
    /// rule a hand-written walk gets wrong first. All three answers come from git.
    @Test func theFileTreeHonoursEveryIgnoreSourceAtOnce() throws {
        let root = try repository("proj")
        try fixture.file("proj/.gitignore", contents: "build/\n*.log\n!keep.log\n")
        try fixture.file("proj/build/artifact.o", contents: "")
        try fixture.file("proj/noise.log", contents: "")
        try fixture.file("proj/keep.log", contents: "")
        try fixture.file("proj/secret.env", contents: "")
        try fixture.file("proj/.git/info/exclude", contents: "secret.env\n")
        try fixture.file("proj/Sources/app.swift", contents: "")

        let names = git.files(ofRepositoryRoot: root).map(\.name)

        // Directories first, then files, each sorted without regard to case.
        #expect(names == ["Sources", ".gitignore", "c.txt", "keep.log"])
        #expect(names.contains("build") == false)
        #expect(names.contains("noise.log") == false)
        #expect(names.contains("secret.env") == false)
    }

    @Test func theFileTreeNestsWhatGitLists() throws {
        let root = try repository("proj")
        try fixture.file("proj/Sources/App/main.swift", contents: "")

        let tree = git.files(ofRepositoryRoot: root)
        let sources = try #require(tree.first { $0.name == "Sources" })
        #expect(sources.isDirectory)
        #expect(sources.children.map(\.name) == ["App"])
        #expect(sources.children[0].children.map(\.path) == ["Sources/App/main.swift"])
    }

    @Test func theFileTreeIsEmptyForADirectoryThatIsNotARepository() throws {
        // An empty tree rather than nil, for the reason the worktree list gives
        // below: a caller can render it without a branch. A pane anchored to a
        // plain directory is an ordinary case, not an error.
        let plain = try fixture.directory("notes")
        #expect(git.files(ofRepositoryRoot: plain).isEmpty)
    }

    @Test func returnsNoWorktreesForADirectoryThatIsNotARepository() throws {
        // An empty array rather than nil, so a caller can hand this straight to
        // `ProjectDiscovery.discover(worktrees:)` without a branch.
        let plain = try fixture.directory("notes")
        #expect(git.worktrees(ofRepositoryRoot: plain).isEmpty)
    }

    @Test func discoversRealRepositoriesAndTheirRealWorktrees() throws {
        // The wiring the app will use, end to end: the walk finds repositories and
        // git names their worktrees. `.worktrees` is a full file copy holding its
        // own `.git`, and it appears here only because git was asked, which is what
        // keeps the walk from tripling.
        try repository("website/shop")
        try repository("baia")
        run(["worktree", "add", "--quiet", ".worktrees/feature-0725-1200", "-b", "feature"], in: "baia")

        let projects = ProjectDiscovery(
            roots: [fixture.root],
            maxDepth: 2,
            ignoredNames: ProjectDiscovery.defaultIgnoredNames
        ).discover(worktrees: git.worktrees(ofRepositoryRoot:))

        #expect(projects.map(\.relativePath) == [
            "baia",
            "baia/.worktrees/feature-0725-1200",
            "website/shop",
        ])
        #expect(projects.map(\.kind) == [
            .repository,
            .worktree(ofRepositoryNamed: "baia"),
            .repository,
        ])
    }
}
