import Foundation

/// One working tree of a repository, as `git worktree list --porcelain` names it.
///
/// Worktrees are asked of git rather than found by walking, because the two
/// layouts on this machine (`.worktrees/<branch>-MMDD-HHMM` from superpowers and
/// `.claude/worktrees/agent-<hex>` from the Agent tool) are full file copies
/// inside the repository. Walking into them once made an admin vitest run report
/// three times the real test count.
public struct Worktree: Sendable, Equatable {
    public var url: URL
    public var head: String?
    public var branch: String?
    public var isBare: Bool
    public var isDetached: Bool
    public var isLocked: Bool
    public var isPrunable: Bool
    /// The first entry `git worktree list` emits is the main working tree.
    public var isMain: Bool

    /// Flags default to false and the two refs to nil, because a bare
    /// repository's stanza is one `worktree` line and a `bare` line with no
    /// `HEAD` at all, and a detached one has no `branch`. Requiring every field
    /// at every call site would push that absence onto the parser as sentinel
    /// values.
    public init(
        url: URL,
        head: String? = nil,
        branch: String? = nil,
        isBare: Bool = false,
        isDetached: Bool = false,
        isLocked: Bool = false,
        isPrunable: Bool = false,
        isMain: Bool = false
    ) {
        // Canonicalized the way ProjectAnchor's `Anchor` is, and for the same
        // reason: a URL built with a directory hint is not equal to one built
        // without it for the same path, so a worktree parsed here would compare
        // unequal to the same worktree built by a caller.
        self.url = URL(filePath: url.path(percentEncoded: false), directoryHint: .isDirectory)
        self.head = head
        self.branch = branch
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
        self.isPrunable = isPrunable
        self.isMain = isMain
    }

    /// The directory name, not the branch name.
    ///
    /// The branch is the tempting choice and it is strictly worse for both
    /// layouts here. `.claude/worktrees/agent-<hex>` sits on branch
    /// `worktree-agent-<hex>`, a longer spelling of the same hex, and
    /// `.worktrees/<branch>-MMDD-HHMM` carries the timestamp that tells two
    /// worktrees cut from one branch apart, which the branch name cannot. So the
    /// directory name is never the less informative of the two.
    public var displayName: String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path(percentEncoded: false) : name
    }
}
