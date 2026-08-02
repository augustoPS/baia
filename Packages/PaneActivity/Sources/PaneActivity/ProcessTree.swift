import Darwin
import Foundation

/// Impure. The only type here that touches the kernel.
///
/// Built on one `sysctl(KERN_PROC_ALL)` read whose parent pointers are then
/// walked, rather than on `proc_listchildpids` once per level.
/// `proc_listchildpids` was measured and rejected: it returns a *count* clamped
/// to whatever buffer it was handed, with no ENOMEM and no errno to distinguish
/// a truncated answer from a complete one. Asked for `launchd`'s children with
/// a 128 slot buffer it returned exactly 128, and with a 1 slot buffer exactly
/// 1. A silently short child list drops the agent out of the tree and reports
/// the pane idle, which is the single failure this package exists to avoid.
///
/// One `KERN_PROC_ALL` costs about 0.3 ms for the 900 processes on this
/// machine, affordable on a one second poll, and it is one consistent view
/// rather than a per-level walk that races the processes it is enumerating.
public enum ProcessTree {
    /// Every descendant of `pid`, inclusive. Empty when `pid` is not running.
    public static func snapshot(under pid: pid_t) -> [ProcessSnapshot] {
        let all = allProcesses()
        var children: [pid_t: [Int]] = [:]
        for (index, process) in all.enumerated() {
            children[process.kp_eproc.e_ppid, default: []].append(index)
        }

        // Breadth first, with a visited set. Parent pointers inside one
        // consistent snapshot should not form a cycle, but pid 0 is genuinely
        // its own parent on this machine, so the set is load bearing the moment
        // anyone passes 0 and it costs one hash per process to hold.
        var visited: Set<pid_t> = [pid]
        var queue = [pid]
        var reached: [Int] = []
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            for index in children[current] ?? [] {
                let child = all[index].kp_proc.p_pid
                guard visited.insert(child).inserted else { continue }
                reached.append(index)
                queue.append(child)
            }
        }

        // The root's own entry, which the children map cannot supply because it
        // is keyed by parent. Absent when `pid` has already exited, and then
        // the whole result is empty, which the classifier reads as an idle
        // pane.
        if let index = all.firstIndex(where: { $0.kp_proc.p_pid == pid }) {
            reached.insert(index, at: 0)
        }

