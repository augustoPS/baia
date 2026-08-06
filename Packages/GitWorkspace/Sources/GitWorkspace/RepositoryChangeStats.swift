import Foundation

/// One repository's line counts, in the shape the sidebar's `CHANGED` header
/// and rows need: per-file counts for the rows, and totals for the header,
/// from one `git diff --raw --numstat` read.
///
/// The deliberate companion to ``RepositoryStatus``, which counts files and
/// never lines. Kept as its own type rather than a field added there for the
/// reason the doc comment on that type already gives for staying a count and
/// not a list: the two reads answer different questions and neither caller
/// needs the other's answer.
public struct RepositoryChangeStats: Sendable, Equatable {
    public let entries: [NumstatEntry]

    public init(entries: [NumstatEntry]) {
        self.entries = entries
    }

    /// The sum of every entry's ``NumstatEntry/additions``, binary files
    /// contributing nothing rather than being read as zero-and-summed. A
    /// repository whose only change is a replaced image therefore totals to
    /// zero, which is correct: nothing to report about lines, not nothing to
    /// report about files.
    public var totalAdditions: Int {
        entries.reduce(0) { $0 + ($1.additions ?? 0) }
    }

    public var totalDeletions: Int {
        entries.reduce(0) { $0 + ($1.deletions ?? 0) }
    }

    /// The entry for a path, matched on ``NumstatEntry/rawPath`` rather than
    /// the drawn spelling, so a lookup keyed on ``RepositoryFileChange/rawPath``
    /// finds the same file even where the two are not valid UTF-8.
    public func entry(forPath path: RepositoryPath) -> NumstatEntry? {
        entries.first { $0.rawPath == path }
    }
}
