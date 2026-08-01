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

    /// `café.txt` in Latin-1: eight bytes, where the fourth is `0xE9` and is not a
    /// UTF-8 sequence at all. UTF-8 spells the same name in nine.
    private static let latin1Name: [UInt8] = Array("caf".utf8) + [0xE9] + Array(".txt".utf8)

    /// Adds an index entry named by `name`'s bytes to the repository at `path`.
    ///
    /// **The file cannot be written to disk, and that is not a shortcut taken here.**
    /// APFS refuses a name that is not valid UTF-8: `open` fails with `EILSEQ`, so
    /// no fixture on this machine can create `caf<E9>.txt`. Git's index has no such
    /// rule and neither does a tree object, so a repository cloned from a filesystem
    /// that allowed the name (an ext4 checkout, an NFS or SMB share, an ExFAT
    /// volume) holds the path in exactly this shape on a Mac, with nothing on disk
    /// to match it. `git ls-files` lists it and `git status` reports it deleted,
    /// which is how these bytes reach the parsers in the field.
    ///
    /// `Process` rather than ``GitCommand``, and stdin rather than an argument,
    /// because argv is where this stops being expressible: `posix_spawn` takes C
    /// strings built from Swift `String`s, and a `String` cannot hold `0xE9` on its
    /// own. On a pipe, bytes stay bytes.
    private func indexEntry(named name: [UInt8], in path: String) throws {
        let sha = try #require(
            run(["rev-parse", ":c.txt"], in: path)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = [
            "-C", fixture.root.appending(path: path).path(percentEncoded: false),
            "update-index", "-z", "--index-info",
        ]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        // `mode SP sha TAB path`, and under `-z` the path is terminated by a NUL
        // rather than by a newline, which is what lets it hold any byte but that
        // one.
        try input.fileHandleForWriting.write(
            contentsOf: Data("100644 \(sha)\t".utf8) + Data(name) + Data([0])
        )
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
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

    /// The seam the fixture tests cannot cover: real git writing real bytes for
    /// names that would be C-quoted without `-z`. A fixture proves the grammar and
    /// this proves the flag is actually passed, which is the half that was wrong.
    ///
    /// Every name here is legal on macOS. Before `-z` the panel showed
    /// `"caf\303\251.txt"` for the first, and a reader taking that as a path would
    /// have been handed one no filesystem holds.
    @Test func readsRealPathsThatWouldOtherwiseArriveCQuoted() throws {
        let root = try repository("proj")
        try fixture.file("proj/café.txt", contents: "x\n")
        try fixture.file("proj/ctrl\tname.txt", contents: "x\n")
        try fixture.file("proj/quo\"te.txt", contents: "x\n")
        try fixture.file("proj/two\nlines.txt", contents: "x\n")

        let changes = git.read(ofRepositoryRoot: root).changes

        #expect(Set(changes.map(\.path)) == [
            "café.txt",
            "ctrl\tname.txt",
            "quo\"te.txt",
            "two\nlines.txt",
        ])
        #expect(changes.allSatisfy { $0.kind == .untracked })
    }

    /// Git's own bytes, before anything decides what they mean. The read that every
    /// byte-carrying answer below is built on: if this decoded, nothing downstream
    /// could undo it.
    @Test func handsBackGitsBytesUndecoded() throws {
        let root = try repository("proj")
        try indexEntry(named: Self.latin1Name, in: "proj")

        let output = git.bytes(of: ["ls-files", "-z"], in: root)

        #expect(output == Array("c.txt\0".utf8) + Self.latin1Name + [0])
    }

    /// The mangling this branch exists to fix. `-z` stops git from quoting the name,
    /// and the bytes still did not survive the read: `String(decoding:as:UTF8.self)`
    /// replaces the one byte that is not UTF-8 with U+FFFD rather than refusing it.
    ///
    /// Both spellings are asserted on purpose, and the pair is the whole design.
    /// ``FileTreeNode/name`` is what a row draws and is still lossy, because a row
    /// has to draw something. ``FileTreeNode/rawName`` is what the file is called,
    /// and it now survives the whole path from git's pipe to the node.
    @Test func aFileWhoseNameIsNotUTF8KeepsItsBytes() throws {
        let root = try repository("proj")
        try indexEntry(named: Self.latin1Name, in: "proj")

        let files = git.files(ofRepositoryRoot: root)

        #expect(files.map(\.rawName).contains(RepositoryPath(Self.latin1Name)))
        #expect(files.map(\.name).contains("caf\u{FFFD}.txt"))
    }

    /// The same byte on the surface the path picker reads, through the whole path
    /// from git's pipe. A click would have to send what this carries, since a
    /// replaced byte is a path handed to the shell that no command can find. This
    /// asserts the parser's answer only; the picker still sends the lossy spelling
    /// and no test here reaches it.
    ///
    /// The entry is reported deleted because the file cannot exist on APFS, which is
    /// the same shape a Mac sees for any repository holding a path this filesystem
    /// could not have made. `git checkout --` against that path is the command the
    /// bytes are for.
    @Test func aChangedPathThatIsNotUTF8KeepsItsBytes() throws {
        let root = try repository("proj")
        try indexEntry(named: Self.latin1Name, in: "proj")

        let changes = git.read(ofRepositoryRoot: root).changes

        #expect(changes.map(\.rawPath) == [RepositoryPath(Self.latin1Name)])
        #expect(changes.map(\.path) == ["caf\u{FFFD}.txt"])
        #expect(changes.map(\.worktree) == [.deleted])
    }

    /// A real rename, so the two-entry layout `-z` gives a `2` record is read from
    /// git's own bytes rather than from a fixture. The original path is chosen to
    /// look exactly like an untracked record: left loose on the stream it becomes
    /// a change for a file that does not exist.
    @Test func readsARealRenameWhoseOriginalPathLooksLikeARecord() throws {
        let root = try repository("proj")
        try fixture.file("proj/? evil.txt", contents: "a path shaped like a record\n")
        run(["add", "--", "? evil.txt"], in: "proj")
        run(["commit", "--quiet", "--no-verify", "-m", "add"], in: "proj")
        run(["mv", "--", "? evil.txt", "renamed.txt"], in: "proj")

        let changes = git.read(ofRepositoryRoot: root).changes

        #expect(changes.map(\.path) == ["renamed.txt"])
        #expect(changes.first?.originalPath == "? evil.txt")
        #expect(changes.first?.kind == .renamedOrCopied)
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
