import Darwin
import Foundation

/// Runs `git` and hands back its standard output.
///
/// `Process` is not used. The only way to start one is `try process.run()`, and
/// this package answers every fallible read with nil rather than a throw.
/// `Process.launch()` is the non-throwing spelling and it raises an Objective-C
/// exception for a missing executable, which is a crash rather than a nil.
/// `posix_spawn` reports both a missing binary and a failed fork as a return
/// code, so a machine without the Command Line Tools degrades to a pane with no
/// git information instead of taking the app down.
///
/// Stateless, so `Sendable` needs nothing but the conformance. The parsers are
/// callable without this type at all, which is where most of the tests live.
public struct GitCommand: Sendable {
    public init() {}

    /// Standard output of `git <arguments>` run against `directory`, or nil for a
    /// non-zero exit, a terminating signal, a missing binary, or a directory that
    /// is not there.
    ///
    /// Pass `--no-optional-locks` before the subcommand for anything on a timer.
    /// Without it a `git status` poll refreshes the index and takes `index.lock`,
    /// which makes a concurrent `git commit` typed into the pane fail with
    /// "Unable to create '.git/index.lock': File exists". `ps1-style.sh` passes it
    /// on every call for exactly this reason, and a status bar polling four panes
    /// is a far better chance of collision than a shell prompt.
    public func output(of arguments: [String], in directory: URL) -> String? {
        guard let executable = Self.executablePath() else { return nil }

        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { return nil }
        let readEnd = descriptors[0]
        let writeEnd = descriptors[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)

        // The child gets no read end. A copy surviving there means this side's
        // `read` never sees EOF once git exits, because a reader is still holding
        // a writer open, and the loop below would block forever.
        posix_spawn_file_actions_addclose(&actions, readEnd)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, STDOUT_FILENO)

