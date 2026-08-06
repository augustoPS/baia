import Foundation

/// One file's line counts from `git diff --raw --numstat`.
///
/// The deliberate companion to ``RepositoryFileChange``, which names a changed
/// path but carries no count: that type is built from `git status`, which
/// never reports how many lines moved, only that some did. This is built from
/// a second, cheaper read over the same paths, and it is kept as its own type
/// rather than folded into ``RepositoryFileChange`` for the same reason
/// ``RepositoryStatus`` and that type stay apart: each is shaped for the read
/// that produces it, and merging them would make one command's absence look
/// like the other's zero.
public struct NumstatEntry: Sendable, Equatable {
    /// Where the file is now, as git wrote it. For a rename, the new path.
    ///
    /// Bytes rather than text, for the reason ``RepositoryPath`` gives: git
    /// reports whatever the filesystem holds, and this is the path a lookup
    /// against ``RepositoryFileChange/rawPath`` has to match byte for byte.
    public let rawPath: RepositoryPath

    /// Where a renamed or copied file was, and nil for everything else.
    public let rawOriginalPath: RepositoryPath?

    /// What a row draws, lossy for a path that is not UTF-8. See
    /// ``RepositoryPath/display``.
    public var path: String { rawPath.display }

    public var originalPath: String? { rawOriginalPath?.display }

    /// Lines added, or nil for a binary file.
    ///
    /// Nil rather than zero: `git diff --numstat` prints `-` for a binary
    /// file because it did not count, not because it counted zero, and a
    /// caller that collapsed the two would draw `+0 -0` beside an image that
    /// was replaced wholesale.
    public let additions: Int?

    /// Lines deleted, or nil for a binary file. See ``additions``.
    public let deletions: Int?

    public init(
        path: RepositoryPath,
        originalPath: RepositoryPath? = nil,
        additions: Int?,
        deletions: Int?
    ) {
        rawPath = path
        rawOriginalPath = originalPath
        self.additions = additions
        self.deletions = deletions
    }
}
