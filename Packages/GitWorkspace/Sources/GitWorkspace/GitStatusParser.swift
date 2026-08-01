import Foundation

/// Reads `git status --porcelain=v2 --branch --untracked-files=all -z`.
///
/// v2 rather than v1 because v1 carries no machine-readable branch header, so
/// ahead and behind would cost a second `git rev-list` on every poll of every
/// pane. `--untracked-files=all` rather than the default `normal` because
/// `normal` collapses an untracked directory into one entry, which makes
/// `untracked` a count of entries rather than of files: two repositories showing
/// `?` would disagree about what the number behind it means.
///
/// **`-z`, which decides the whole shape of this grammar.** Without it git renders
/// any path holding a non-ASCII byte, a double quote, a backslash or a control
/// byte in C-style quoting, so `café.txt` arrives as the fifteen ASCII characters
/// `"caf\303\251.txt"` and a reader is handed a name no filesystem holds. `-z`
/// turns the quoting off and terminates every record with a NUL, which is the
/// only byte a path cannot contain. Two consequences run through everything
/// below: a newline is a path character rather than a separator, and a rename's
/// original path is an entry of its own rather than a field after a tab.
///
/// **Bytes rather than a `String`, which is the other half of `-z`.** The flag
/// stops the quoting and hands over whatever the filesystem holds, and a
/// repository cloned from a filesystem that allowed a name APFS would refuse
/// carries paths that are not UTF-8. Decoding the capture before parsing it
/// replaces those bytes with U+FFFD, irreversibly, before this grammar ever sees
/// them. So the split, the field boundaries and the markers are all byte work, and
/// only the fields git spells itself, a branch name or an oid, become text.
///
/// Kept free of any process running so the whole grammar can be tested on
/// fixture bytes. ``GitCommand`` composes the two.
public enum GitStatusParser {
    /// The first byte of a record, which is what says how to read the rest.
    private enum Marker {
        static let header = UInt8(ascii: "#")
        static let ordinary = UInt8(ascii: "1")
        static let renamedOrCopied = UInt8(ascii: "2")
        static let unmerged = UInt8(ascii: "u")
        static let untracked = UInt8(ascii: "?")
        static let ignored = UInt8(ascii: "!")
    }

    private static let separator = UInt8(ascii: " ")
    private static let terminator: UInt8 = 0
    private static let unmodified = UInt8(ascii: ".")

    /// A field git wrote itself, as text.
    ///
    /// Only ever called on a field that is git's own vocabulary: a header name, an
    /// oid, a branch name, a pair of status columns. A path never goes through here,
    /// which is the whole point of the type it goes into instead.
    private static func text(_ field: ArraySlice<UInt8>) -> String {
        String(decoding: field, as: UTF8.self)
    }
    /// Parses `git status --porcelain=v2 --branch --untracked-files=all`.
    ///
    /// Nil when the output carries no branch header, which is what `git status`
    /// outside a work tree and an empty string both look like. A caller that got
    /// nil should show no git information at all rather than a zeroed status,
    /// since a repository that is genuinely clean and a directory that is not a
    /// repository render identically otherwise.
    public static func parse(_ output: [UInt8]) -> RepositoryStatus? {
        var oid: String?
        var headName: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var staged = 0
        var unstaged = 0
        var untracked = 0
        var conflicted = 0

        // The original path a rename carries is dropped here rather than read,
        // but it still has to be taken off the stream by ``records(_:)``: it is a
        // path, so `? evil.txt` is a legal one, and left loose it would be counted
        // as an untracked file that does not exist.
        for record in records(output).map(\.text) {
            guard let marker = record.first else { continue }

            switch marker {
            case Marker.header:
                guard let header = fields(record, count: 3) else { continue }
                switch text(header[1]) {
                case "branch.oid":
                    oid = text(header[2])
                case "branch.head":
                    headName = text(header[2])
                case "branch.upstream":
                    upstream = text(header[2])
                case "branch.ab":
                    // Read by sign rather than by position, so a future git that
                    // emits them the other way round does not silently swap
                    // ahead with behind. The two look the same on a clean
                    // branch, which is where such a swap would go unnoticed.
                    for token in text(header[2]).split(separator: " ") {
                        if token.hasPrefix("+") { ahead = Int(token.dropFirst()) ?? 0 }
                        if token.hasPrefix("-") { behind = Int(token.dropFirst()) ?? 0 }
                    }
                default:
                    // `# stash 2` appears with `--show-stash`, and git is free
                    // to add more headers. An unknown one is not a parse
                    // failure.
                    continue
                }
            case Marker.ordinary:
                guard let entry = fields(record, count: 9) else { continue }
                count(statusColumns: entry[1], staged: &staged, unstaged: &unstaged)
            case Marker.renamedOrCopied:
                guard let entry = fields(record, count: 10) else { continue }
                count(statusColumns: entry[1], staged: &staged, unstaged: &unstaged)
            case Marker.unmerged:
                guard fields(record, count: 11) != nil else { continue }
                // Unmerged paths land in `conflicted` and nowhere else. Their XY
                // is `UU`, `AA`, `DU` and friends, so reading the two columns
                // the way an ordinary change is read would count one conflicted
                // file as staged and unstaged as well, and the counts would
                // claim three problems where there is one.
                conflicted += 1
            case Marker.untracked:
                guard fields(record, count: 2) != nil else { continue }
                untracked += 1
            case Marker.ignored:
                // An ignored path counts as nothing. It only appears with
                // `--ignored`, which this command does not pass, and counting it
                // as untracked would put a permanent `?` on any repository with
                // a build directory.
                continue
            default:
                continue
            }
        }

        guard let oid, let headName else { return nil }

        let head: RepositoryStatus.Head
        if oid == "(initial)" {
            // Checked before `(detached)`. The two cannot co-occur in git today,
            // since an unborn HEAD is by definition a symbolic ref to a branch,
            // and ordering it this way means a repository that somehow reports
            // both is called unborn rather than detached: the branch name is the
            // more useful of the two answers.
            head = .unborn(headName)
        } else if headName == "(detached)" {
            head = .detached(commit: oid)
        } else {
            head = .branch(headName)
        }

        if upstream == nil {
            // `# branch.ab` is absent without an upstream, so these are already
            // zero. Forced anyway so a truncated capture or a hand-built fixture
            // cannot report a divergence against an upstream that does not
            // exist, which would render as `↑3` beside a branch with nowhere to
            // push.
            ahead = 0
            behind = 0
        }

        return RepositoryStatus(
            head: head,
            upstream: upstream,
            ahead: ahead,
            behind: behind,
            staged: staged,
            unstaged: unstaged,
            untracked: untracked,
            conflicted: conflicted
        )
    }

