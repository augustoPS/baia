import Darwin
import Foundation
import Testing

@testable import GitWorkspace

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

@Suite(.serialized) final class BoundedGitCommandTests {
    let fixture: DirectoryFixture

    init() throws {
        fixture = try DirectoryFixture()
    }

    @Test func aHungLeaderTimesOutAndIsReapedAndTheNextReadSucceeds() throws {
        let pidFile = fixture.root.appending(path: "hung.pid")
        let executable = try helper(
            named: "hung-git",
            body: """
            if [ "$1" = "hang" ]; then
                echo $$ > "$2"
                trap '' TERM
                while :; do sleep 1; done
            fi
            printf 'recovered'
            """
        )
        let command = command(executable, limits: limits(deadline: 0.15))
        let pipesBefore = openPipeDescriptors()
        let started = ProcessInfo.processInfo.systemUptime

        let outcome = command.run(["hang", pidFile.path], in: fixture.root)

        #expect(outcome == .timedOut)
        #expect(ProcessInfo.processInfo.systemUptime - started < 1.0)
        try expectProcessGone(recordedAt: pidFile)
        expectNoLingeringPipes(since: pipesBefore)
        for _ in 0 ..< 3 {
            #expect(command.run([], in: fixture.root) == .completed(Array("recovered".utf8)))
        }
        expectNoLingeringPipes(since: pipesBefore)
    }

    /// **Descriptor isolation, observed from inside the child.** A descriptor the
    /// test leaves inheritable is not seen by the helper, and neither is anything
    /// else: the child lists exactly its own stdio, plus the one descriptor the
    /// listing itself opens. This is `POSIX_SPAWN_CLOEXEC_DEFAULT` at work for
    /// launches this type makes; it says nothing about launches other code makes
    /// in the window between `pipe` and `fcntl`, which `GitCommand` records as
    /// open.
    @Test func ourLaunchesInheritNoUnrelatedDescriptors() throws {
        // Descriptor numbers are per process: a child that starts with only its
        // stdio reuses 3 and 4 for whatever it opens itself, so a low number in
        // its listing says nothing. The inheritable descriptors are therefore
        // pinned to 200 and 201, numbers nothing in the helper opens on its own,
        // and `dup2` leaves them without close-on-exec, which is asserted.
        let file = open("/dev/null", O_RDONLY)
        try #require(file >= 0)
        defer { close(file) }
        var inheritablePipe: [Int32] = [-1, -1]
        try #require(pipe(&inheritablePipe) == 0)
        defer { close(inheritablePipe[0]); close(inheritablePipe[1]) }
        let leakedFile: Int32 = 200
        let leakedPipe: Int32 = 201
        try #require(dup2(file, leakedFile) == leakedFile)
        try #require(dup2(inheritablePipe[1], leakedPipe) == leakedPipe)
        defer { close(leakedFile); close(leakedPipe) }
        #expect(fcntl(leakedFile, F_GETFD) & FD_CLOEXEC == 0)
        #expect(fcntl(leakedPipe, F_GETFD) & FD_CLOEXEC == 0)

        let executable = try helper(named: "fd-list-git", body: "ls /dev/fd")
        let command = command(executable, limits: limits(deadline: 2))

        guard case let .completed(bytes) = command.run([], in: fixture.root) else {
            Issue.record("the listing helper did not complete")
            return
        }
        let listed = Set(
            String(decoding: bytes, as: UTF8.self)
                .split(whereSeparator: \.isWhitespace)
                .compactMap { Int32($0) }
        )

        #expect(listed.isSuperset(of: [0, 1, 2]))
        #expect(!listed.contains(leakedFile), "\(listed.sorted())")
        #expect(!listed.contains(leakedPipe), "\(listed.sorted())")
        // Beyond stdio, only the handles `ls` opens for itself to read `/dev/fd`,
        // which land on the lowest free numbers. A test process holds dozens of
        // descriptors above that, and none of them may reach the child.
        #expect(listed.allSatisfy { $0 < 8 }, "\(listed.sorted())")
    }

