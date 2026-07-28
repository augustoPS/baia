import Foundation

/// One changed path, in the shape a list needs.
///
/// The deliberate opposite of ``RepositoryStatus``, which holds counts and no paths
/// because the footer it feeds is one line that must not wrap. This is what the
/// footer cannot say: the footer reports `*3 ?1`, and this names which three files
/// are dirty and which one is untracked. Neither type is a better version of the
/// other and neither should grow into it, because the reason each exists is the
/// surface it is rendered on.
public struct RepositoryFileChange: Sendable, Equatable {
    /// Which porcelain v2 record the path came from.
    ///
    /// Kept rather than derived from the two columns, because untracked and
    /// unmerged both have to be distinguishable from an ordinary change that
    /// happens to have the same columns, and a caller that has to reconstruct
    /// "was this a `u` record" from `UU` is a caller that will one day get it
    /// wrong.
    public enum Kind: Sendable, Equatable {
        /// A `1` record: an ordinary add, modify, delete or type change.
        case ordinary
        /// A `2` record. Both are one kind because the distinction between them is
        /// already in ``RepositoryFileChange/index``, as `R` or `C`, and a second
        /// place to say it is a second place for the two to disagree.
        case renamedOrCopied
        /// A `u` record. Its columns are `UU`, `AA`, `DU` and friends, and it is
        /// never both staged and unstaged, whatever the columns look like.
        case unmerged
        /// A `?` record. Neither column carries a state.
        case untracked
    }

    /// What one column of `XY` says about a path.
    ///
    /// `.` is absent rather than a case: an unmodified column is the absence of a
    /// change, and giving it a name invites a caller to render it.
    public enum State: Character, Sendable, Equatable, CaseIterable {
        case modified = "M"
        case added = "A"
        case deleted = "D"
        case renamed = "R"
        case copied = "C"
        case typeChanged = "T"
        /// Only ever seen on a ``Kind/unmerged`` record.
        case unmerged = "U"
    }

    /// Where the file is now. For a rename, the new path.
    public let path: String

    /// Where a renamed or copied file was, and nil for everything else.
    ///
    /// Separated from ``path`` by a tab in the record rather than by a space, which
    /// is the detail that makes a rename vanish from any parse that splits the line
    /// on whitespace.
    public let originalPath: String?

    /// The `X` column: what is staged.
    public let index: State?

    /// The `Y` column: what is changed in the worktree and not staged.
    public let worktree: State?

    public let kind: Kind

    public init(
        path: String,
        originalPath: String? = nil,
        index: State? = nil,
        worktree: State? = nil,
        kind: Kind
    ) {
        self.path = path
        self.originalPath = originalPath
        self.index = index
        self.worktree = worktree
        self.kind = kind
    }
}
