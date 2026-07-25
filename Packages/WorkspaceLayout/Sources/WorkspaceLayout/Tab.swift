import Foundation

/// One tab: a pane tree, which pane the keyboard is in, and whether one pane is
/// filling the tab.
///
/// Focus is per tab rather than per window, so switching away and back returns
/// the cursor to the pane it was in. A single window-wide focused pane would put
/// the cursor in a pane the tab bar is not showing.
public struct Tab: Sendable, Equatable, Codable {
    public var id: UUID
    public var tree: PaneTree
    public var focusedPane: PaneID

    /// The pane drawn over the whole tab, or nil when the tree is laid out as it
    /// stands.
    ///
    /// Zoom is presentation, so it is a flag beside the tree and never a change to
    /// it. Rebuilding the tree for a zoom would mean rebuilding it again to
    /// leave zoom, and a `TerminalView` that is released in the process takes its
    /// shell and its scrollback with it.
    public var zoomedPane: PaneID?

    public init(id: UUID, tree: PaneTree, focusedPane: PaneID, zoomedPane: PaneID?) {
        self.id = id
        self.tree = tree
        self.focusedPane = focusedPane
        self.zoomedPane = zoomedPane
    }

    /// A new tab showing one pane, focused, not zoomed.
    public init(pane: PaneID) {
        self.init(id: UUID(), tree: .leaf(pane), focusedPane: pane, zoomedPane: nil)
    }
}
