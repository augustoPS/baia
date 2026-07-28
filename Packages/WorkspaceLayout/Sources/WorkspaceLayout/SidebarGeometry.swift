import Foundation

/// How the sidebar was sized, as the session file carries it.
///
/// Two numbers rather than one, because they are dragged by different gestures and
/// only one of them costs anything: the width is taken from the panes, so changing
/// it resizes every ghostty grid, while the split moves inside a column whose width
/// never changes and resizes nothing at all.
///
/// Session-level rather than per window, the same shape ``WindowFrame`` already
/// has. A sidebar dragged to a width in one tab and left at the default in the next
/// would read as a bug rather than as a per-tab preference, and nobody has asked to
/// size two of them differently.
///
/// Not clamped here. The bounds belong to the view that lays the column out, since
/// they depend on the window's height and on how many sections are stacked, and a
/// value clamped at write time would be re-clamped against a different window on
/// the next launch anyway.
public struct SidebarGeometry: Sendable, Equatable, Codable {
    /// Points taken from the panes.
    public var width: Double

    /// Points given to the first section when two are stacked.
    ///
    /// Kept even while one section is showing, so switching to `both` and back does
    /// not forget where the split was put.
    public var splitHeight: Double

    public init(width: Double, splitHeight: Double) {
        self.width = width
        self.splitHeight = splitHeight
    }
}