        let boot = bootSeconds()
        return reached.map { snapshot(of: all[$0], bootSeconds: boot) }
    }

    /// Every process on the machine, as one `sysctl` read.
    ///
    /// The size query and the fetch are two syscalls, so processes can be
    /// created in between and the fetch can come back with no room. The kernel
    /// signals that with ENOMEM and, measured here, a reported size of 0 rather
    /// than a partial buffer. So the buffer carries slack over the reported
    /// size and the pair retries, with more slack each time. Measured: the
    /// first attempt has been enough every time, because the kernel's own
    /// reported size already runs about 20 slots ahead of the live process
    /// count.
    ///
    /// Four failures in a row returns empty, which reads as an idle pane for
    /// one poll. That is the right degradation: the next poll is a second away,
    /// and the alternative is a loop that keeps retrying while the machine
    /// forks faster than `sysctl` can enumerate.
    private static func allProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        for attempt in 1 ... 4 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
            let slots = size / stride + 16 * attempt
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: slots)
            var read = slots * stride
            guard sysctl(&mib, 4, &buffer, &read, nil, 0) == 0 else { continue }
            return Array(buffer.prefix(read / stride))
        }
        return []
    }

    /// Fills in the per-pid fields the bulk snapshot does not carry.
    private static func snapshot(of process: kinfo_proc, bootSeconds: Double?) -> ProcessSnapshot {
        let pid = process.kp_proc.p_pid
        let arguments = argumentVector(of: pid)
        return ProcessSnapshot(
            pid: pid,
            parentPid: process.kp_eproc.e_ppid,
            name: name(of: process),
            // The exec path when `KERN_PROCARGS2` gave one, `proc_pidpath`
            // otherwise. That order matters and is not a preference: for the
            // live Claude Code, the exec path is `~/.local/bin/claude` and
            // identifies the agent, while `proc_pidpath` resolves the symlink
            // to `~/.local/share/claude/versions/2.1.220` and identifies
            // nothing.
            executablePath: arguments?.executablePath ?? path(of: pid),
            arguments: arguments?.values ?? [],
            startedAtSecondsSinceBoot: bootSeconds.map { startSeconds(of: process) - $0 }
        )
    }

    /// `p_comm`, bounded by `strnlen`.
    ///
    /// The field is a fixed 17 bytes and `String(cString:)` trusts NUL
    /// termination, so a name that fills it exactly would send the read on past
    /// the field into the rest of the struct. `strnlen` bounds it to the field,
    /// the same way `ProcessWorkingDirectory` bounds `vip_path`.
    private static func name(of process: kinfo_proc) -> String {
        var process = process
        return withUnsafeBytes(of: &process.kp_proc.p_comm) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            let length = strnlen(base.assumingMemoryBound(to: CChar.self), raw.count)
            return String(decoding: raw.prefix(length), as: UTF8.self)
        }
    }

    /// The resolved binary behind a pid, as the fallback identifier.
    ///
    /// `proc_pidpath` reads across users, measured: it returns `/sbin/launchd`
    /// for pid 1 while `KERN_PROCARGS2` refuses that same pid. So it is the
    /// fallback rather than the primary precisely because it always answers,
    /// and what it answers is the real file rather than the path that was
    /// exec'd.
    private static func path(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        // Measured: the return value is the byte count written, excluding the
        // NUL, and 0 on failure with errno ESRCH for a pid that is not running.
        // Taking that count means no terminator has to be trusted, and clamping
        // it to the buffer keeps a kernel that ever over-reports from reading
        // past the end.
        guard written > 0 else { return nil }
        return String(decoding: buffer.prefix(min(Int(written), buffer.count)), as: UTF8.self)
    }

    /// `KERN_PROCARGS2`'s exec path and argv, or nil when it is unavailable.
    ///
    /// It refuses a process owned by another user. Measured: `sysctl` on
    /// `launchd` returns EINVAL rather than a partial answer, and so does a pid
    /// that is not running. No entitlement changes that, and baia is
    /// unsandboxed already so there is nothing to ask for. It is cheap to live
    /// with, because a pane's processes are the user's own: ghostty spawns the
    /// shell through `login -flp`, which drops root. The honest consequence is
    /// that `arguments` is empty for every system process a pane's tree happens
    /// to contain, and classification falls back to
    /// ``ProcessSnapshot/executablePath`` for those.
    private static func argumentVector(of pid: pid_t) -> (executablePath: String?, values: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let prefix = MemoryLayout<Int32>.size
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > prefix else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        var read = size
        guard sysctl(&mib, 3, &buffer, &read, nil, 0) == 0, read > prefix else { return nil }

        var count = Int32(0)
        withUnsafeMutableBytes(of: &count) { destination in
            for offset in 0 ..< destination.count { destination[offset] = buffer[offset] }
        }

        var index = prefix
        let execStart = index
        while index < read, buffer[index] != 0 { index += 1 }
        let executablePath = String(decoding: buffer[execStart ..< index], as: UTF8.self)

        // The exec path is followed by alignment padding of one or more NULs
        // before argv[0] begins, so this has to be a loop rather than a single
        // increment.
        while index < read, buffer[index] == 0 { index += 1 }

        // The environment sits in this same buffer, immediately after argv, and
        // is deliberately never parsed. It carries API keys and session tokens
        // for every process in the pane, and nothing here needs it: the pane
        // identity that `BAIA_PANE` would confirm is already known, since baia
        // is asking about a pid it spawned itself.
        var values: [String] = []
        var start = index
        while index < read, values.count < Int(max(count, 0)) {
            if buffer[index] == 0 {
                values.append(String(decoding: buffer[start ..< index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        return (executablePath.isEmpty ? nil : executablePath, values)
    }

    /// The pane's shell: the nearest shell at or above `pid`.
    ///
    /// Passing the foreground pid as the shell instead is the obvious mistake
    /// and it fails silently. `PaneActivityClassifier.classify` excludes the
    /// shell by pid and looks only below it, so a pane running `sleep` would
    /// report the sleep as its own shell, find nothing beneath, and read as
    /// idle forever. The tell is a pane that never labels anything while
    /// plainly running something.
    public static func shellPid(above pid: pid_t, in tree: [ProcessSnapshot]) -> pid_t? {
        let byPid = Dictionary(tree.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var current = pid
        // Bounded rather than trusting the parent chain to terminate. These
        // pointers come from one kernel snapshot and should form a tree, but a
        // loop here would hang the main thread on a poll timer.
        for _ in 0 ..< 64 {
            guard let process = byPid[current] else { return nil }
            if PaneActivityClassifier.shellNames.contains(normalized(process.name)) {
                return process.pid
            }
            current = process.parentPid
        }
        return nil
    }

    /// A login shell presents itself as `-zsh`, and the leading hyphen is a
    /// convention rather than part of the name.
    private static func normalized(_ name: String) -> String {
        name.hasPrefix("-") ? String(name.dropFirst()) : name
    }

    /// Wall clock seconds at boot, from `KERN_BOOTTIME`.
    private static func bootSeconds() -> Double? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0,
              size == MemoryLayout<timeval>.size
        else { return nil }
        return seconds(boot)
    }

    /// Wall clock seconds at which a process started, from `p_starttime`.
    ///
    /// Subtracting boot time from this is why the reported value counts time
    /// the machine spent asleep. Measured on this machine: the subtraction
    /// gives 70215 s, `mach_continuous_time` gives 70222 s, and
    /// `mach_absolute_time` gives 18810 s, so it tracks continuous time rather
    /// than awake time.
    ///
    /// The alternative was `proc_pid_rusage`'s `ri_proc_start_abstime`, a
    /// genuine mach timestamp. Rejected on measurement: it is one more per-pid
    /// syscall for a value the bulk snapshot already carries, and it fails with
    /// EPERM on a process owned by another user, so it would return nil in
    /// exactly the places where `KERN_PROC_ALL` still knows the answer.
    private static func startSeconds(of process: kinfo_proc) -> Double {
        seconds(process.kp_proc.p_starttime)
    }

    private static func seconds(_ time: timeval) -> Double {
        Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
    }
}
