import Foundation

/// Everything the workspace knows about one repository, as one value.
///
/// Published whole, on the main actor, by ``RepositoryObserver``, and replaced
/// whole: no field is ever assigned on its own, so a surface reading two fields
/// from one snapshot reads two fields the observer published together. A surface
/// reads the fields it renders from one snapshot and never starts work of its
/// own, which is what stops a redraw from becoming a read.
///
/// **Latest known, not same moment.** The status and the tree are read on
/// separate cadences by separate processes, so ``status`` and ``changes`` are
/// the newest status read that answered and ``tree`` is the newest tree read
/// that answered, each with its own state: ``health`` for the status read and
/// ``TreeState`` for the tree. A tree read can succeed while the status read
/// times out, and the snapshot then carries a fresh tree beside a kept status
/// whose health says it is stale. What is atomic is the publication, and what
/// is guaranteed is that no field comes from a superseded root or a superseded
/// request generation.
///
/// **Equality is over the rendered fields only.** ``generation`` and ``readAt``
/// are excluded: a poll that found nothing new must not redraw anything, and both
/// of those move on every completed read. Everything else counts, including the
/// path identities in ``changes``: a rename keeps every aggregate count and the
/// branch equal while the paths change, and that is a change the sidebar draws.
public struct RepositorySnapshot: Sendable {
    /// The observed root. Its ``RepositoryRoot/url`` is the first spelling a
    /// subscriber used for this identity.
    public let root: RepositoryRoot

    /// Monotonic per root, incremented on every publication. A reader holding a
    /// newer generation can discard this one. Not compared.
    public let generation: UInt64

    /// When the last successful status read completed, or nil before one has.
    /// Not compared.
    public let readAt: Date?

    /// The last successfully read status, kept across a timed-out or failed read
    /// (``health`` says so), and cleared when the root stops being a repository.
    public let status: RepositoryStatus?

    /// The changed paths from the same read as ``status``.
    public let changes: [RepositoryFileChange]

    /// What is known about the repository's default branch.
    public let defaultBranch: DefaultBranchState

    /// Whether the root is a linked worktree rather than a main checkout.
    public let isLinkedWorktree: Bool

    /// The file tree, on its own cadence and with its own states.
    public let tree: TreeState

    /// How the last status read went.
    public let health: ReadHealth

    public init(
        root: RepositoryRoot,
        generation: UInt64,
        readAt: Date?,
        status: RepositoryStatus?,
        changes: [RepositoryFileChange],
        defaultBranch: DefaultBranchState,
        isLinkedWorktree: Bool,
        tree: TreeState,
        health: ReadHealth
    ) {
        self.root = root
        self.generation = generation
        self.readAt = readAt
        self.status = status
        self.changes = changes
        self.defaultBranch = defaultBranch
        self.isLinkedWorktree = isLinkedWorktree
        self.tree = tree
        self.health = health
    }

    public enum DefaultBranchState: Sendable, Equatable {
        /// Not read yet, or the read did not answer.
        case unresolved
        /// Read. Nil means no remote has ever said, which is a real answer that
        /// must not be asked again on every poll. Both answers are re-read on an
        /// explicit refresh or a metadata invalidation, which is when a remote
        /// can have been added or its HEAD moved; ordinary polling keeps them.
        case known(String?)
    }

    /// The tree's lifecycle, stored rather than inferred from an optional.
    ///
    /// `.empty` and `.failed` are the R08 repair: a cache that forgot an empty or
    /// failed read was asked again by the very redraw its completion caused, and
    /// looped for as long as the root was shown.
    public enum TreeState: Sendable, Equatable {
        /// No read has landed. Draws as nothing, not as an empty repository.
        case unread
        /// A read landed and the repository holds no files. Stored, so it is not
        /// re-requested by a redraw.
        case empty
        /// A read landed and the repository holds these files. Never an empty
        /// array; that is `.empty`.
        case loaded([FileTreeNode])
        /// The last read failed this way, after this many consecutive attempts.
        /// The observer retries on a bounded backoff that continues at its cap.
        case failed(RepositoryReadFailure, attempts: Int)

        /// The rows a surface draws: nothing for unread, empty or failed.
        public var nodes: [FileTreeNode] {
            if case let .loaded(nodes) = self { return nodes }
            return []
        }
    }

    /// Whether the last status read answered, and how.
    public enum ReadHealth: Sendable, Equatable {
        /// No status read has landed yet.
        case unread
        /// The last status read answered.
        case ok
        /// The last status read failed this way, after this many consecutive
        /// attempts. `.notARepository` here means the root is gone or is no
        /// longer a repository; ``status`` is nil in that case and kept as the
        /// last good value in every other.
        case failed(RepositoryReadFailure, attempts: Int)
    }

    /// Whether the head is the branch this repository is normally on.
    ///
    /// True while nothing is known, which keeps an unresolved pane showing a bare
    /// project name rather than flashing a branch for one poll. A detached head
    /// is never the default. With no recorded default, the conventional names
    /// decide, exactly as ``DefaultBranchResolver/isDefaultBranch(_:ofRepositoryRoot:)``
    /// decides them.
    public var isOnDefaultBranch: Bool {
        guard let status else { return true }
        switch status.head {
        case .detached:
            return false
        case let .branch(name), let .unborn(name):
            switch defaultBranch {
            case let .known(recorded?):
                return name == recorded
            case .known(nil), .unresolved:
                return DefaultBranchResolver.isConventionalDefault(name)
            }
        }
    }

    /// True when the root stopped being a repository or stopped existing.
    public var isGone: Bool {
        if case .failed(.notARepository, _) = health { return true }
        return false
    }
}

extension RepositorySnapshot: Equatable {
    /// Rendered fields only. See the type's documentation for why
    /// ``generation`` and ``readAt`` stay out.
    public static func == (lhs: RepositorySnapshot, rhs: RepositorySnapshot) -> Bool {
        lhs.root == rhs.root
            && lhs.status == rhs.status
            && lhs.changes == rhs.changes
            && lhs.defaultBranch == rhs.defaultBranch
            && lhs.isLinkedWorktree == rhs.isLinkedWorktree
            && lhs.tree == rhs.tree
            && lhs.health == rhs.health
    }
}
