import Foundation

/// How prominent a stretch of text is. Deliberately not a colour: the colour
/// depends on the theme and on the surface the text is drawn on, and only
/// ``PaneTheme`` knows both. See ``PaneTheme/color(for:focused:on:)``.
///
/// The set is a tier system rather than a brightness ramp. Tier 1 is identity
/// (``strong``), tier 2 is repository state (``normal``), tier 3 is a warning
/// (``warn``, ``alert``), and tier 4 is context (``context``, ``faint``).
/// ``info`` sits inside tier 2 for the ahead and behind counts, which are a
/// number you may act on later rather than a state you are in now.
public enum PaneStatusEmphasis: Sendable, Equatable, CaseIterable {
    /// Tier 1. The focus colour on the focused pane, the foreground otherwise.
    /// The only emphasis focus changes, and the only one that must never dim.
    case strong

    /// Tier 2. The repository's own state, at full foreground.
    case normal

    /// Tier 3. The next command makes things worse: a half-finished operation,
    /// and the dirty marker.
    case warn

    /// Tier 3, and the loudest thing drawn. Reserved for a conflicted tree and
    /// for an agent asking for input, so that one colour means "act now".
    case alert

    /// Ahead and behind counts. A number to act on eventually, which is neither
    /// a warning nor plain state.
    case info

    /// Tier 4. The pin chip and the agent label.
    case context

    /// Tier 4, quieter still. The working directory, and the palette row's
    /// unmatched characters.
    case faint
}

/// One stretch of text drawn in a single emphasis.
///
/// **The drawing vocabulary, and it outlived the bar it was invented for.** It
/// arrived as the inside of a `PaneStatusSegment`, which was one measured
/// droppable cell of `PaneStatusBarView`'s table but not necessarily one colour;
/// the markers were the case it existed for, since `↑1↓2*?3` is read as a single
/// word yet the `*` is a warning and the `?3` is a fact. The bar and its segment
/// table were deleted on 2026-08-13 and this stayed, because two surfaces that
/// never were bars already drew in it: the command palette's rows
/// (``PaletteRow``, `CommandPaletteView.drawRuns`) and the markers themselves
/// (``PaneGitRuns``). A run is text plus a tier, which is a smaller idea than a
/// bar cell and belongs to neither.
public struct PaneStatusRun: Sendable, Equatable {
    public var text: String
    public var emphasis: PaneStatusEmphasis

    public init(text: String, emphasis: PaneStatusEmphasis) {
        self.text = text
        self.emphasis = emphasis
    }
}
