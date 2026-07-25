import Foundation

/// What a tab is called, given the anchor its pane resolved to.
public enum TabTitle {
    /// `~/Projects/baia/.claude/worktrees/agent-3f9c1a2b` abbreviates to
    /// `agent-3f9c1a`, but only when the directory name is `agent-` followed by
    /// six or more lowercase hex digits.
    ///
    /// The Agent tool's `isolation: "worktree"` names its worktrees after a hex
    /// id, where every character past the sixth is noise in a tab. A superpowers
    /// worktree such as `exif-display-0725-1432` is shown verbatim instead,
    /// because its name is the branch and cutting it loses which piece of work the
    /// tab holds. Both layouts are in daily use in this workspace, so the
    /// distinction is not hypothetical.
    public static func title(anchorName: String, isWorktree: Bool) -> String {
        // The name is only abbreviated inside a worktree. A repository the owner
        // deliberately called `agent-deadbeef` keeps its name, since outside the
        // worktree layouts there is no hex id to throw away.
        guard isWorktree, anchorName.hasPrefix(agentPrefix) else { return anchorName }

        let identifier = anchorName.dropFirst(agentPrefix.count)
        guard identifier.count >= abbreviatedLength,
              identifier.allSatisfy(lowercaseHex.contains)
        else { return anchorName }
        return agentPrefix + identifier.prefix(abbreviatedLength)
    }

    /// Disambiguates repeated titles by appending an increasing parent-path
    /// component, so two tabs both called `baia` become `baia (Projects)` and
    /// `baia (sandbox)`.
    ///
    /// Each entry is a slash-separated path whose last component is the title the
    /// tab wants, which is the only shape that carries anything to disambiguate
    /// *with*. An entry with no parents is valid and simply has nothing to grow
    /// into.
    ///
    /// The loop stops on lack of progress rather than on uniqueness. Two panes on
    /// the same path is not an edge case, it is what splitting a pane produces
    /// immediately, and a uniqueness-driven loop would never return for them. A
    /// group whose members share every component is left where it is rather than
    /// grown to the full path, so those two tabs read `baia` and `baia` instead of
    /// `baia (~/Projects)` twice, which is equally ambiguous and three times as
    /// wide.
    public static func disambiguated(_ titles: [String]) -> [String] {
        let components = titles.map { $0.split(separator: "/").map(String.init) }
        var depths = [Int](repeating: 0, count: titles.count)

        while true {
            var rendered: [String: [Int]] = [:]
            for index in titles.indices {
                rendered[render(components[index], depth: depths[index]), default: []].append(index)
            }

            var progressed = false
            for group in rendered.values where group.count > 1 {
                // A group whose members are the same path cannot be split by any
                // depth, and deepening it is what would spin forever.
                guard Set(group.map { components[$0] }).count > 1 else { continue }
                for index in group where depths[index] < parentCount(components[index]) {
                    depths[index] += 1
                    progressed = true
                }
            }
            if !progressed { break }
        }

        return titles.indices.map { render(components[$0], depth: depths[$0]) }
    }

    /// The title with `depth` of its parents appended in brackets.
    private static func render(_ components: [String], depth: Int) -> String {
        guard let title = components.last else { return "" }
        let parents = components.dropLast().suffix(depth)
        guard !parents.isEmpty else { return title }
        return "\(title) (\(parents.joined(separator: "/")))"
    }

    /// How many parents a path has to offer. Bounds every depth, which is what
    /// makes the loop in ``disambiguated(_:)`` terminate.
    private static func parentCount(_ components: [String]) -> Int {
        max(0, components.count - 1)
    }

    private static let agentPrefix = "agent-"

    /// Six digits of a hex id, which is what `git rev-parse --short` and the
    /// owner's own statusline show, so the tab and the prompt truncate a hash to
    /// the same length.
    private static let abbreviatedLength = 6

    /// Lowercase hex only, as the Agent tool writes it.
    ///
    /// An explicit set rather than `Character.isHexDigit`, which also accepts
    /// `A` through `F` and the fullwidth forms, and would let a repository
    /// deliberately named `agent-ABCDEF12` lose half its name.
    private static let lowercaseHex = Set("0123456789abcdef")
}