    /// The same output read as a list of paths rather than as counts.
    ///
    /// A second pass over the same string rather than a second return value from
    /// ``parse(_:)``, and rather than paths added to ``RepositoryStatus``. The
    /// status feeds a one-line footer and says so on its own doc comment; widening
    /// it to carry paths would put them in reach of the caller that must not render
    /// them. The cost of the extra pass is a walk over one repository's status
    /// output, which is already in memory because the status read fetched it.
    ///
    /// An empty array for a clean repository *and* for a directory that is not a
    /// repository, unlike ``parse(_:)``, which separates those with nil. The
    /// distinction is not this function's to make: a caller reaching for a file
    /// list has already asked for the status and learned which it has.
    ///
    /// Order is git's own, which is by path within each record type.
    public static func changes(_ output: [UInt8]) -> [RepositoryFileChange] {
        var changes: [RepositoryFileChange] = []

        for entry in records(output) {
            let record = entry.text
            guard let marker = record.first else { continue }

            switch marker {
            case Marker.ordinary:
                guard let fields = fields(record, count: 9) else { continue }
                let (index, worktree) = states(fields[1])
                changes.append(RepositoryFileChange(
                    path: RepositoryPath(fields[8]),
                    index: index,
                    worktree: worktree,
                    kind: .ordinary
                ))
            case Marker.renamedOrCopied:
                guard let fields = fields(record, count: 10) else { continue }
                let (index, worktree) = states(fields[1])
                // The tenth field is the path alone. The original path was taken
                // off the stream by ``records(_:)``, because under `-z` it is a
                // NUL terminated entry of its own rather than a field after a
                // tab, and a path may contain a tab.
                changes.append(RepositoryFileChange(
                    path: RepositoryPath(fields[9]),
                    originalPath: entry.originalPath.map(RepositoryPath.init),
                    index: index,
                    worktree: worktree,
                    kind: .renamedOrCopied
                ))
            case Marker.unmerged:
                guard let fields = fields(record, count: 11) else { continue }
                let (index, worktree) = states(fields[1])
                changes.append(RepositoryFileChange(
                    path: RepositoryPath(fields[10]),
                    index: index,
                    worktree: worktree,
                    kind: .unmerged
                ))
            case Marker.untracked:
                guard let fields = fields(record, count: 2) else { continue }
                changes.append(RepositoryFileChange(
                    path: RepositoryPath(fields[1]),
                    kind: .untracked
                ))
            default:
                // Headers and `!` ignored records both land here. An ignored path
                // is not a change, for the reason the counting pass gives: it
                // appears only under `--ignored`, and treating it as untracked
                // would put every build directory in the list.
                continue
            }
        }

        return changes
    }

