import Foundation

/// One repository's state, in the shape a one-line status bar needs.
///
/// Every field is a count rather than a list of paths. The pane's one-line
/// chrome copies `claude-dotfiles/statusline/ps1-style.sh`, which is one line that must
/// not wrap, so holding paths here would only invite a caller to render them
/// where they do not fit.
public struct RepositoryStatus: Sendable, Equatable {
    /// What HEAD points at. Three cases rather than two, because a repository
    /// with no commits still names a branch.
    public enum Head: Sendable, Equatable {
        case branch(String)
        case detached(commit: String)
        /// A repository with no commits yet. `git status` reports
        /// `# branch.oid (initial)` alongside a real `# branch.head main`, and a
        /// status bar must not render that as detached: a fresh `git init` would
        /// then look like the one state the owner has to escape from.
        case unborn(String)
    }

    /// The operation the repository is halfway through.
    ///
    /// Never set by ``GitStatusParser``. Porcelain v2 reports none of these at
    /// all, so they come from ``InProgressProbe`` reading the git directory, and
    /// a caller that parses status output on its own gets nil here forever.
    ///
    /// **Not `CaseIterable`, because the compiler already guards what the
    /// conformance was carried for.** It was added so a test could walk every
    /// case through `PaneChrome`'s `PaneStatus.Git.operationLabel(for:)` and fail
    /// on a nil, catching a state nobody taught the label mapping about. That
    /// test could not fail: `operationLabel` switches over this enum with no
    /// `default`, so a case added here is `error: switch must be exhaustive` at
    /// `PaneStatus+Repository.swift:50` and `swift build` stops before any test
    /// runs. Measured 2026-08-13 by adding a `graft` case — `make test` died in
    /// compilation and the test's nil branch was never reached.
    ///
    /// The compiler's check is strictly stronger than the test was: it fires on
    /// every switch over this type in every target, at build time, and cannot be
    /// skipped by a suite nobody ran. So the conformance went with the test.
    /// `allCases` had exactly one caller in the tree — that `for` loop — and a
    /// package does not grow public API surface to feed one.
    ///
    /// A consumer that genuinely needs to enumerate these should add the
    /// conformance back with a real caller named here. Anything that only needs
    /// *total* handling already has it, for free, from the switch.
    public enum InProgress: Sendable, Equatable {
        case rebase, merge, cherryPick, revert, bisect
    }

    public var head: Head
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var staged: Int
    public var unstaged: Int
    public var untracked: Int
    public var conflicted: Int
    public var inProgress: InProgress?

    /// Everything but `head` defaults, so a test can compare a whole parsed
    /// status against a constructed one and name only the fields it cares
    /// about. Field-by-field poking is how a parser regression hides: a test
    /// that never mentions `conflicted` cannot notice it being counted twice.
    public init(
        head: Head,
        upstream: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        staged: Int = 0,
        unstaged: Int = 0,
        untracked: Int = 0,
        conflicted: Int = 0,
        inProgress: InProgress? = nil
    ) {
        self.head = head
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.conflicted = conflicted
        self.inProgress = inProgress
    }

    /// The owner's own statusline vocabulary, from
    /// `claude-dotfiles/statusline/ps1-style.sh`: up arrow ahead, down arrow
    /// behind, asterisk dirty, question mark untracked, in that order.
    ///
    /// Empty when clean and in sync, so a status bar can concatenate it after
    /// the head name without a conditional. The script omits a zero count
    /// rather than printing `↑0`, and reproducing that is the whole point: a
    /// vocabulary the owner already reads at a glance is worth more than a
    /// complete one he has to learn.
    public var indicators: String {
        var text = ""
        if ahead > 0 { text += "↑\(ahead)" }
        if behind > 0 { text += "↓\(behind)" }

        // A conflicted path counts as dirty. `ps1-style.sh` derives the
        // asterisk from `git diff --quiet`, which reports an unmerged path as a
        // difference, so leaving conflicts out here would make a repository
        // stuck mid-merge render as clean.
        if staged > 0 || unstaged > 0 || conflicted > 0 { text += "*" }
        if untracked > 0 { text += "?" }
        return text
    }

    /// The head as the status bar prints it.
    ///
    /// A detached commit is parenthesised and abbreviated because that is what
    /// `ps1-style.sh` does (`branch="(${branch})"` around a
    /// `rev-parse --short`), so a detached pane reads the same in baia as in the
    /// owner's shell prompt. The full 40 character oid would push the one line
    /// into wrapping on a narrow split.
    public var displayHead: String {
        switch head {
        case let .branch(name):
            return name
        case let .unborn(name):
            return name
        case let .detached(commit):
            return "(\(commit.prefix(Self.abbreviatedCommitLength)))"
        }
    }

    /// `git rev-parse --short` grows past this when the repository needs more
    /// digits to stay unambiguous, and this does not: an ambiguous prefix is
    /// harmless in a status bar that nothing copies out of. A commit already
    /// shorter than this is passed through whole rather than padded.
    private static let abbreviatedCommitLength = 7
}
