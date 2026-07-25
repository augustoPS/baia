import Foundation

/// What a segment is, independent of what it says. The role is what the app
/// keys a click or a tooltip off, so it stays separate from the text: two
/// segments can render the same string and mean different things, and a branch
/// called `main` next to a directory called `main` is not hypothetical here.
public enum PaneStatusSegmentRole: Sendable, Equatable, CaseIterable {
    case anchorName, pin, branch, indicators, operation, agent, workingDirectory
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
/// the theme and on whether the pane has focus, and only ``PaneTheme`` knows
/// both. See ``PaneTheme/color(for:focused:)``.
public enum PaneStatusEmphasis: Sendable, Equatable {
    case normal, strong, muted, alert
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
    public var emphasis: PaneStatusEmphasis

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
    }
}
