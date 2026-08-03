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

    /// Where the file is now, as git wrote it. For a rename, the new path.
    ///
    /// Bytes rather than text, because a path is bytes: see ``RepositoryPath``. This
    /// is the only spelling that names the file, so it is what a click would have to
    /// send.
    ///
    /// **This is what the picker sends.** `Sources/ChangesSurface.swift` and
    /// `Sources/FilesSurface.swift` hand it to `onSelect`, `PromptPath.resolve`
    /// takes the bytes, and `TerminalPaneController.send` writes them through
    /// `sendBytes`, so the route from git's index to the pty decodes nothing.
    ///
    /// The rule that leaves: ``path`` draws, ``rawPath`` names. A new call site
    /// that has to identify a file, rather than show one, wants this. Two known
    /// places still identify by ``path`` and collapse two files onto one entry
    /// because of it, `FileChangeMarks.marks` and the sidebar's expanded-directory
    /// set; both are tracked and neither is on this route.
    public let rawPath: RepositoryPath

    /// Where a renamed or copied file was, and nil for everything else.
    ///
    /// Its own NUL terminated entry under `-z` rather than a field after a tab,
    /// which is the detail that makes a rename vanish from any parse that splits the
    /// record on whitespace.
    public let rawOriginalPath: RepositoryPath?

    /// What a row draws, which is lossy for a path that is not UTF-8.
    ///
    /// Derived rather than stored, so it cannot drift from ``rawPath``.
    public var path: String { rawPath.display }

    /// The drawn spelling of ``rawOriginalPath``, lossy for the same reason.
    public var originalPath: String? { rawOriginalPath?.display }

    /// The `X` column: what is staged.
    public let index: State?

    /// The `Y` column: what is changed in the worktree and not staged.
    public let worktree: State?

    public let kind: Kind

    /// Labelled for what they are rather than for how they are spelled, so a call
    /// site reads the same as it did when both were `String`s. A literal still
    /// works, since a path a caller can type has a text spelling.
    public init(
        path: RepositoryPath,
        originalPath: RepositoryPath? = nil,
        index: State? = nil,
        worktree: State? = nil,
        kind: Kind
    ) {
        rawPath = path
        rawOriginalPath = originalPath
        self.index = index
        self.worktree = worktree
        self.kind = kind
    }
}
