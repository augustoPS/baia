import Darwin
import Foundation

/// Why a subprocess read failed before it could produce a complete answer.
public enum SubprocessFailure: Sendable, Equatable {
    /// The pipe, spawn actions, process attributes, or executable launch failed.
    case spawn(Int32)
    /// The child was not the leader of the private process group requested at spawn.
    case unsafeProcessGroup
    /// Reading standard output failed.
    case read(Int32)
    /// The process exited normally with a non-zero status.
    case exit(Int32)
    /// The process was terminated by a signal before a bounded stop was requested.
    case signal(Int32)
    /// The direct child could not be waited for after its output ended. The
    /// value is `errno` from `waitpid`, in practice `ECHILD`: something else in
    /// this process reaped the child first, so its exit status is gone. Kept apart
    /// from ``exit(_:)`` because `ECHILD` is 10, and an exit code of 10 is a claim
    /// about git that nothing here observed.
    case wait(Int32)
}

/// The complete, typed result of a bounded subprocess read.
public enum SubprocessOutcome: Sendable, Equatable {
    case completed([UInt8])
    case failed(SubprocessFailure)
    case timedOut
    case tooMuchOutput
    case cancelled
}

/// Limits applied to spawn, output drain, process exit, and bounded teardown.
///
/// A deadline or cancellation gives the owned group one `terminationGrace`
/// after TERM, then gives the direct child one `terminationGrace` after KILL.
/// The caller therefore waits at most `deadline + 2 * terminationGrace`, apart
/// from scheduler latency. A direct child still not waitable then is retained by
/// the deferred reaper; no caller waits for a grandchild.
public struct SubprocessLimits: Sendable, Equatable {
    /// Maximum wall time, measured on a monotonic clock, before teardown starts.
    public let deadline: TimeInterval
    /// Maximum bytes retained. The first byte beyond this limit abandons the read.
    public let outputLimit: Int
    /// Time allowed after TERM and again after KILL before cleanup continues off-caller.
    public let terminationGrace: TimeInterval

    public init(
        deadline: TimeInterval,
        outputLimit: Int,
        terminationGrace: TimeInterval
    ) {
        self.deadline = max(0, deadline)
        self.outputLimit = max(0, outputLimit)
        self.terminationGrace = max(0, terminationGrace)
    }

    public static let `default` = SubprocessLimits(
        deadline: 10,
        outputLimit: 16 << 20,
        terminationGrace: 0.5
    )
}

/// An idempotent cancellation signal that may be fired from any thread.
public final class SubprocessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

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
public struct GitCommand: Sendable {
    private let limits: SubprocessLimits
    private let executablePathOverride: String?
    private let fixedArguments: [String]
    private let counter: SpawnCounter

    public init(limits: SubprocessLimits = .default) {
        self.limits = limits
        executablePathOverride = nil
        fixedArguments = []
        counter = SpawnCounter()
    }

    /// A package-internal executable seam for real subprocess fixtures.
    init(
        executablePath: String,
        fixedArguments: [String] = [],
        limits: SubprocessLimits = .default
    ) {
        self.limits = limits
        executablePathOverride = executablePath
        self.fixedArguments = fixedArguments
        counter = SpawnCounter()
    }

    /// How many times this command has spawned `git`.
    ///
    /// Not instrumentation added for a test. The claims this type makes are about
    /// *how often* it runs, not about what it returns: the status read is on a timer
    /// per pane, the file tree is cached per repository, and the sidebar is supposed
    /// to cost nothing when focus moves. Every one of those failures is invisible,
    /// since a doubled read returns the same answer and shows up only as heat, so the
    /// count is the only thing that can contradict them.
    ///
    /// Per command rather than per process, and shared across copies of one command
    /// because the box is a reference: the app hands a `GitCommand` into background
    /// closures by value, and a count that reset on every copy would answer zero
    /// forever. Process-wide was the first shape and it is untestable, since suites
    /// running in parallel spawn git into each other's baseline.
    public var spawnCount: Int { counter.value }

    public func resetSpawnCount() { counter.reset() }

