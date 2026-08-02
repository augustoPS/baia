import Darwin
import Foundation
import Testing

@testable import PaneActivity

@Suite final class ProcessTreeTests {
    let fixture: ChildProcessFixture

    init() throws {
        fixture = try ChildProcessFixture()
    }

    @Test func includesTheProcessItWasAskedAbout() {
        // The root's entry comes from a separate lookup, because the children
        // map is keyed by parent and so can never yield the root. Dropping that
        // lookup leaves a tree that starts one level too low.
        #expect(ProcessTree.snapshot(under: getpid()).contains { $0.pid == getpid() })
    }

    @Test func returnsNothingForAPidThatIsNotRunning() {
        #expect(ProcessTree.snapshot(under: pid_t(999_999)).isEmpty)
    }

    @Test func readsItsOwnArgumentsAndExecutablePath() {
        let mine = ProcessTree.snapshot(under: getpid()).first { $0.pid == getpid() }

        #expect(mine?.arguments.isEmpty == false)
        // An absolute path is what pins the `KERN_PROCARGS2` parse. The buffer
        // opens with a four byte argc, so a parse that started at offset 0 or
        // skipped the padding wrongly would still produce a non-empty string,
        // just one beginning mid-path or mid-integer.
        #expect(mine?.executablePath?.hasPrefix("/") == true)
        #expect(mine?.name.isEmpty == false)
    }

    @Test func reportsNoArgumentsForAProcessOwnedByAnotherUser() {
        // `launchd` runs as root and `KERN_PROCARGS2` refuses it with EINVAL,
        // while `proc_pidpath` answers for it. This is the fallback firing in
        // exactly the place the two calls disagree, and the reason
        // `executablePath` is not simply the exec field.
        let launchd = ProcessTree.snapshot(under: pid_t(1)).first { $0.pid == 1 }

        #expect(launchd?.arguments.isEmpty == true)
        #expect(launchd?.executablePath == "/sbin/launchd")
    }

    @Test func startTimeIsMeasuredFromBootRatherThanFromTheEpoch() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let uptime = Double(mach_continuous_time()) * Double(timebase.numer)
            / Double(timebase.denom) / 1e9
        let mine = ProcessTree.snapshot(under: getpid()).first { $0.pid == getpid() }

        // Forgetting to subtract `KERN_BOOTTIME` leaves a raw epoch timestamp
        // around 1.78e9, which no uptime on a machine that reboots can reach.
        // The upper bound is what makes this test fail rather than pass
        // trivially.
        #expect((mine?.startedAtSecondsSinceBoot ?? -1) > 0)
        #expect((mine?.startedAtSecondsSinceBoot ?? .greatestFiniteMagnitude) < uptime)
    }

    @Test func enumeratingFromPidZeroTerminates() {
        // pid 0 is genuinely its own parent on this machine, so it is the
        // shortest possible cycle and the one the visited set exists for.
        // Without the set the queue never drains and the test hangs rather than
        // failing, so reaching the expectation is the assertion.
        let tree = ProcessTree.snapshot(under: pid_t(0))

        #expect(tree.contains { $0.pid == 1 })
        #expect(tree.filter { $0.pid == 0 }.count == 1)
    }

    @Test func findsAChildAndTheGrandchildBelowIt() {
        // Two levels down from the test process, and only the first level's pid
        // was ever knowable here. The grandchild is what proves the walk
        // recurses rather than listing one level, which is what the rejected
        // `proc_listchildpids` shape would have done per call.
        let tree = fixture.tree(under: getpid()) { tree in
            tree.contains { $0.parentPid == self.fixture.childPid }
        }

        #expect(tree.contains { $0.pid == self.fixture.childPid })
        #expect(tree.contains { $0.parentPid == self.fixture.childPid && $0.name == "sleep" })
    }

    @Test func classifiesALiveShellRunningACommand() {
        // The end to end path: real syscalls, a real tree, through the pure
        // classifier. Rooted at the fixture's own shell rather than at the test
        // process, so whatever else the test runner happens to spawn cannot
        // decide the answer.
        let tree = fixture.tree(under: fixture.childPid) { tree in
            tree.contains { $0.name == "sleep" }
        }

        let activity = PaneActivityClassifier.classify(tree: tree, shellPid: fixture.childPid)
        #expect(activity == .command(name: "sleep"))
    }

    // MARK: - shellPid

    private func process(
        pid: pid_t,
        parent: pid_t,
        name: String
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid,
            parentPid: parent,
            name: name,
            executablePath: nil,
            arguments: [],
            startedAtSecondsSinceBoot: nil
        )
    }

    @Test func theAnswerIsTheAncestorShellNotTheForegroundProcessItself() {
        // The mistake `shellPid`'s own doc comment names: passing the foreground
        // pid back out as if it were the shell. A pane running `sleep` under its
        // real shell must resolve to the shell above it, not to `sleep`'s own
        // pid, or `classify`'s shell exclusion would exclude the wrong process
        // and the pane would read as idle forever.
        let shell = process(pid: 100, parent: 10, name: "zsh")
        let foreground = process(pid: 101, parent: 100, name: "sleep")

        let found = ProcessTree.shellPid(above: 101, in: [shell, foreground])

        #expect(found == 100)
    }

    @Test func aCycleInTheParentPointersTerminatesWithoutFindingAShell() {
        // No process here is a shell, so a correct walk exhausts its bound and
        // answers nil. An unbounded walk following these parent pointers would
        // instead spin forever, freezing the poll timer that calls this.
        let first = process(pid: 200, parent: 201, name: "make")
        let second = process(pid: 201, parent: 200, name: "make")

        let found = ProcessTree.shellPid(above: 200, in: [first, second])

        #expect(found == nil)
    }
}