        // stderr goes to /dev/null. Inheriting the app's means git's "fatal: not
        // a git repository" lands in the console on every poll of a pane that is
        // not in a repository, and the nil return already carries that fact.
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        // stdin too. A git that decides to prompt (a credential helper, a
        // passphrase) would otherwise inherit the app's stdin and hang, and a
        // hung poll is the 25 minute silent stall this workspace is meant to stop
        // producing.
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)

        // `-C` rather than `posix_spawn_file_actions_addchdir_np`, which is
        // deprecated as of the macOS 26 SDK in favour of a spelling that does not
        // exist on this package's deployment target. git's own option needs
        // neither, and it is what `ps1-style.sh` uses.
        var argv: [UnsafeMutablePointer<CChar>?] =
            ([executable, "-C", directory.path(percentEncoded: false)] + arguments)
                .map { strdup($0) }
        argv.append(nil)
        defer { for argument in argv { free(argument) } }

        var pid: pid_t = 0
        // The environment is inherited. git needs HOME to find the user's config,
        // and passing nil here would hand the child an empty environment, which
        // changes what `git status` reports.
        let spawned = posix_spawn(&pid, executable, &actions, nil, &argv, environ)
        posix_spawn_file_actions_destroy(&actions)

        // Closed here, after the spawn and before the read. The child holds the
        // only other copy now, so its exit is what closes the pipe and ends the
        // loop.
        close(writeEnd)
        guard spawned == 0 else {
            close(readEnd)
            return nil
        }

        // Drained before `waitpid`, not after. `git status --untracked-files=all`
        // in a repository with a few thousand untracked files writes past the
        // 64 KiB pipe buffer, and a child blocked on write against a parent
        // blocked in waitpid is a deadlock that only shows up on the largest
        // repository the owner has.
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(readEnd, raw.baseAddress, raw.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer[0 ..< count])
            } else if count == 0 {
                break
            } else if errno != EINTR {
                // A real read error abandons the output. Reaping the child below
                // still happens, so a failed read costs nil rather than a zombie.
                break
            }
        }
        close(readEnd)

        var status: Int32 = 0
        // Retried on EINTR. Any signal delivered to the app interrupts this call,
        // and giving up on the first one leaves the child unreaped as a zombie for
        // the life of the process.
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        guard Self.exitedCleanly(status) else { return nil }

        // Invalid UTF-8 is replaced rather than rejected. git reports a path in
        // whatever bytes the filesystem holds, and one badly named file should not
        // blank the whole status bar.
        return String(decoding: data, as: UTF8.self)
    }

    /// A ``RepositoryStatus`` for a repository root, in-progress operation
    /// included.
    ///
    /// Composed here rather than left to the caller because ``GitStatusParser``
    /// can never fill `inProgress` on its own: porcelain v2 says nothing about a
    /// half-finished rebase, so a caller wiring the parser up itself would ship a
    /// status bar where that field is permanently nil.
    public func status(ofRepositoryRoot root: URL) -> RepositoryStatus? {
        guard let output = output(
            of: ["--no-optional-locks", "status", "--porcelain=v2", "--branch", "--untracked-files=all"],
            in: root
        ) else { return nil }
        guard var status = GitStatusParser.parse(output) else { return nil }
        if let gitDirectory = GitDirectory.url(forRepositoryRoot: root) {
            status.inProgress = InProgressProbe.detect(gitDirectory: gitDirectory)
        }
        return status
    }

    /// The branch a remote calls this repository's default, or nil when no remote
    /// has ever said.
    ///
    /// One process, and never on a timer: ``DefaultBranchResolver`` is what callers
    /// want, since it remembers the answer and this does not.
    ///
    /// `--no-optional-locks` for the same reason every other read here passes it.
    /// `for-each-ref` takes no index lock of its own, but this runs from inside the
    /// status poll's queue, and the flag costs nothing next to a `git commit` in the
    /// pane failing on `index.lock`.
    public func defaultBranch(ofRepositoryRoot root: URL) -> String? {
        guard let output = output(
            of: [
                "--no-optional-locks",
                "for-each-ref",
                "--format=%(refname) %(symref)",
                "refs/remotes/*/HEAD",
            ],
            in: root
        ) else { return nil }
        return DefaultBranchParser.parse(output)
    }

    /// Every working tree of a repository, main first.
    ///
    /// This is the closure ``ProjectDiscovery/discover(worktrees:)`` wants, which
    /// is why it exists as a method rather than being left to the call site: the
    /// walk must never find worktrees by descending into them.
    public func worktrees(ofRepositoryRoot root: URL) -> [Worktree] {
        guard let output = output(of: ["worktree", "list", "--porcelain"], in: root) else {
            return []
        }
        return GitWorktreeParser.parse(output)
    }

    /// Absolute paths, in order.
    ///
    /// Looking git up by name is what fails here: a GUI app inherits `PATH` from
    /// launchd rather than from a login shell, so `/opt/homebrew/bin` is simply
    /// absent when baia is opened from the Finder and present when it is opened
    /// from a terminal. That is a bug that reproduces on one launch path and not
    /// the other, which is the worst kind to chase.
    private static let candidatePaths = [
        "/usr/bin/git",
        "/usr/local/bin/git",
        "/opt/homebrew/bin/git",
    ]

    /// The first candidate that is there, or nil on a machine with no git.
    ///
    /// `/usr/bin/git` is a Command Line Tools shim that exists even when the tools
    /// are not installed, in which case it exits non-zero after putting an
    /// installer dialog on screen. Nothing here can prevent that, and the
    /// non-zero exit already reads as nil, so the shim stays first: when the tools
    /// are installed it is the right answer and it is the only one present on a
    /// machine with no homebrew.
    private static func executablePath() -> String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// True when the child exited normally with status 0.
    ///
    /// `WIFEXITED` and `WEXITSTATUS` are C macros and do not survive into Swift,
    /// so the wait status is decoded by hand: the low seven bits carry the
    /// terminating signal, and a zero there means a normal exit with the code in
    /// the next eight bits. Testing the whole word against 0 would look right and
    /// would also accept a child killed by signal 0, which does not exist, while
    /// rejecting nothing extra. Testing only the high byte would accept a git
    /// killed by SIGKILL as a success.
    private static func exitedCleanly(_ status: Int32) -> Bool {
        (status & 0x7F) == 0 && ((status >> 8) & 0xFF) == 0
    }
}
