import Foundation

/// Reads `git diff --raw --numstat -z`.
///
/// **Why `--raw` rides along with `--numstat`, when only the counts are
/// wanted.** Under `-z` a plain numstat record is `adds\tdeletes\tpath\0`.
/// A detected rename or copy is `adds\tdeletes\t` followed by *three* NUL
/// terminated entries: one empty field first, confirmed against a real
/// capture rather than assumed from the one-path shape, then the old path,
/// then the new path. Nothing marks that empty field as the start of a
/// two-path record rather than an ordinary record's answer trailing off
/// early, and nothing marks where a rename's own fields end and the next
/// record begins: no `=>`, no tab, no count. Read on its own, a parser
/// deciding by content, such as treating a path beginning with a digit or
/// `-` as the next record's count column, is wrong on the first real
/// repository with a file named `-README.txt` renamed from `1-notes.txt`:
/// that path opens with a binary-file marker and a digit respectively, and
/// either would be misread as a fresh record, truncating the rename. This is
/// not a hypothetical: an early version of this parser used exactly that
/// heuristic and a fixture built from a real `git mv 1weird.txt
/// -dashname.txt` broke it on the first try.
///
/// `--raw` computed in the same invocation is unambiguous by construction:
/// each record spends a status letter, `R` or `C` for a rename or copy and
/// anything else for one path, exactly the marker numstat lacks, in the same
/// order the diff engine produced both blocks. Reading the raw block first
/// gives, per record, the one piece of information the numstat block cannot
/// supply about itself: how many NUL terminated paths belong to it. One `git`
/// invocation, one parser, no guessing.
///
/// Bytes rather than a `String`, for the reason ``GitStatusParser`` gives:
/// decoding the capture before parsing it replaces a filesystem-legal but
/// non-UTF-8 path with U+FFFD before this grammar ever sees it, and that loss
/// is not reversible.
///
/// Kept free of any process running, like every other parser in this
/// package, so the grammar is testable on fixture bytes. ``GitCommand`` is
/// where a real `git diff --raw --numstat -z` invocation belongs once one is
/// wired.
public enum NumstatParser {
    private static let tab = UInt8(ascii: "\t")
    private static let space = UInt8(ascii: " ")
    private static let terminator: UInt8 = 0
    private static let colon = UInt8(ascii: ":")
    private static let binaryMarker = UInt8(ascii: "-")

    /// Parses combined `git diff --raw --numstat -z` output: a `:`-led raw
    /// record per file, all of them, followed by the numstat block for the
    /// same files in the same order.
    ///
    /// Order is git's own throughout, not sorted here.
    public static func parse(_ output: [UInt8]) -> [NumstatEntry] {
        var index = output.startIndex

        // The raw block's own job here is narrow: for each record, in
        // order, whether it carries one path or two. Nothing else about it
        // is kept, since the counts come from the numstat block that
        // follows and everything else the raw block carries (modes, blobs)
        // is not this parser's business.
        var pathCounts: [Int] = []
        while index < output.endIndex, output[index] == colon {
            guard let (count, next) = readRawRecord(output, from: index) else { break }
            pathCounts.append(count)
            index = next
        }

        var entries: [NumstatEntry] = []
        for pathCount in pathCounts {
            guard let (entry, next) = readNumstatRecord(output, from: index, pathCount: pathCount) else {
                break
            }
            entries.append(entry)
            index = next
        }

        return entries
    }

    /// One `:mode mode oldsha newsha STATUS\0path\0[path\0]` record.
    ///
    /// Returns the number of NUL terminated paths it carries (2 for a status
    /// beginning `R` or `C`, 1 otherwise) and the index just past it, or nil
    /// for a record that does not have this shape, which stops the whole
    /// parse rather than guess past malformed input.
    private static func readRawRecord(
        _ bytes: [UInt8], from start: Int
    ) -> (pathCount: Int, next: Int)? {
        // Four space separated fields (the colon-prefixed old mode, the new
        // mode, the old sha, the new sha) precede the status field, which is
        // NUL terminated rather than space terminated: unlike the others it
        // is not fixed width, since it carries a similarity score for a
        // rename or copy.
        var cursor = start
        for _ in 0 ..< 4 {
            guard let spaceIndex = bytes[cursor...].firstIndex(of: space) else { return nil }
            cursor = spaceIndex + 1
        }
        guard let statusEnd = bytes[cursor...].firstIndex(of: terminator) else { return nil }
        let status = bytes[cursor ..< statusEnd]
        let pathCount = (status.first == UInt8(ascii: "R") || status.first == UInt8(ascii: "C")) ? 2 : 1

        var next = statusEnd + 1
        for _ in 0 ..< pathCount {
            guard let pathEnd = bytes[next...].firstIndex(of: terminator) else { return nil }
            next = pathEnd + 1
        }
        return (pathCount, next)
    }

    /// One `adds\tdeletes\tpath\0` or `adds\tdeletes\t` + two NUL terminated
    /// paths, `pathCount` telling which shape to expect.
    private static func readNumstatRecord(
        _ bytes: [UInt8], from start: Int, pathCount: Int
    ) -> (entry: NumstatEntry, next: Int)? {
        guard let firstTab = bytes[start...].firstIndex(of: tab) else { return nil }
        let additionsField = bytes[start ..< firstTab]
        guard let secondTab = bytes[(firstTab + 1)...].firstIndex(of: tab) else { return nil }
        let deletionsField = bytes[(firstTab + 1) ..< secondTab]

        var cursor = secondTab + 1
        var paths: [ArraySlice<UInt8>] = []
        // A two-path record's paths are NUL terminated, like a one-path
        // record's, but they do not start immediately after the second tab:
        // git writes one empty NUL terminated field there first, every time,
        // confirmed against real output rather than assumed from the
        // one-path shape. `pathCount + 1` fields are read and the leading
        // empty one is dropped, rather than special-casing "the first field
        // is empty" as a signal, because an empty field is indistinguishable
        // from a rename into an empty string and this way never has to tell
        // the two apart.
        let fieldCount = pathCount == 2 ? 3 : 1
        for _ in 0 ..< fieldCount {
            guard let pathEnd = bytes[cursor...].firstIndex(of: terminator) else { return nil }
            paths.append(bytes[cursor ..< pathEnd])
            cursor = pathEnd + 1
        }
        if pathCount == 2 { paths.removeFirst() }

        let isBinary = additionsField.elementsEqual([binaryMarker])
            || deletionsField.elementsEqual([binaryMarker])
        let additions = isBinary ? nil : Int(text(additionsField))
        let deletions = isBinary ? nil : Int(text(deletionsField))

        let entry: NumstatEntry =
            if paths.count == 2 {
                NumstatEntry(
                    path: RepositoryPath(paths[1]),
                    originalPath: RepositoryPath(paths[0]),
                    additions: additions,
                    deletions: deletions
                )
            } else {
                NumstatEntry(path: RepositoryPath(paths[0]), additions: additions, deletions: deletions)
            }
        return (entry, cursor)
    }

    private static func text(_ field: ArraySlice<UInt8>) -> String {
        String(decoding: field, as: UTF8.self)
    }
}
