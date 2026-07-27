import Foundation

/// One hit, in one line, of one pane.
///
/// Carries no pane identity on purpose. `PaneSearch` imports nothing, so it has
/// no `PaneID` to hold, and the app associates matches with panes by searching
/// one pane at a time. That keeps the matching rule testable with plain strings.
///
/// `lineIndex` counts logical lines as the screen read returns them, which is
/// not a screen row: a line wider than the terminal occupies several rows and
/// one index. Resolving one to the other is the app's job and needs the pane.
public struct LineMatch: Sendable, Equatable {
    public let lineIndex: Int
    public let line: String
    /// Character offsets into `line`, so the range can be handed to a drawing
    /// layer without re-deriving it from a `String.Index` of a different string.
    public let range: Range<Int>

    public init(lineIndex: Int, line: String, range: Range<Int>) {
        self.lineIndex = lineIndex
        self.line = line
        self.range = range
    }
}
