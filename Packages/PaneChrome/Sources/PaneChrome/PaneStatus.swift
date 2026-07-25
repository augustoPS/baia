import Foundation

/// Everything one pane's status bar shows, already reduced to display values.
///
/// Nothing here is read from disk or from a process. The git counts arrive
/// computed, the operation label arrives formatted, and the working directory
/// arrives abbreviated, which is what keeps this package free of AppKit, of git,
/// and of any test that needs a repository on disk.
public struct PaneStatus: Sendable, Equatable {
    /// A pane's git facts, in the vocabulary of the owner's own statusline
    /// (`claude-dotfiles/statusline/ps1-style.sh`): `↑` ahead, `↓` behind, `*`
    /// dirty, `?` untracked. Reusing that vocabulary rather than inventing one
    /// means the bar reads the same as the prompt he already scans.
    public struct Git: Sendable, Equatable {
        /// The branch name, or whatever the caller decided to show for a
        /// detached HEAD. The statusline shows a parenthesised short SHA there,
        /// and this type takes it verbatim rather than reformatting it.
        public var head: String

        /// False for a detached HEAD and for a branch whose upstream was
        /// deleted. ``PaneStatusSegments`` then drops ``ahead`` and ``behind``,
        /// because with no upstream to count against they are stale numbers
        /// rather than zeroes.
        public var hasUpstream: Bool

        public var ahead: Int
        public var behind: Int
        public var dirty: Bool
        public var untracked: Int

        /// Unmerged paths. Non-zero forces the indicators segment to
        /// ``PaneStatusEmphasis/alert``, since a conflicted tree is the one git
        /// state where running the next command makes things worse.
        public var conflicted: Int

        /// Already-formatted operation label, for example `REBASE 1/3`, or nil.
        /// The caller formats it because only the caller can read
        /// `.git/rebase-merge/msgnum`, and a half-parsed operation shown as
        /// `REBASE` with no position is worse than the label the caller built.
        public var operation: String?

        /// True when the pane sits in a linked worktree rather than the main
        /// checkout. Two incompatible worktree layouts are in daily use here
        /// (`.worktrees/<branch>-MMDD-HHMM` from superpowers and
        /// `.claude/worktrees/agent-<hex>` from the Agent tool), and running a
        /// command in the wrong one of them is a recorded, repeated mistake.
        public var isLinkedWorktree: Bool

        public init(
            head: String,
            hasUpstream: Bool,
            ahead: Int,
            behind: Int,
            dirty: Bool,
            untracked: Int,
            conflicted: Int,
            operation: String?,
            isLinkedWorktree: Bool
        ) {
            self.head = head
            self.hasUpstream = hasUpstream
            self.ahead = ahead
            self.behind = behind
            self.dirty = dirty
            self.untracked = untracked
            self.conflicted = conflicted
            self.operation = operation
            self.isLinkedWorktree = isLinkedWorktree
        }
    }

    /// What is running in the pane, and whether it asked for the owner.
    public struct Agent: Sendable, Equatable {
        public var label: String

        /// Set from the pane's bell or OSC 9 notification, not from a guess
        /// about the process tree. The signal it replaces is a single
        /// `afplay Blow.aiff` on the Stop hook, identical for every session, so
        /// with four or five panes open it says something finished and nothing
        /// about which.
        public var wantsAttention: Bool

        public init(label: String, wantsAttention: Bool) {
            self.label = label
            self.wantsAttention = wantsAttention
        }
    }

    /// The anchor's display name.
    public var anchorName: String

    /// True when the anchor is a git repository. A plain directory emits no git
    /// segments at all, even when ``git`` is non-nil.
    public var anchorIsRepository: Bool

    public var isPinned: Bool

    /// Tilde-abbreviated working directory, shown only when it differs from the
    /// anchor. Build it with ``workingDirectory(ofShellAt:anchoredAt:home:)``
    /// rather than by hand, which is where the "differs from the anchor" half of
    /// that rule lives: this type holds the anchor's *name*, not its path, so it
    /// cannot make the comparison itself.
    public var workingDirectory: String?

    public var git: Git?
    public var agent: Agent?

    public init(
        anchorName: String,
        anchorIsRepository: Bool,
        isPinned: Bool,
        workingDirectory: String?,
        git: Git?,
        agent: Agent?
    ) {
        self.anchorName = anchorName
        self.anchorIsRepository = anchorIsRepository
        self.isPinned = isPinned
        self.workingDirectory = workingDirectory
        self.git = git
        self.agent = agent
    }

    /// The value for ``workingDirectory``: nil when the shell sits at the
    /// anchor, otherwise the shell's directory with `home` abbreviated to `~`.
    ///
    /// Nil rather than the anchor's own path, because a pane whose shell has not
    /// left the project root would otherwise spend the widest trailing segment
    /// restating what the leading segment already says.
    ///
    /// - Parameter home: passed in rather than read from
    ///   `FileManager.default.homeDirectoryForCurrentUser`, so the abbreviation
    ///   is a pure function of its arguments and the tests do not depend on
    ///   whose machine they run on.
    public static func workingDirectory(
        ofShellAt directory: String,
        anchoredAt anchor: String,
        home: String
    ) -> String? {
        let shell = trimmingTrailingSlashes(directory)
        guard shell != trimmingTrailingSlashes(anchor) else { return nil }
        guard !shell.isEmpty else { return nil }

        let root = trimmingTrailingSlashes(home)
        guard !root.isEmpty else { return shell }
        if shell == root { return "~" }

        // The prefix has to end at a path boundary. `/Users/gu` against
        // `/Users/gutao/p` matches as a plain string prefix and would abbreviate
        // to `~tao/p`, a path that does not exist and cannot be pasted anywhere.
        guard shell.hasPrefix(root + "/") else { return shell }
        return "~" + shell.dropFirst(root.count)
    }

    /// Drops trailing slashes so `/a/b` and `/a/b/` compare equal. Leaves a
    /// lone `/` alone, since a shell really can sit at the root.
    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
