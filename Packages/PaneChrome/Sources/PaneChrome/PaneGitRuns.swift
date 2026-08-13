import Foundation
import GitWorkspace

/// The git marker vocabulary, in the coloured runs three surfaces draw it with:
/// the tab title, the command palette, and the capsule's changes segment.
///
/// **Named for what it answers rather than for where it used to live.** Until
/// 2026-08-13 this was `PaneStatusSegments`, a table of measured, droppable,
/// aligned, prioritised segments built for `PaneStatusBarView` to solve a bar
/// width against. The bar is gone and its solver with it, and what the three
/// remaining callers wanted was never the table: each took one row out of it and
/// threw the rest away. The word `Segments` promised a bar's placement and the
/// word `Status` promised the pane's whole status, and neither is on offer here
/// any more — this is the marker vocabulary and the branch beside it, nothing
/// else. `Runs` is the honest noun, because ``PaneStatusRun`` is what every
/// entry point returns and what the palette and the capsule already draw.
///
/// The vocabulary itself is the owner's own statusline
/// (`claude-dotfiles/statusline/ps1-style.sh`): `↑` ahead, `↓` behind, `*`
/// dirty, `?` untracked, `!` conflicted. Reusing it rather than inventing one
/// means every surface reads the same as the prompt he already scans.
public enum PaneGitRuns {
    /// Marks a linked worktree in front of the branch name, so that a caller
    /// truncating from the tail eats the branch before it eats the warning. `wt`
    /// is the workspace's own shorthand for a worktree, down to the fixture
    /// directory name in ProjectAnchor's tests.
    private static let worktreePrefix = "wt:"

    /// The markers, for example `↑1↓2*?3`, as coloured runs.
    ///
    /// **One unit, four colours, and both halves of that are load-bearing.** The
    /// markers are read as a single word, so they are assembled and drawn whole
    /// rather than as five independently droppable pieces: the width pressure the
    /// bar applied would have kept the `↑1` and dropped the `*`, which is exactly
    /// backwards. Yet they do not mean the same thing as each other, and one
    /// colour across all of them made the reader parse the glyphs to find that
    /// out. An ahead count is a number to act on eventually, a dirty tree is the
    /// one that costs you if you miss it, untracked files are a fact, and a
    /// conflict is an emergency.
    ///
    /// The bar that applied the pressure was deleted on 2026-08-13. The shape
    /// survives it because the capsule measures these same runs to size its pill
    /// (``PaneClusterLayout``), so "assembled whole, coloured inside" is still
    /// the contract and not a fossil.
    public static func markers(for git: PaneStatus.Git) -> [PaneStatusRun] {
        var runs: [PaneStatusRun] = []

        // Ahead and behind are dropped when there is no upstream, even when the
        // counts are non-zero. A detached HEAD or a deleted upstream leaves
        // whatever the last successful count was, and `↑3` against a branch that
        // has nowhere to push is worse than saying nothing.
        if git.hasUpstream {
            if git.ahead > 0 { runs.append(PaneStatusRun(text: "↑\(git.ahead)", emphasis: .info)) }
            if git.behind > 0 { runs.append(PaneStatusRun(text: "↓\(git.behind)", emphasis: .info)) }
        }

        if git.dirty { runs.append(PaneStatusRun(text: "*", emphasis: .warn)) }
        if git.untracked > 0 {
            runs.append(PaneStatusRun(text: "?\(git.untracked)", emphasis: .context))
        }

        // Conflicts come last so the owner's own four markers keep the exact
        // prefix his prompt shows.
        if git.conflicted > 0 {
            runs.append(PaneStatusRun(text: "!\(git.conflicted)", emphasis: .alert))
        }

        return runs
    }

    /// The marker string, for example `↑1↓2*?3`: ``markers(for:)`` joined.
    ///
    /// **One assembly with two renderings, rather than two assemblies.** The tab
    /// title takes this string and the capsule's changes segment
    /// (``PaneClusterSegments/build(from:)``) takes it too, while the palette
    /// takes the runs; a second copy of the vocabulary anywhere is a second
    /// chance for one surface to be taught about a new marker and another not.
    /// The joining is unspaced, which `TerminalPaneController.tabTitle` relies on
    /// when it budgets the title's width.
    public static func markerText(for git: PaneStatus.Git) -> String {
        markers(for: git).map(\.text).joined()
    }

    /// The command palette's branch and markers for a selected row, on one line.
    ///
    /// The palette row has no room for a second line, so what the bar drew as two
    /// separated cells is flattened here with a single space run standing in for
    /// the gap between them. Routing it through this file rather than formatting
    /// it at the call site is what keeps the palette from drifting: the same
    /// dirty marker is the same colour in both surfaces, and a change to the
    /// vocabulary reaches the palette for free.
    ///
    /// The operation label is dropped because the palette row has no room for it,
    /// and the worktree flag is false because a palette row names a project
    /// rather than a pane, so nothing here has been anchored to a checkout yet.
    /// The pane's own capsule answers both the moment the project is open.
    public static func runs(for status: RepositoryStatus) -> [PaneStatusRun] {
        let git = PaneStatus.Git(status, operation: nil, isLinkedWorktree: false)

        var runs = branch(for: git)
        let markers = markers(for: git)
        if !markers.isEmpty {
            if !runs.isEmpty { runs.append(PaneStatusRun(text: " ", emphasis: .context)) }
            runs.append(contentsOf: markers)
        }
        return runs
    }

    /// The branch name, prefixed when the pane sits in a linked worktree.
    ///
    /// The prefix is a separate run rather than a separate unit: it must never be
    /// dropped away from the branch it qualifies, and it must not be the loudest
    /// thing here either. Drawn in tier 4 while the branch keeps tier 2, so the
    /// branch name reads first and the prefix answers "which checkout" only once
    /// you have read it.
    ///
    /// An empty head emits nothing rather than an empty run, so a caller joining
    /// this with the markers does not pay a separator for a branch that is not
    /// there.
    static func branch(for git: PaneStatus.Git) -> [PaneStatusRun] {
        guard !git.head.isEmpty else { return [] }
        guard git.isLinkedWorktree else {
            return [PaneStatusRun(text: git.head, emphasis: .normal)]
        }
        return [
            PaneStatusRun(text: worktreePrefix, emphasis: .context),
            PaneStatusRun(text: git.head, emphasis: .normal),
        ]
    }

    /// True for a string with nothing but whitespace in it. A caller that
    /// formatted an operation label from an empty git file hands over `" "`
    /// rather than `""`, and that still draws as an empty box.
    ///
    /// Package-internal rather than private because ``PaneStatus/Git/displayableOperation``
    /// is the one predicate every surface drawing an operation asks, and it asks
    /// this. Two copies of one blankness test is two chances for one surface to
    /// be taught about a new kind of blank and the other not — which is not
    /// hypothetical: the place card applied `if let` alone until 2026-08-13 and
    /// grew a row captioned `operation` with a blank value beside it.
    static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