    /// **A child reaped by someone else is a typed wait failure, not an exit code.**
    /// The test stands in for a foreign reaper in the same process: it waits on the
    /// child's pid as soon as the helper reports it, so the store's own `waitpid`
    /// finds nothing. The next read must still succeed, since nothing was adopted
    /// or signalled on a pid that is no longer ours.
    ///
    /// The ordering is forced rather than raced. The leader exits at once while a
    /// descendant keeps stdout open for half a second, so the store cannot reach
    /// EOF, and therefore cannot reap, until the descendant lets go. The foreign
    /// waiter reaps the leader inside that half second. EOF then arrives, the
    /// store asks for a child that is no longer there, and the answer is typed.
    @Test func aChildReapedElsewhereIsATypedWaitFailureAndTheNextReadSucceeds() throws {
        let pidFile = fixture.root.appending(path: "foreign.pid")
        let executable = try helper(
            named: "foreign-reaped-git",
            body: """
            if [ "$1" = "linger" ]; then
                echo $$ > "$2"
                (sleep 0.5) &
                exit 0
            fi
            printf 'recovered'
            """
        )
        let command = command(executable, limits: limits(deadline: 5))
        let reapedByForeignWaiter = LockedFlag()
        let waiter = DispatchGroup()
        waiter.enter()
        Thread.detachNewThread {
            defer { waiter.leave() }
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            var pid: pid_t?
            while pid == nil, ProcessInfo.processInfo.systemUptime < deadline {
                if let text = try? String(contentsOf: pidFile, encoding: .utf8),
                   let parsed = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    pid = parsed
                } else {
                    usleep(1_000)
                }
            }
            guard let pid else { return }
            var status: Int32 = 0
            var result = waitpid(pid, &status, 0)
            while result == -1, errno == EINTR { result = waitpid(pid, &status, 0) }
            if result == pid { reapedByForeignWaiter.set() }
        }
        let started = ProcessInfo.processInfo.systemUptime

        let outcome = command.run(["linger", pidFile.path], in: fixture.root)

