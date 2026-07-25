import Foundation

/// One process as the kernel describes it, flattened into a value that the pure
/// classifier can be driven from.
///
/// Every field degrades rather than failing. `KERN_PROCARGS2` refuses a process
/// owned by another user with EINVAL, and a process is free to exit between the
/// bulk snapshot and the per-pid reads that follow it. Neither is exceptional on
/// a one second poll, so nothing here throws and a field that could not be read
/// arrives as nil or empty.
public struct ProcessSnapshot: Sendable, Equatable {
    public var pid: pid_t
    public var parentPid: pid_t
    /// Short name, for example `node`. Truncated by the kernel, so never assume
    /// it is complete.
    ///
    /// `p_comm` is a 17 byte field, so 16 characters survive:
    /// `com.apple.iCloud` in a snapshot of this machine is really
    /// `com.apple.iCloudHelper`. Worse for the case this package exists for, a
    /// program may rewrite it at will. Claude Code 2.1.220 reports `2.1.220`,
    /// its own version, so the agent baia most needs to recognise is the one
    /// this field never names.
    public var name: String
    /// Full argv[0] path when obtainable. A `claude` installed as a node script
    /// has a *name* of `node`, so only the path or the arguments identify it.
    ///
    /// Sourced from `KERN_PROCARGS2`'s exec field when that is readable, and
    /// from `proc_pidpath` otherwise. The two disagree and the first is the
    /// better identifier: for the Claude Code measured here, the exec field is
    /// `~/.local/bin/claude` while `proc_pidpath` resolves the symlink to
    /// `~/.local/share/claude/versions/2.1.220`.
    public var executablePath: String?
    /// argv, empty for a process this user does not own and for one that zeroes
    /// it. `/usr/bin/login` does the latter, which is why `login` has to be
    /// recognisable from ``name`` alone.
    public var arguments: [String]
    /// Seconds between boot and this process's start, or nil when boot time
    /// could not be read.
    ///
    /// Here for a status bar that wants to say how long a build has been
    /// running. ``PaneActivityClassifier`` deliberately ignores it: ordering
    /// two same depth siblings by start time would make the pane's label depend
    /// on which of them won a fork race, which is no more meaningful than
    /// ordering them by pid and is nil for a process whose boot time read
    /// failed.
    public var startedAtSecondsSinceBoot: Double?

    public init(
        pid: pid_t,
        parentPid: pid_t,
        name: String,
        executablePath: String?,
        arguments: [String],
        startedAtSecondsSinceBoot: Double?
    ) {
        self.pid = pid
        self.parentPid = parentPid
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
        self.startedAtSecondsSinceBoot = startedAtSecondsSinceBoot
    }
}
