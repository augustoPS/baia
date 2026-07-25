import Foundation

/// Reads `git worktree list --porcelain`.
public enum GitWorktreeParser {
    /// Parses `git worktree list --porcelain`.
    ///
    /// The output is blank-line separated stanzas, each opening with
    /// `worktree <path>`. Returns an empty array rather than nil for output it
    /// cannot use: every caller here wants to iterate the result, and a
    /// repository with no linked worktrees and a failed read are the same thing
    /// to a palette.
    public static func parse(_ output: String) -> [Worktree] {
        var worktrees: [Worktree] = []
        var path: String?
        var head: String?
        var branch: String?
        var isBare = false
        var isDetached = false
        var isLocked = false
        var isPrunable = false

        func flush() {
            guard let opened = path else { return }
            worktrees.append(
                Worktree(
                    url: URL(filePath: opened, directoryHint: .isDirectory),
                    head: head,
                    branch: branch,
                    isBare: isBare,
                    isDetached: isDetached,
                    isLocked: isLocked,
                    isPrunable: isPrunable,
                    // The main working tree is the first stanza git emits, which
                    // is the only way to tell it apart: its own stanza carries
                    // no marker saying so.
                    isMain: worktrees.isEmpty
                )
            )
            path = nil
            head = nil
            branch = nil
            isBare = false
            isDetached = false
            isLocked = false
            isPrunable = false
        }

        // Empty subsequences are kept, because the blank line between stanzas is
        // the record separator. Dropping it would merge every stanza into one
        // worktree carrying the last path and the first branch.
        //
        // Split on any newline rather than on "\n", because a CRLF pair is a single
        // `Character` in Swift: splitting on "\n" leaves a CRLF capture as one line
        // and the parse finds one worktree whose path swallows the rest of the
        // output.
        for line in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.isEmpty {
                flush()
                continue
            }
            if let value = value(of: line, field: "worktree") {
                // A stanza opened without the previous one closing means the
                // blank line was lost, which happens to any output that has been
                // through a text editor or a log. Flushing here keeps that from
                // collapsing two worktrees into one.
                flush()
                path = value
            } else if let value = value(of: line, field: "HEAD") {
                head = value
            } else if let value = value(of: line, field: "branch") {
                // Shortened from `refs/heads/<name>`. A status bar showing
                // `refs/heads/main` wastes eleven columns of a one-line bar on
                // every pane.
                branch = value.hasPrefix(Self.branchRefPrefix)
                    ? String(value.dropFirst(Self.branchRefPrefix.count))
                    : value
            } else if isFlag(line, "bare") {
                isBare = true
            } else if isFlag(line, "detached") {
                isDetached = true
            } else if isFlag(line, "locked") {
                isLocked = true
            } else if isFlag(line, "prunable") {
                isPrunable = true
            }
        }
        flush()
        return worktrees
    }

    private static let branchRefPrefix = "refs/heads/"

    /// The value of `field <value>`, or nil when the line is a different field.
    ///
    /// Split once only, so a worktree path containing a space survives whole.
    /// `git worktree add` accepts one, and losing everything after it would point
    /// a pane at a directory that is not there.
    private static func value(of line: Substring, field: String) -> String? {
        guard line.hasPrefix(field + " ") else { return nil }
        return String(line.dropFirst(field.count + 1))
    }

    /// True for a bare flag line.
    ///
    /// `locked` and `prunable` may carry a reason after a space
    /// (`prunable gitdir file points to non-existent location`), so an equality
    /// test alone would report a locked worktree as unlocked exactly when there
    /// is something to say about why.
    private static func isFlag(_ line: Substring, _ name: String) -> Bool {
        line == name || line.hasPrefix(name + " ")
    }
}