        #expect(waiter.wait(timeout: .now() + 5) == .success)
        #expect(reapedByForeignWaiter.isSet)
        #expect(outcome == .failed(.wait(ECHILD)))
        // Ended when the descendant released stdout, not at the deadline: nothing
        // was signalled or adopted for a pid that was no longer ours.
        #expect(ProcessInfo.processInfo.systemUptime - started < 3)
        for _ in 0 ..< 3 {
            #expect(command.run([], in: fixture.root) == .completed(Array("recovered".utf8)))
        }
    }

    @Test func aDescendantHoldingStdoutIsKilledWithItsLeaderGroup() throws {
        let leaderFile = fixture.root.appending(path: "leader.pid")
        let descendantFile = fixture.root.appending(path: "descendant.pid")
        let executable = try helper(
            named: "descendant-git",
            body: """
            echo $$ > "$1"
            (trap '' HUP TERM; sleep 600) &
            echo $! > "$2"
            exit 0
            """
        )
        let command = command(executable, limits: limits(deadline: 0.15))
        let started = ProcessInfo.processInfo.systemUptime

        let outcome = command.run(
            [leaderFile.path, descendantFile.path],
            in: fixture.root
        )

        #expect(outcome == .timedOut)
        #expect(ProcessInfo.processInfo.systemUptime - started < 1.0)
        try expectProcessGone(recordedAt: leaderFile)
        try expectProcessGone(recordedAt: descendantFile)
    }

    @Test func cancellationStopsTheGroupAndTheNextReadSucceeds() async throws {
        let pidFile = fixture.root.appending(path: "cancelled.pid")
        let executable = try helper(
            named: "cancellable-git",
            body: """
            if [ "$1" = "hang" ]; then
                echo $$ > "$2"
                trap '' TERM
                while :; do sleep 1; done
            fi
            printf 'recovered'
            """
        )
        let command = command(executable, limits: limits(deadline: 5))
        let cancellation = SubprocessCancellation()
        let root = fixture.root
        let task = Task.detached {
            command.run(["hang", pidFile.path], in: root, cancellation: cancellation)
        }
        try await Task.sleep(for: .milliseconds(100))
        let cancelledAt = ProcessInfo.processInfo.systemUptime

        cancellation.cancel()
        let outcome = await task.value

        #expect(outcome == .cancelled)
        #expect(ProcessInfo.processInfo.systemUptime - cancelledAt < 1.0)
        try expectProcessGone(recordedAt: pidFile)
        for _ in 0 ..< 3 {
            #expect(command.run([], in: fixture.root) == .completed(Array("recovered".utf8)))
        }
    }

    @Test func cancellationBeforeRunDoesNotSpawn() throws {
        let marker = fixture.root.appending(path: "spawned")
        let executable = try helper(
            named: "should-not-run-git",
            body: "echo ran > \"$1\""
        )
        let command = command(executable, limits: limits(deadline: 5))
        let cancellation = SubprocessCancellation()
        cancellation.cancel()

        #expect(command.run([marker.path], in: fixture.root, cancellation: cancellation) == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func anElapsedDeadlineDoesNotSpawn() throws {
        let marker = fixture.root.appending(path: "spawned-after-deadline")
        let executable = try helper(
            named: "expired-git",
            body: "echo ran > \"$1\""
        )
        let command = command(executable, limits: limits(deadline: 0))

        #expect(command.run([marker.path], in: fixture.root) == .timedOut)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func outputPastTheCapIsRejectedAndTheNextReadSucceeds() throws {
        let pidFile = fixture.root.appending(path: "flood.pid")
        let executable = try helper(
            named: "flood-git",
            body: """
            if [ "$1" = "flood" ]; then
                echo $$ > "$2"
                trap '' TERM
                while :; do printf '0123456789abcdef'; done
            fi
            printf 'recovered'
            """
        )
        let command = command(
            executable,
            limits: SubprocessLimits(deadline: 5, outputLimit: 1_024, terminationGrace: 0.05)
        )

        let outcome = command.run(["flood", pidFile.path], in: fixture.root)

        #expect(outcome == .tooMuchOutput)
        try expectProcessGone(recordedAt: pidFile)
        for _ in 0 ..< 3 {
            #expect(command.run([], in: fixture.root) == .completed(Array("recovered".utf8)))
        }
    }

    @Test func nonzeroExitAndSpawnFailureAreDistinct() throws {
        let nonzero = GitCommand(
            executablePath: "/bin/sh",
            fixedArguments: ["-c", "exit 23"],
            limits: limits(deadline: 1)
        )
        let missing = GitCommand(
            executablePath: fixture.root.appending(path: "missing-git").path,
            limits: limits(deadline: 1)
        )

        let pipesBefore = openPipeDescriptors()
        #expect(nonzero.run([], in: fixture.root) == .failed(.exit(23)))
        guard case let .failed(.spawn(error)) = missing.run([], in: fixture.root) else {
            Issue.record("missing executable did not return a spawn failure")
            return
        }
        #expect(error == ENOENT)
        #expect(nonzero.bytes(of: [], in: fixture.root) == nil)
        expectNoLingeringPipes(since: pipesBefore)
    }

    @Test func anUnexpectedSignalIsTyped() {
        let command = GitCommand(
            executablePath: "/bin/sh",
            fixedArguments: ["-c", "kill -KILL $$"],
            limits: limits(deadline: 1)
        )

        #expect(command.run([], in: fixture.root) == .failed(.signal(SIGKILL)))
    }

    @Test func normalGitAndTheCompatibilityWrapperReturnTheSameBytes() throws {
        let command = GitCommand(limits: limits(deadline: 2))

        guard case let .completed(typedBytes) = command.run(["--version"], in: fixture.root) else {
            Issue.record("normal git did not complete")
            return
        }

        #expect(String(decoding: typedBytes, as: UTF8.self).hasPrefix("git version "))
        #expect(command.bytes(of: ["--version"], in: fixture.root) == typedBytes)
    }

    private func limits(deadline: TimeInterval) -> SubprocessLimits {
        SubprocessLimits(deadline: deadline, outputLimit: 1 << 20, terminationGrace: 0.05)
    }

    private func command(_ script: URL, limits: SubprocessLimits) -> GitCommand {
        GitCommand(executablePath: "/bin/sh", fixedArguments: [script.path], limits: limits)
    }

    private func helper(named name: String, body: String) throws -> URL {
        let executable = try fixture.file(
            name,
            contents: """
            #!/bin/sh
            \(body)

            """
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path
        )
        return executable
    }

    private func expectProcessGone(recordedAt file: URL) throws {
        let text = try String(contentsOf: file, encoding: .utf8)
        let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while kill(pid, 0) == 0, ProcessInfo.processInfo.systemUptime < deadline {
            usleep(10_000)
        }
        let gone = kill(pid, 0) == -1 && errno == ESRCH
        #expect(gone)
        if !gone { _ = kill(pid, SIGKILL) }
    }

    /// Every open descriptor in this process that is a pipe end.
    ///
    /// Pipes rather than a total count: the only descriptors a run creates are
    /// its two pipe ends, and other suites run in parallel opening and closing
    /// files of their own, so a count can hide a leak behind someone else's
    /// close. Their pipes are transient too, which is what `expectNoLingeringPipes`
    /// relies on.
    private func openPipeDescriptors() -> Set<Int32> {
        var pipes: Set<Int32> = []
        for descriptor in 0 ..< Int32(1_024) {
            var information = stat()
            if fstat(descriptor, &information) == 0, information.st_mode & S_IFMT == S_IFIFO {
                pipes.insert(descriptor)
            }
        }
        return pipes
    }

    /// No pipe end opened since `before` is still open once the process has had a
    /// moment to settle. A pipe another suite's read holds right now closes within
    /// milliseconds; a pipe this suite's run leaked never does, so polling for two
    /// seconds tells the two apart without serialising the package.
    private func expectNoLingeringPipes(since before: Set<Int32>) {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var lingering = openPipeDescriptors().subtracting(before)
        while !lingering.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
            usleep(10_000)
            lingering = openPipeDescriptors().subtracting(before)
        }
        #expect(lingering.isEmpty, "pipe descriptors still open: \(lingering.sorted())")
    }
}
