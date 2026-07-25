import Darwin
import Foundation

@testable import PaneActivity

/// A live two level process tree under the test process.
///
/// `/bin/sh -c "sleep 30 & wait"` is chosen for its shape rather than for what
/// it does. The `&` makes `sleep` a grandchild of the test process instead of
/// an exec'd replacement for the shell, and the `wait` keeps the shell alive
/// holding it. A plain `sh -c "sleep 30"` would have `sh` exec straight into
/// `sleep` and flatten to one level, which is the level a single
/// `proc_listchildpids` call would already have found.
///
/// No mock of the kernel exists here and none is wanted. The real syscalls
/// against a real tree this fixture spawned are the only honest test of
/// ``ProcessTree``, the same way `DirectoryFixture` tests the locator against a
/// real directory.
final class ChildProcessFixture {
    let childPid: pid_t
    private let child = Process()

    init() throws {
        child.executableURL = URL(filePath: "/bin/sh")
        child.arguments = ["-c", "sleep 30 & wait"]
        try child.run()
        childPid = child.processIdentifier
    }

    deinit {
        // Guarded, because `terminate()` on a Process that has already exited
        // raises rather than returning, and a 30 second sleep can still lose to
        // a machine under load taking longer than that to finish the suite.
        if child.isRunning { child.terminate() }
    }

    /// Polls `ProcessTree.snapshot(under:)` until `predicate` holds or the
    /// budget runs out, and returns the last read either way.
    ///
    /// Spawning is asynchronous: `Process.run` returns as soon as the shell
    /// exists, which is before the shell has forked its own child, so a single
    /// read races the grandchild into being. Returning the last read on timeout
    /// rather than looping forever keeps a slow machine to a failing test
    /// instead of a hung one.
    func tree(under pid: pid_t, until predicate: ([ProcessSnapshot]) -> Bool) -> [ProcessSnapshot] {
        var latest = ProcessTree.snapshot(under: pid)
        var attempts = 0
        while !predicate(latest), attempts < 150 {
            usleep(20_000)
            latest = ProcessTree.snapshot(under: pid)
            attempts += 1
        }
        return latest
    }
}
