import Foundation

/// Why a filesystem watch asked the observer to read again.
///
/// Ordinary working-tree writes still invalidate status and the tree, so porcelain
/// and Files stay in step. They do not discard a known default branch: that
/// answer changes when refs move, not when a file is saved. Gitdir metadata,
/// dropped-event rescans and an explicit refresh relearn it.
public enum RepositoryInvalidation: Sendable, Equatable {
    /// A write under the worktree. Status and tree, keeping a known default branch.
    case workingTree
    /// Per-worktree HEAD/index, common refs, or a dropped/root-change rescan.
    case metadata

    /// One pending slot: metadata wins so a refs event in the same burst is not
    /// lost inside a storm of working-tree writes.
    public func merging(_ other: RepositoryInvalidation) -> RepositoryInvalidation {
        if self == .metadata || other == .metadata { return .metadata }
        return .workingTree
    }
}
