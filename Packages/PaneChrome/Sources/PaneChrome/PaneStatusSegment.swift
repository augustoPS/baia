import Foundation

/// What a segment is, independent of what it says. The role is what the app
/// keys a click or a tooltip off, so it stays separate from the text: two
/// segments can render the same string and mean different things, and a branch
/// called `main` next to a directory called `main` is not hypothetical here.
public enum PaneStatusSegmentRole: Sendable, Equatable, CaseIterable {
    case anchorName, pin, branch, indicators, operation, agent, workingDirectory

    /// A transient sentence answering a click the pane refused, and the only role
    /// that replaces the bar rather than sharing it. See ``PaneStatus/notice``.
    case notice
}

/// Which question a segment answers, and therefore what it sits next to.
///
/// Grouping is by meaning rather than by position, which is what lets the bar
/// survive segments appearing and disappearing. A plain-directory pane emits no
/// repository group at all and an idle shell emits no agent group, so a fixed
/// row of slots would leave holes where a group used to be. Contiguous runs of
/// one group get the tight gap and the boundary between two groups gets the wide
/// one, so the bar reads as a table however many of its cells exist today.
public enum PaneStatusGroup: Sendable, Equatable, CaseIterable {
    /// Which stall this is: the anchor name and the pin chip.
    case identity

    /// What the repository is doing: the operation, the branch and the markers.
    case repository

    /// What is running in the pane.
    case agent

    /// True but not urgent: the working directory.
    case context

    /// Something the owner just did and the pane refused. Its own group because
    /// it never sits beside anything: a notice takes the bar alone.
    case notice
}

public extension PaneStatusSegmentRole {
    /// The group this role belongs to.
    ///
    /// Derived from the role rather than passed in, so a caller cannot build a
    /// branch segment that claims to be identity. There is exactly one correct
    /// answer per role and no reason for two call sites to be able to disagree
    /// about it.
    var group: PaneStatusGroup {
        switch self {
        case .anchorName, .pin: .identity
        case .operation, .branch, .indicators: .repository
        case .agent: .agent
        case .workingDirectory: .context
        case .notice: .notice
        }
    }
}

/// Which edge of the bar a segment is measured from.
public enum PaneStatusAlignment: Sendable, Equatable {
    case leading, trailing
}

/// Which end of the text the app cuts when a segment is placed narrower than it
/// measured.
public enum PaneStatusTruncation: Sendable, Equatable {
    case none, head, tail
}

/// How prominent a segment is. Deliberately not a colour: the colour depends on
/// the theme and on the bar the segment is drawn on, and only ``PaneTheme``
/// knows both. See ``PaneTheme/color(for:focused:on:)``.
///
/// The set is a tier system rather than a brightness ramp. Tier 1 is identity
/// (``strong``), tier 2 is repository state (``normal``), tier 3 is a warning
/// (``warn``, ``alert``), and tier 4 is context (``context``, ``faint``).
/// ``info`` sits inside tier 2's segment for the ahead and behind counts, which
/// are a number you may act on later rather than a state you are in now.
public enum PaneStatusEmphasis: Sendable, Equatable, CaseIterable {
    /// Tier 1. The focus colour on the focused pane, the foreground otherwise.
    /// The only emphasis focus changes, and the only one that must never dim.
    case strong

    /// Tier 2. The repository's own state, at full foreground.
    case normal

    /// Tier 3. The next command makes things worse: a half-finished operation,
    /// and the dirty marker.
    case warn

    /// Tier 3, and the loudest thing on the bar. Reserved for a conflicted tree
    /// and for an agent asking for input, so that one colour means "act now".
    case alert

    /// Ahead and behind counts. A number to act on eventually, which is neither
    /// a warning nor plain state.
    case info

    /// Tier 4. The pin chip and the agent label.
    case context

    /// Tier 4, quieter still. The working directory, which is the first thing
    /// dropped and the least urgent thing kept.
    case faint

    /// How loudly this emphasis speaks, used to pick a multi-run segment's
    /// headline. Higher wins.
    ///
    /// Not `Comparable`, because the order is a display decision rather than a
    /// property of the values: nothing outside this file should be able to ask
    /// whether `.faint < .warn` and get an answer it might read as a ranking of
    /// importance in some other sense.
    var loudness: Int {
        switch self {
        case .alert: 6
        case .warn: 5
        case .strong: 4
        case .info: 3
        case .normal: 2
        case .context: 1
        case .faint: 0
        }
    }
}

/// One stretch of a segment's text drawn in a single emphasis.
///
/// A segment is one measured, droppable unit but not necessarily one colour.
/// The markers are the case this exists for: `↑1↓2*?3` is read as a single word
/// and must be dropped whole, yet the `*` is a warning and the `?3` is a fact.
/// Splitting it into segments would let width pressure keep the ahead count and
/// drop the dirty marker, which is exactly backwards.
public struct PaneStatusRun: Sendable, Equatable {
    public var text: String
    public var emphasis: PaneStatusEmphasis

    public init(text: String, emphasis: PaneStatusEmphasis) {
        self.text = text
        self.emphasis = emphasis
    }
}

/// One measurable, droppable piece of a pane's status bar.
public struct PaneStatusSegment: Sendable, Equatable {
    public var role: PaneStatusSegmentRole
    public var text: String
    public var alignment: PaneStatusAlignment

    /// Higher survives width pressure. Ties drop the greatest index first, so the
    /// order is deterministic rather than dependent on sort stability.
    public var priority: Int

    public var truncation: PaneStatusTruncation

    /// The segment's headline emphasis. For a single-run segment it is that
    /// run's; for a multi-run one it is the loudest run's, so a caller that only
    /// looks here still sees `alert` on a conflicted repository.
    public var emphasis: PaneStatusEmphasis

    /// The text broken into coloured stretches, in order. Always at least one
    /// run, and always joining back to ``text``, which is what the width solver
    /// measures.
    public var runs: [PaneStatusRun]

    /// Which question this segment answers. Derived from ``role``.
    public var group: PaneStatusGroup { role.group }

    public init(
        role: PaneStatusSegmentRole,
        text: String,
        alignment: PaneStatusAlignment,
        priority: Int,
        truncation: PaneStatusTruncation,
        emphasis: PaneStatusEmphasis
    ) {
        self.role = role
        self.text = text
        self.alignment = alignment
        self.priority = priority
        self.truncation = truncation
        self.emphasis = emphasis
        runs = [PaneStatusRun(text: text, emphasis: emphasis)]
    }

    /// A segment whose text is drawn in more than one colour.
    ///
    /// ``text`` is the runs joined, so nothing downstream has to know a segment
    /// was built this way: it measures, truncates and drops exactly as a
    /// single-run segment does.
    public init(
        role: PaneStatusSegmentRole,
        runs: [PaneStatusRun],
        alignment: PaneStatusAlignment,
        priority: Int,
        truncation: PaneStatusTruncation
    ) {
        self.role = role
        self.runs = runs
        text = runs.map(\.text).joined()
        self.alignment = alignment
        self.priority = priority
        self.truncation = truncation
        emphasis = runs.max { $0.emphasis.loudness < $1.emphasis.loudness }?.emphasis ?? .normal
    }
}
