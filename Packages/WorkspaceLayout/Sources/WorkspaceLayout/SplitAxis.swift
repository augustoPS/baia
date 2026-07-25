import Foundation

/// Which way a divider cuts the space it was given.
///
/// Named after how the children sit, not after how the divider runs, because the
/// divider reading is the opposite one and the two are easy to swap by accident:
/// `NSSplitView.isVertical` is true for the side-by-side arrangement this calls
/// `.horizontal`. The AppKit layer maps `.horizontal` to `isVertical = true`, and
/// getting that backwards produces a window that splits the wrong way with no
/// error anywhere.
///
/// Backed by `String` so the session file carries `"horizontal"` rather than the
/// `{"horizontal":{}}` object the compiler synthesizes for a case with no raw
/// value, since reading that file by hand is a real debugging move here.
public enum SplitAxis: String, Sendable, Equatable, Codable {
    /// Children sit side by side, first on the left.
    case horizontal
    /// Children stack, first on top.
    case vertical
}
