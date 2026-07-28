import Foundation

/// Decides when a repository's file tree is worth reading again.
///
/// Extracted from the app so the rule can be tested without a window, a pane, or
/// Metal. The rule is the whole feature: reading a tree is a `git ls-files` over
/// every tracked and untracked path in the repository, and the sidebar asks for one
/// every time focus moves. Focus moves several times a second while someone arrows
/// across a grid of panes, so a cache that answers "read it" too eagerly forks git
/// at that rate for an answer that is almost always the one already held.
///
/// Keyed by repository root rather than by pane. Two panes in the same repository
/// are two askers of one question, and a per-pane cache would read the same tree
/// once for each of them.
public struct FileTreeCache: Sendable {
    private var trees: [URL: [FileTreeNode]] = [:]

    /// Roots whose read is out. Held separately from ``trees`` because a read in
    /// flight has no answer yet and must still suppress a second one: without this,
    /// a focus change arriving while the first read is running starts another, which
    /// is exactly the case a busy grid produces.
    private var inFlight: Set<URL> = []

    public init() {}

    /// What to draw for `root` right now, which is nothing until a read lands.
    public func tree(for root: URL) -> [FileTreeNode]? { trees[root] }

    /// Whether the caller should start a read.
    ///
    /// Mutating, and deliberately: asking is what claims the read. Two callers
    /// asking in the same turn must not both be told yes, and a separate
    /// `shouldRead` plus `markStarted` would leave the gap between them open.
    public mutating func claimRead(of root: URL) -> Bool {
        guard trees[root] == nil, !inFlight.contains(root) else { return false }
        inFlight.insert(root)
        return true
    }

    /// Records a landed read.
    public mutating func store(_ tree: [FileTreeNode], for root: URL) {
        inFlight.remove(root)
        trees[root] = tree
    }

    /// Records a read that produced nothing.
    ///
    /// The root leaves ``inFlight`` without entering ``trees``, so the next ask
    /// claims a fresh read rather than being refused forever by a failure. A
    /// repository that was mid-clone, or a directory that stopped being one, is a
    /// case that resolves itself, and a cache that never retried would need a
    /// relaunch to notice.
    public mutating func forget(_ root: URL) {
        inFlight.remove(root)
    }

    /// Drops a root's answer so the next ask re-reads it.
    ///
    /// Nothing calls this on a timer. A file tree changes when a file is created or
    /// deleted, which no poll here observes, so this is the hook a future refresh
    /// command uses rather than a staleness rule pretending to be one.
    public mutating func invalidate(_ root: URL) {
        trees[root] = nil
    }
}