    /// One record, with the original path a rename or a copy carries.
    private struct Record {
        let text: ArraySlice<UInt8>
        /// The entry that followed a `2` record, and nil for every other kind.
        let originalPath: ArraySlice<UInt8>?
    }

    /// The capture split into records at its NUL bytes, with a rename's original
    /// path attached to the record that owns it.
    ///
    /// **The attachment is the point, not a convenience.** Under `-z` git writes a
    /// rename as two entries: the record, then the original path. That path is a
    /// path, so a file really can be called `? evil.txt`, and an entry loop that
    /// took every entry for a record would read it as an untracked file that
    /// nothing on disk matches. Consuming it here is what makes both passes safe
    /// from a name chosen to look like a record.
    ///
    /// Empty subsequences are kept, so the trailing NUL after the last record does
    /// not vanish and cannot be mistaken for a missing terminator. An empty entry
    /// carries no marker, so both passes skip it. An empty entry standing where a
    /// rename's original path should be is that terminator rather than a path,
    /// which is why it becomes nil rather than "".
    private static func records(_ output: [UInt8]) -> [Record] {
        let entries = output.split(separator: terminator, omittingEmptySubsequences: false)
        var records: [Record] = []
        var index = entries.startIndex

        while index < entries.endIndex {
            let entry = entries[index]
            index += 1
            // Taken off the stream even when the record turns out to be malformed
            // below. git wrote the pair, so the entry after a `2` belongs to it
            // whatever shape the record is in.
            guard entry.first == Marker.renamedOrCopied, index < entries.endIndex else {
                records.append(Record(text: entry, originalPath: nil))
                continue
            }
            let following = entries[index]
            index += 1
            records.append(Record(text: entry, originalPath: following.isEmpty ? nil : following))
        }

        return records
    }

    /// `XY` as two optional states, where `.` becomes nil.
    ///
    /// Nil rather than a case, because an unmodified column is the absence of a
    /// change and a named value for it is a value someone will draw.
    private static func states(
        _ columns: ArraySlice<UInt8>
    ) -> (index: RepositoryFileChange.State?, worktree: RepositoryFileChange.State?) {
        guard columns.count == 2 else { return (nil, nil) }
        var bytes = columns.makeIterator()
        guard let index = bytes.next(), let worktree = bytes.next() else {
            return (nil, nil)
        }
        // The columns are git's own alphabet and every letter in it is ASCII, so a
        // byte is a character here and the conversion cannot lose anything.
        return (
            RepositoryFileChange.State(rawValue: Character(UnicodeScalar(index))),
            RepositoryFileChange.State(rawValue: Character(UnicodeScalar(worktree)))
        )
    }

    /// `XY` is two status characters: `X` is the index column, `Y` the worktree
    /// column, and `.` means unmodified in that column.
    ///
    /// One file increments both counters when both columns are set, which is the
    /// ordinary result of staging a change and then editing the file again.
    /// Counting each record once is the obvious wrong implementation and it
    /// under-reports exactly the state the owner most needs to see before
    /// committing.
    private static func count(
        statusColumns columns: ArraySlice<UInt8>,
        staged: inout Int,
        unstaged: inout Int
    ) {
        guard columns.count == 2 else { return }
        var bytes = columns.makeIterator()
        guard let index = bytes.next(), let worktree = bytes.next() else { return }
        if index != unmodified { staged += 1 }
        if worktree != unmodified { unstaged += 1 }
    }

    /// Splits a record into exactly `count` space separated fields, or nil when
    /// it has any other shape.
    ///
    /// Two things here are load-bearing. The split is bounded, so the last field
    /// keeps the rest of the record: a path containing a space would otherwise
    /// produce ten fields for an ordinary change and be rejected as malformed,
    /// which would silently stop counting a file named `old name.txt`. And the
    /// separator is a literal space rather than "any whitespace", because a tab
    /// is a legal character in a filename and `-z` delivers it raw: a file called
    /// `ctrl<TAB>name.txt` would otherwise split into an extra field and be
    /// rejected as malformed.
    ///
    /// Empty subsequences are kept. Dropping them would make the same bounded
    /// split forgiving of a record with a missing field, and a malformed record
    /// should be ignored rather than counted from whatever fields happened to
    /// line up.
    private static func fields(_ record: ArraySlice<UInt8>, count: Int) -> [ArraySlice<UInt8>]? {
        let parts = record.split(
            separator: separator,
            maxSplits: count - 1,
            omittingEmptySubsequences: false
        )
        return parts.count == count ? parts : nil
    }
}
