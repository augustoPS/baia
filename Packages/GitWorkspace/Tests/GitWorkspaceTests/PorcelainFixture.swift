import Foundation

/// Builds a `git status --porcelain=v2 -z` capture from a readable listing.
///
/// Under `-z` every record ends in a NUL and nothing ends in a newline, which
/// makes a fixture written as one long escaped string unreadable and therefore
/// unreviewable. The fixtures here are written as lines and joined with NUL,
/// which is the only difference between them and the bytes git printed.
///
/// A rename's original path is its own NUL terminated entry rather than a
/// trailing field, so it appears in these listings as the line after the record
/// it belongs to. That is git's layout, not a convenience of this helper.
enum PorcelainFixture {
    /// The listing with every newline replaced by a NUL, as bytes.
    ///
    /// Empty subsequences are kept, so a listing ending in a newline produces the
    /// trailing NUL git writes after its last record.
    ///
    /// Bytes rather than a `String`, because that is what the parser now reads and
    /// what git actually writes. A listing that can be typed is UTF-8 by
    /// construction; a path that is not has to be appended as bytes, which is what
    /// ``bytes(_:)`` is for.
    static func zeroed(_ listing: String) -> [UInt8] {
        Array(
            listing
                .split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: "\0")
                .utf8
        )
    }

    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
}
