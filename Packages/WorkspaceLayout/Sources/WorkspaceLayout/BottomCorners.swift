import Foundation

/// Which of a pane's two bottom corners sit on a bottom corner of the window.
///
/// The window is drawn with rounded corners by the system, which clips whatever
/// a pane paints there. A pane in a bottom corner therefore has to curve its own
/// footer to the same shape, or its focus frame runs square into a fill that
/// curves away from it.
///
/// Only the bottom pair, because only they can meet a corner: the top of the
/// window is the title bar's, and no pane reaches it. Naming corners this type
/// can never answer for would invite a caller to ask.
///
/// An `OptionSet` rather than an enum of four states, because the four states
/// are two independent facts and every caller reads them one at a time: the
/// drawing code asks "do I round this end", once per end.
public struct BottomCorners: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The bottom-left corner of the window, which is the pane's own bottom-left.
    public static let left = BottomCorners(rawValue: 1 << 0)

    /// The bottom-right corner of the window.
    public static let right = BottomCorners(rawValue: 1 << 1)

    /// What a single pane, a zoomed pane, and the bottom pane of a stacked-only
    /// split all own.
    public static let both: BottomCorners = [.left, .right]
}
