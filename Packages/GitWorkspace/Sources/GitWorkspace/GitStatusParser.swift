import Foundation

/// Reads `git status --porcelain=v2 --branch --untracked-files=all`.
///
/// v2 rather than v1 because v1 carries no machine-readable branch header, so
/// ahead and behind would cost a second `git rev-list` on every poll of every
/// pane. `--untracked-files=all` rather than the default `normal` because
/// `normal` collapses an untracked directory into one entry, which makes
/// `untracked` a count of entries rather than of files: two repositories showing
/// `?` would disagree about what the number behind it means.
///
/// Kept free of any process running so the whole grammar can be tested on
/// fixture strings. ``GitCommand`` composes the two.
public enum GitStatusParser {
    /// Parses `git status --porcelain=v2 --branch --untracked-files=all`.
    ///
    /// Nil when the output carries no branch header, which is what `git status`
    /// outside a work tree and an empty string both look like. A caller that got
    /// nil should show no git information at all rather than a zeroed status,
    /// since a repository that is genuinely clean and a directory that is not a
    /// repository render identically otherwise.
    public static func parse(_ output: String) -> RepositoryStatus? {
        var oid: String?
        var headName: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var staged = 0
        var unstaged = 0
        var untracked = 0
        var conflicted = 0

        // Split on any newline rather than on "\n". A CRLF pair is a single
        // `Character` in Swift, so splitting on "\n" does not split a CRLF stream
        // at all: the whole capture arrives as one line, no header is recognised,
        // and the parse returns nil for output that is perfectly well formed.
        // `isNewline` is true for that pair, for a lone return, and for a lone
        // feed, which covers every spelling this can be handed.
        for record in output.split(whereSeparator: \.isNewline) {
            guard let marker = record.first else { continue }

            switch marker {
            case "#":
                guard let header = fields(record, count: 3) else { continue }
                switch header[1] {
                case "branch.oid":
                    oid = String(header[2])
                case "branch.head":
                    headName = String(header[2])
                case "branch.upstream":
                    upstream = String(header[2])
                case "branch.ab":
                    // Read by sign rather than by position, so a future git that
                    // emits them the other way round does not silently swap
                    // ahead with behind. The two look the same on a clean
                    // branch, which is where such a swap would go unnoticed.
                    for token in header[2].split(separator: " ") {
                        if token.hasPrefix("+") { ahead = Int(token.dropFirst()) ?? 0 }
                        if token.hasPrefix("-") { behind = Int(token.dropFirst()) ?? 0 }
                    }
                default:
                    // `# stash 2` appears with `--show-stash`, and git is free
                    // to add more headers. An unknown one is not a parse
                    // failure.
                    continue
                }
            case "1":
                guard let entry = fields(record, count: 9) else { continue }
                count(statusColumns: entry[1], staged: &staged, unstaged: &unstaged)
            case "2":
                guard let entry = fields(record, count: 10) else { continue }
                count(statusColumns: entry[1], staged: &staged, unstaged: &unstaged)
            case "u":
                guard fields(record, count: 11) != nil else { continue }
                // Unmerged paths land in `conflicted` and nowhere else. Their XY
                // is `UU`, `AA`, `DU` and friends, so reading the two columns
                // the way an ordinary change is read would count one conflicted
                // file as staged and unstaged as well, and the counts would
                // claim three problems where there is one.
                conflicted += 1
            case "?":
                guard fields(record, count: 2) != nil else { continue }
                untracked += 1
            case "!":
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

    /// `XY` is two status characters: `X` is the index column, `Y` the worktree
    /// column, and `.` means unmodified in that column.
    ///
    /// One file increments both counters when both columns are set, which is the
    /// ordinary result of staging a change and then editing the file again.
    /// Counting each record once is the obvious wrong implementation and it
    /// under-reports exactly the state the owner most needs to see before
    /// committing.
    private static func count(
        statusColumns columns: Substring,
        staged: inout Int,
        unstaged: inout Int
    ) {
        guard columns.count == 2 else { return }
        var characters = columns.makeIterator()
        guard let index = characters.next(), let worktree = characters.next() else { return }
        if index != "." { staged += 1 }
        if worktree != "." { unstaged += 1 }
    }

    /// Splits a record into exactly `count` space separated fields, or nil when
    /// it has any other shape.
    ///
    /// Two things here are load-bearing. The split is bounded, so the last field
    /// keeps the rest of the line: a path containing a space would otherwise
    /// produce ten fields for an ordinary change and be rejected as malformed,
    /// which would silently stop counting a file named `old name.txt`. And the
    /// separator is a literal space rather than "any whitespace", because a
    /// rename record ends in `<path>TAB<origPath>`: treating that tab as a
    /// separator yields eleven fields where ten are expected, so every rename
    /// would vanish from the counts.
    ///
    /// Empty subsequences are kept. Dropping them would make the same bounded
    /// split forgiving of a record with a missing field, and a malformed record
    /// should be ignored rather than counted from whatever fields happened to
    /// line up.
    private static func fields(_ record: Substring, count: Int) -> [Substring]? {
        let parts = record.split(
            separator: " ",
            maxSplits: count - 1,
            omittingEmptySubsequences: false
        )
        return parts.count == count ? parts : nil
    }
}