    /// A lock rather than an actor: this is touched from whatever queue a caller is
    /// on, immediately before a `Process` launch that costs orders of magnitude more.
    final class SpawnCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        func reset() {
            lock.lock()
            count = 0
            lock.unlock()
        }
    }

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
    /// Lossy, and only for output that is git's own words rather than the
    /// filesystem's: a version string, a branch name, a worktree stanza. Anything
    /// carrying a path wants ``bytes(of:in:)``, because this replaces every byte it
    /// cannot decode with U+FFFD and there is no way back from that.
    public func output(of arguments: [String], in directory: URL) -> String? {
        bytes(of: arguments, in: directory).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The same read, undecoded.
    ///
    /// **Where the decision belongs.** git writes paths in whatever bytes the
    /// filesystem holds, and a repository cloned from one that allowed a name this
    /// one could not make carries paths that are not UTF-8. Decoding at the pipe
    /// throws the name away before any parser can see it, so the pipe hands over
    /// bytes and each field decides for itself: a path stays bytes in a
    /// ``RepositoryPath``, and everything git spells itself becomes text.
    public func bytes(of arguments: [String], in directory: URL) -> [UInt8]? {
        guard case let .completed(bytes) = run(arguments, in: directory) else { return nil }
        return bytes
    }

    /// Runs one command under the configured deadline and output cap.
    ///
    /// The deadline starts before the spawn is scheduled. If `posix_spawn` itself
    /// does not return in time, the caller returns while this command's retained
    /// execution owner waits for the pid and tears it down before releasing it.
    public func run(
        _ arguments: [String],
        in directory: URL,
        cancellation: SubprocessCancellation? = nil
    ) -> SubprocessOutcome {
        if cancellation?.isCancelled == true { return .cancelled }

        let execution = SubprocessExecution(
            executable: executablePathOverride ?? Self.executablePath(),
            fixedArguments: executablePathOverride == nil
                ? ["-C", directory.path(percentEncoded: false)]
                : fixedArguments,
            arguments: arguments,
            limits: limits,
            cancellation: cancellation,
            counter: counter
        )
        return execution.run()
    }

    /// A ``RepositoryStatus`` for a repository root, in-progress operation
    /// included.
    ///
    /// Composed here rather than left to the caller because ``GitStatusParser``
    /// can never fill `inProgress` on its own: porcelain v2 says nothing about a
    /// half-finished rebase, so a caller wiring the parser up itself would ship a
    /// status bar where that field is permanently nil.
    public func status(ofRepositoryRoot root: URL) -> RepositoryStatus? {
        read(ofRepositoryRoot: root).status
    }

    /// The status and the changed paths, from **one** invocation.
    ///
    /// The pane poller wants both and they come out of the same bytes, so this
    /// exists to stop the second reader from forking a second `git`. That matters
    /// more than it looks: the read is per pane and on a timer, so a second spawn is
    /// a second process every couple of seconds for every pane in every window.
    ///
    /// Two parses over one string rather than one parse producing both, because the
    /// two answers are shaped for different surfaces and neither type should grow
    /// the other's fields. See ``GitStatusParser/changes(_:)``.
    ///
    /// `-z` for the reason ``files(ofRepositoryRoot:)`` passes it, and the changes
    /// list is the same kind of surface as the tree: without it git C-quotes any
    /// path holding a non-ASCII byte, a double quote, a backslash or a control
    /// byte, so the panel drew `café.txt` as `"caf\303\251.txt"` and handed that
    /// rendering to anything downstream. The flag came late, on 2026-07-29, after
    /// the path picker design made the changed paths into something the owner
    /// clicks rather than only reads.
    public func read(
        ofRepositoryRoot root: URL
    ) -> (status: RepositoryStatus?, changes: [RepositoryFileChange]) {
        guard let output = bytes(
            of: [
                "--no-optional-locks",
                "status",
                "--porcelain=v2",
                "--branch",
                "--untracked-files=all",
                "-z",
            ],
            in: root
        ) else { return (nil, []) }
        guard var status = GitStatusParser.parse(output) else { return (nil, []) }
        if let gitDirectory = GitDirectory.url(forRepositoryRoot: root) {
            status.inProgress = InProgressProbe.detect(gitDirectory: gitDirectory)
        }
        return (status, GitStatusParser.changes(output))
    }

    /// Per-file line counts against `HEAD`, staged and unstaged combined.
    ///
    /// `HEAD` rather than `--cached` or the bare worktree comparison, because
    /// ``RepositoryFileChange`` also does not separate the two: one path there
    /// carries one `index` state and one `worktree` state, and the sidebar row
    /// it feeds shows one `+n −n` for the file, not two. `git diff HEAD` is the
    /// single comparison that already sums a file staged and then edited again
    /// the same way that row does.
    ///
    /// An untracked file has no `HEAD` blob to diff against and so never
    /// appears here, which is deliberate rather than a gap: ``RepositoryChangeStats/entry(forPath:)``
    /// answers nil for it, and a caller renders that as "no count available"
    /// rather than `+0 −0`, which is what an untracked file's line count
    /// actually is not.
    ///
    /// A repository with no commits yet has no `HEAD` to diff against either.
    /// git exits non-zero rather than inventing an empty tree to compare, which
    /// ``bytes(of:in:)`` already turns into nil, so this returns an empty
    /// summary the same way it would for a directory that is not a repository.
    ///
    /// One invocation for every file in the repository, on the same cadence as
    /// ``read(ofRepositoryRoot:)``, never one per row: a caller polling per pane
    /// on a timer that forked a second process per changed file would turn a
    /// window with a dozen dirty files into a dozen extra spawns every tick.
    ///
    /// `--raw` rides along with `--numstat` for the reason ``NumstatParser``
    /// documents: numstat's own `-z` output carries no marker telling a rename's
    /// second path apart from the next record, and the raw block's status
    /// letter is what supplies it. `-M` is git's default since 2.9 and passed
    /// anyway, for the same reason `GitCommand` spells out every flag it relies
    /// on rather than trusting a version-dependent default.
    public func changeStats(ofRepositoryRoot root: URL) -> RepositoryChangeStats {
        guard let output = bytes(
            of: ["--no-optional-locks", "diff", "--raw", "--numstat", "HEAD", "-z", "-M"],
            in: root
        ) else { return RepositoryChangeStats(entries: []) }
        return RepositoryChangeStats(entries: NumstatParser.parse(output))
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

    /// Every file the repository holds, as a tree.
    ///
    /// `--cached --others --exclude-standard` is the whole decision: tracked files
    /// plus untracked ones, minus everything the ignore rules exclude, computed by
    /// git rather than by us. `--exclude-standard` is what pulls in `.gitignore` at
    /// every level, `.git/info/exclude` and the `core.excludesFile` global together,
    /// which is the set no hand-written walk gets right for long.
    ///
    /// `-z` because git quotes any path with a space, a quote or a non-ASCII byte
    /// otherwise, and a tree is exactly the surface where a name nobody typed would
    /// be believed.
    ///
    /// `--no-optional-locks` for the reason every read here passes it: this runs
    /// while a `git commit` may be running in the pane, and a read that takes
    /// `index.lock` fails that commit.
    ///
    /// An empty tree for a directory that is not a repository, which is the same
    /// answer as a repository holding nothing. A caller that needs to tell those
    /// apart has already asked for the status.
    public func files(ofRepositoryRoot root: URL) -> [FileTreeNode] {
        guard let output = bytes(
            of: ["--no-optional-locks", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            in: root
        ) else { return [] }
        return FileTree.build(paths: FileTree.paths(fromNulSeparated: output))
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

}

/// Owns one subprocess even when its caller's deadline expires while
/// `posix_spawn` or `waitpid` cannot make progress.
private final class SubprocessExecution: @unchecked Sendable {
    private static let checkInterval: TimeInterval = 0.01

    private let executable: String?
    private let fixedArguments: [String]
    private let arguments: [String]
    private let limits: SubprocessLimits
    private let cancellation: SubprocessCancellation?
    private let counter: GitCommand.SpawnCounter
    private let deadline: TimeInterval

    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private var requestedStop: SubprocessOutcome?
    private var finalOutcome: SubprocessOutcome?

    init(
        executable: String?,
        fixedArguments: [String],
        arguments: [String],
        limits: SubprocessLimits,
        cancellation: SubprocessCancellation?,
        counter: GitCommand.SpawnCounter
    ) {
        self.executable = executable
        self.fixedArguments = fixedArguments
        self.arguments = arguments
        self.limits = limits
        self.cancellation = cancellation
        self.counter = counter
        deadline = MonotonicTime.now + limits.deadline
    }

    func run() -> SubprocessOutcome {
        // A dedicated owner avoids priority inversion and queue starvation when
        // synchronous callers themselves occupy a dispatch executor. If spawn
        // blocks past the caller's bound, this thread remains the cleanup owner.
        Thread.detachNewThread { self.execute() }

        while true {
            if let outcome = outcome() { return outcome }
            if cancellation?.isCancelled == true {
                return stopAndWait(.cancelled)
            }
            let now = MonotonicTime.now
            if now >= deadline {
                return stopAndWait(.timedOut)
            }
            waitForChange(until: min(deadline, now + Self.checkInterval))
        }
    }

    private func stopAndWait(_ reason: SubprocessOutcome) -> SubprocessOutcome {
        requestStop(reason)
        let callerReturnDeadline = MonotonicTime.now + (limits.terminationGrace * 2)
        while MonotonicTime.now < callerReturnDeadline {
            if let outcome = outcome() { return outcome }
            waitForChange(until: min(callerReturnDeadline, MonotonicTime.now + Self.checkInterval))
        }
        return reason
    }

    private func waitForChange(until instant: TimeInterval) {
        let interval = max(0, instant - MonotonicTime.now)
        _ = changed.wait(timeout: .now() + interval)
    }

    private func outcome() -> SubprocessOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return finalOutcome
    }

    @discardableResult
    private func requestStop(_ reason: SubprocessOutcome) -> SubprocessOutcome {
        lock.lock()
        if requestedStop == nil { requestedStop = reason }
        let selected = requestedStop ?? reason
        lock.unlock()
        changed.signal()
        return selected
    }

    private func stopReason() -> SubprocessOutcome? {
        if cancellation?.isCancelled == true {
            return requestStop(.cancelled)
        }
        if MonotonicTime.now >= deadline {
            return requestStop(.timedOut)
        }
        lock.lock()
        defer { lock.unlock() }
        return requestedStop
    }

    private func complete(_ outcome: SubprocessOutcome) {
        lock.lock()
        finalOutcome = requestedStop ?? outcome
        lock.unlock()
        changed.signal()
    }

    private func execute() {
        if let stop = stopReason() {
            complete(stop)
            return
        }
        guard let executable else {
            complete(.failed(.spawn(ENOENT)))
            return
        }

        // `pipe(2)` cannot create the ends close-on-exec; macOS has no `pipe2`.
        // Between this call and the `fcntl` below, both ends are inheritable by
        // any process the app spawns from another thread. Spawns made by this
        // type are covered: `POSIX_SPAWN_CLOEXEC_DEFAULT` below closes every
        // descriptor the child did not get through an explicit file action, so a
        // concurrent read's git never holds this pipe. A foreign launcher in the
        // same process, such as the shell libghostty spawns for a new pane, is
        // not covered: a spawn it makes in this window inherits the write end,
        // and this read then reaches its deadline instead of EOF for as long as
        // that process lives. The window is a few microseconds per read and is
        // recorded here rather than claimed closed.
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            complete(.failed(.spawn(errno)))
            return
        }
        let readEnd = descriptors[0]
        let writeEnd = descriptors[1]
        var readIsOpen = true
        var writeIsOpen = true
        defer {
            if readIsOpen { close(readEnd) }
            if writeIsOpen { close(writeEnd) }
        }

        guard makeNonblockingAndCloseOnExec(readEnd), makeCloseOnExec(writeEnd) else {
            complete(.failed(.spawn(errno)))
            return
        }

        var actions: posix_spawn_file_actions_t?
        var code = posix_spawn_file_actions_init(&actions)
        guard code == 0 else {
            complete(.failed(.spawn(code)))
            return
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        code = posix_spawn_file_actions_addclose(&actions, readEnd)
        if code == 0 { code = posix_spawn_file_actions_adddup2(&actions, writeEnd, STDOUT_FILENO) }
        if code == 0 { code = posix_spawn_file_actions_addclose(&actions, writeEnd) }
        if code == 0 {
            code = posix_spawn_file_actions_addopen(
                &actions,
                STDERR_FILENO,
                "/dev/null",
                O_WRONLY,
                0
            )
        }
        if code == 0 {
            code = posix_spawn_file_actions_addopen(
                &actions,
                STDIN_FILENO,
                "/dev/null",
                O_RDONLY,
                0
            )
        }
        guard code == 0 else {
            complete(.failed(.spawn(code)))
            return
        }

        var attributes: posix_spawnattr_t?
        code = posix_spawnattr_init(&attributes)
        guard code == 0 else {
            complete(.failed(.spawn(code)))
            return
        }
        defer { posix_spawnattr_destroy(&attributes) }

        // `POSIX_SPAWN_CLOEXEC_DEFAULT` is Darwin's answer to the missing
        // `pipe2`: the child starts with every parent descriptor closed except
        // the ones the file actions above open or `dup2` explicitly, which is
        // exactly stdin, stdout and stderr. Without it the child would inherit
        // whatever another thread had open without close-on-exec at that
        // instant: another read's pipe, a pane's pty, a socket. The stdio
        // actions are spelled out rather than inherited for the same reason.
        code = posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        )
        if code == 0 { code = posix_spawnattr_setpgroup(&attributes, 0) }
        guard code == 0 else {
            complete(.failed(.spawn(code)))
            return
        }

        let argumentStrings = [executable] + fixedArguments + arguments
        var argv = argumentStrings.map { strdup($0) }
        guard argv.allSatisfy({ $0 != nil }) else {
            for argument in argv { free(argument) }
            complete(.failed(.spawn(ENOMEM)))
            return
        }
        argv.append(nil)
        defer { for argument in argv { free(argument) } }

        if let stop = stopReason() {
            complete(stop)
            return
        }

        var pid: pid_t = 0
        counter.increment()
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, &argv, environ)
        close(writeEnd)
        writeIsOpen = false
        guard spawned == 0 else {
            complete(.failed(.spawn(spawned)))
            return
        }

        let ownedGroup = getpgid(pid) == pid ? pid : nil
        guard ownedGroup != nil else {
            terminate(
                pid: pid,
                ownedGroup: nil,
                readEnd: readEnd,
                reason: .failed(.unsafeProcessGroup)
            )
            readIsOpen = false
            return
        }

        if let stop = stopReason() {
            terminate(pid: pid, ownedGroup: ownedGroup, readEnd: readEnd, reason: stop)
            readIsOpen = false
            return
        }

        drain(pid: pid, ownedGroup: ownedGroup, readEnd: readEnd)
        readIsOpen = false
    }

    private func makeNonblockingAndCloseOnExec(_ descriptor: Int32) -> Bool {
        let statusFlags = fcntl(descriptor, F_GETFL)
        guard statusFlags != -1,
              fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) != -1
        else { return false }

        return makeCloseOnExec(descriptor)
    }

    private func makeCloseOnExec(_ descriptor: Int32) -> Bool {
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        return descriptorFlags != -1
            && fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) != -1
    }

    private func drain(pid: pid_t, ownedGroup: pid_t?, readEnd: Int32) {
        var data: [UInt8] = []
        data.reserveCapacity(min(limits.outputLimit, 1 << 16))
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var reachedEOF = false

        while true {
            if let stop = stopReason() {
                terminate(pid: pid, ownedGroup: ownedGroup, readEnd: readEnd, reason: stop)
                return
            }

            // EOF is part of a complete answer. The leader exiting first is not:
            // a descendant that inherited stdout may still be producing output
            // the caller asked for, and declaring success on the leader's exit
            // would both truncate that output and kill its producer. So a group
            // whose leader is gone while something still holds the write end runs
            // to the deadline and is reported as a timeout, which is the
            // coordinator's ruling (2026-09-05) over the alternative of finishing
            // on leader exit.
            if reachedEOF {
                switch reap(pid, options: WNOHANG) {
                case let .reaped(status):
                    complete(Self.outcome(for: status, data: data))
                    close(readEnd)
                    return
                case .running:
                    usleep(useconds_t(Self.checkInterval * 1_000_000))
                    continue
                case let .failed(error):
                    // The child is no longer ours to wait for, which for `ECHILD`
                    // means something else in the process reaped it. Its status is
                    // gone, and so is the reason to signal or adopt it: whoever
                    // reaped it owns nothing further either.
                    complete(.failed(.wait(error)))
                    close(readEnd)
                    return
                }
            }

            var descriptor = pollfd(
                fd: readEnd,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let remaining = max(0, deadline - MonotonicTime.now)
            let timeout = Int32(max(1, min(Self.checkInterval, remaining) * 1_000).rounded(.up))
            let polled = poll(&descriptor, 1, timeout)
            if polled == -1 {
                if errno == EINTR { continue }
                let failure = SubprocessOutcome.failed(.read(errno))
                requestStop(failure)
                terminate(pid: pid, ownedGroup: ownedGroup, readEnd: readEnd, reason: failure)
                return
            }
            if polled == 0 { continue }
            if descriptor.revents & Int16(POLLNVAL) != 0 {
                let failure = SubprocessOutcome.failed(.read(EBADF))
                requestStop(failure)
                terminate(pid: pid, ownedGroup: ownedGroup, readEnd: readEnd, reason: failure)
                return
            }

            var readAttempts = 0
            while readAttempts < 16 {
                readAttempts += 1
                let count = buffer.withUnsafeMutableBytes { raw in
                    Darwin.read(readEnd, raw.baseAddress, raw.count)
                }
                if count > 0 {
                    let remainingCapacity = limits.outputLimit - data.count
                    if count > remainingCapacity {
                        let overflow = requestStop(.tooMuchOutput)
                        terminate(pid: pid, ownedGroup: ownedGroup, readEnd: readEnd, reason: overflow)
                        return
                    }
                    data.append(contentsOf: buffer[0 ..< count])
                    continue
                }
                if count == 0 {
                    reachedEOF = true
                    break
                }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { break }

                let failure = SubprocessOutcome.failed(.read(errno))
                requestStop(failure)
                terminate(pid: pid, ownedGroup: ownedGroup, readEnd: readEnd, reason: failure)
                return
            }
        }
    }

    /// TERM and KILL are sent while the leader remains unreaped. Its pid therefore
    /// cannot be reused between the two signals. Only the direct child is reaped.
    private func terminate(
        pid: pid_t,
        ownedGroup: pid_t?,
        readEnd: Int32,
        reason: SubprocessOutcome
    ) {
        let target = ownedGroup.map { -$0 } ?? pid
        _ = kill(target, SIGTERM)
        drainDiscarding(readEnd, until: MonotonicTime.now + limits.terminationGrace)

        // The direct child is deliberately still ours here. Reaping it before
        // this signal would permit its numeric process-group identity to be reused.
        _ = kill(target, SIGKILL)
        let reapDeadline = MonotonicTime.now + limits.terminationGrace
        while MonotonicTime.now < reapDeadline {
            drainAvailableDiscarding(readEnd)
            switch reap(pid, options: WNOHANG) {
            case .reaped, .failed:
                // Reaped here, or reaped by someone else: either way there is no
                // child left to adopt, and the stop reason is still the answer.
                close(readEnd)
                complete(reason)
                return
            case .running:
                usleep(useconds_t(Self.checkInterval * 1_000_000))
            }
        }

        close(readEnd)
        DeferredChildReaper.shared.adopt(pid)
        complete(reason)
    }

    private func drainDiscarding(_ descriptor: Int32, until deadline: TimeInterval) {
        while MonotonicTime.now < deadline {
            drainAvailableDiscarding(descriptor)
            usleep(useconds_t(Self.checkInterval * 1_000_000))
        }
    }

    private func drainAvailableDiscarding(_ descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 1 << 14)
        for _ in 0 ..< 16 {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if count > 0 { continue }
            if count == -1, errno == EINTR { continue }
            return
        }
    }

    private enum ReapResult {
        case reaped(Int32)
        case running
        /// `waitpid` refused, with its `errno`. `ECHILD` in practice.
        case failed(Int32)
    }

    private func reap(_ pid: pid_t, options: Int32) -> ReapResult {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, options)
            if result == pid { return .reaped(status) }
            if result == 0 { return .running }
            let error = errno
            if error == EINTR { continue }
            return .failed(error)
        }
    }

    private static func outcome(for status: Int32, data: [UInt8]) -> SubprocessOutcome {
        let signal = status & 0x7F
        if signal != 0 { return .failed(.signal(signal)) }
        let exitCode = (status >> 8) & 0xFF
        return exitCode == 0 ? .completed(data) : .failed(.exit(exitCode))
    }
}

/// Monotonic seconds. Wall-clock changes cannot lengthen or shorten a command.
private enum MonotonicTime {
    static var now: TimeInterval {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return TimeInterval(time.tv_sec) + (TimeInterval(time.tv_nsec) / 1_000_000_000)
    }
}

/// One retained owner for direct children that did not become waitable inside
/// the caller's teardown budget. It never waits for non-child descendants.
private final class DeferredChildReaper: @unchecked Sendable {
    static let shared = DeferredChildReaper()

    private let queue = DispatchQueue(label: "pasqualotto.baia.git-reaper", qos: .utility)
    private let timer: DispatchSourceTimer
    private var children: Set<pid_t> = []

    private init() {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.reapAvailableChildren() }
        timer.resume()
    }

    func adopt(_ pid: pid_t) {
        queue.async { self.children.insert(pid) }
    }

    private func reapAvailableChildren() {
        for pid in children {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result == -1 && errno == ECHILD) {
                children.remove(pid)
            }
        }
    }
}
