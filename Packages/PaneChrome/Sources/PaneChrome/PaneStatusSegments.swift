import Foundation

/// Turns a ``PaneStatus`` into the segments a bar draws, in reading order.
public enum PaneStatusSegments {
    /// Survival order under width pressure, from a bar that has room for
    /// everything down to a bar the width of one word.
    ///
    /// ``indicators`` outranks ``branch`` on purpose. Losing the branch name
    /// leaves a pane that says "this project has uncommitted work"; losing the
    /// markers leaves one that says nothing about it, and uncommitted work found
    /// too late is a recorded, repeatedly patched friction here. The name of the
    /// project outranks both, because a pane nobody can identify is the failure
    /// the bar exists to prevent.
    private enum Priority {
        static let anchorName = 100
        static let pin = 80
        static let operation = 80
        static let agent = 80
        static let indicators = 60
        static let branch = 40
        static let workingDirectory = 10
    }

    /// An ASCII label rather than a pin glyph. The bar is drawn in the terminal
    /// font, and a glyph outside that font's coverage is composed from a
    /// fallback face, which changes the run's metrics halfway along the string
    /// and puts the measured width the app hands to
    /// ``PaneStatusLayout/solve(segments:widths:availableWidth:)`` out of step
    /// with what gets drawn. `↑` and `↓` are kept because the owner's statusline
    /// already proves they render in this font.
    private static let pinMarker = "PIN"

    /// Marks a linked worktree on the branch segment, and sits in front of the
    /// branch so that the tail truncation the branch uses eats the branch name
    /// before it eats the warning. `wt` is the workspace's own shorthand for a
    /// worktree, down to the fixture directory name in ProjectAnchor's tests.
    private static let worktreePrefix = "wt:"

    /// Builds the bar's segments in placement order: leading segments left to
    /// right, then the trailing ones, which
    /// ``PaneStatusLayout/solve(segments:widths:availableWidth:)`` measures from
    /// the right edge leftwards while keeping this order on screen.
    public static func build(from status: PaneStatus) -> [PaneStatusSegment] {
        var segments: [PaneStatusSegment] = []

        // An empty name emits nothing rather than an empty box the width of the
        // insets. A pane whose anchor has not resolved yet is in exactly this
        // state for its first poll, since no surface exists before the view has
        // a window and non-zero bounds.
        if !status.anchorName.isEmpty {
            segments.append(PaneStatusSegment(
                role: .anchorName,
                text: status.anchorName,
                alignment: .leading,
                priority: Priority.anchorName,
                truncation: .tail,
                emphasis: .strong
            ))
        }

        if status.isPinned {
            segments.append(PaneStatusSegment(
                role: .pin,
                text: pinMarker,
                alignment: .leading,
                priority: Priority.pin,
                truncation: .none,
                emphasis: .muted
            ))
        }

        // A plain directory emits no git segments at all, even when `git` is
        // non-nil. The caller can legitimately be holding stale git facts from
        // before a `cd` out of the repository, and a branch name on a directory
        // that has no branch is a lie the owner would act on.
        if status.anchorIsRepository, let git = status.git {
            append(git, to: &segments)
        }

        if let agent = status.agent, !agent.label.isEmpty {
            segments.append(PaneStatusSegment(
                role: .agent,
                text: agent.label,
                alignment: .trailing,
                priority: Priority.agent,
                truncation: .tail,
                // An agent asking for input is the one thing on this bar that is
                // worth interrupting for.
                emphasis: agent.wantsAttention ? .alert : .normal
            ))
        }

        if let directory = status.workingDirectory, !isBlank(directory) {
            segments.append(PaneStatusSegment(
                role: .workingDirectory,
                text: directory,
                alignment: .trailing,
                priority: Priority.workingDirectory,
                // Truncated from the head, so `~/Projects/baia/Packages/…/Tests`
                // keeps the end that says where the shell actually is. Cutting
                // the tail of a path leaves every deep directory in one project
                // looking identical.
                truncation: .head,
                emphasis: .muted
            ))
        }

        return segments
    }

    /// The three git segments, in the order the table in the brief fixes:
    /// operation, then branch, then indicators. The operation comes first
    /// because a half-finished rebase changes what every other fact on the bar
    /// means.
    private static func append(_ git: PaneStatus.Git, to segments: inout [PaneStatusSegment]) {
        if let operation = git.operation, !isBlank(operation) {
            segments.append(PaneStatusSegment(
                role: .operation,
                text: operation,
                alignment: .leading,
                priority: Priority.operation,
                truncation: .none,
                // Strong, not alert. Alert is reserved for conflicted files and
                // for an agent asking for input, so that one colour on this bar
                // means "act now" and a mid-rebase pane does not cry it every
                // time.
                emphasis: .strong
            ))
        }

        if !git.head.isEmpty {
            segments.append(PaneStatusSegment(
                role: .branch,
                text: git.isLinkedWorktree ? worktreePrefix + git.head : git.head,
                alignment: .leading,
                priority: Priority.branch,
                truncation: .tail,
                emphasis: .normal
            ))
        }

        // An empty indicator string emits no segment rather than an empty one.
        // A clean repository is the common case, and a zero-width segment still
        // costs a spacing gap, which would leave the bar looking mis-aligned
        // against the pane next to it.
        let markers = indicators(git)
        if !markers.isEmpty {
            segments.append(PaneStatusSegment(
                role: .indicators,
                text: markers,
                alignment: .leading,
                priority: Priority.indicators,
                truncation: .none,
                emphasis: git.conflicted > 0 ? .alert : .normal
            ))
        }
    }

    /// The marker string, for example `↑1↓2*?3`.
    ///
    /// Kept as one segment rather than five, because the markers are read as a
    /// single word and splitting them would let width pressure drop the `*`
    /// while keeping the `↑1`. It is a segment of its own rather than a suffix on
    /// the branch, which is how the owner's statusline writes it, so that a long
    /// branch name can be dropped with the markers surviving.
    private static func indicators(_ git: PaneStatus.Git) -> String {
        var text = ""

        // Ahead and behind are dropped when there is no upstream, even when the
        // counts are non-zero. A detached HEAD or a deleted upstream leaves
        // whatever the last successful count was, and `↑3` against a branch that
        // has nowhere to push is worse than saying nothing.
        if git.hasUpstream {
            if git.ahead > 0 { text += "↑\(git.ahead)" }
            if git.behind > 0 { text += "↓\(git.behind)" }
        }

        if git.dirty { text += "*" }
        if git.untracked > 0 { text += "?\(git.untracked)" }

        // Conflicts come last so the owner's own four markers keep the exact
        // prefix his prompt shows, and the whole segment turns alert anyway, so
        // position costs nothing in noticing it.
        if git.conflicted > 0 { text += "!\(git.conflicted)" }

        return text
    }

    /// True for a string with nothing but whitespace in it. A caller that
    /// formatted an operation label from an empty git file hands over `" "`
    /// rather than `""`, and that still draws as an empty box.
    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
