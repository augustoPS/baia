import Foundation

/// One window on screen, holding its tabs in the order the tab bar shows them.
///
/// This is what AppKit calls an `NSWindowTabGroup`, and baia keeps native tabbing
/// rather than drawing its own bar: drag to reorder, drag out to detach, the
/// overflow menu and Merge All Windows all come free. The cost, which
/// ``WorkspaceWindowController`` states, is that tab order lives in AppKit and is
/// read back when a session is written rather than mirrored continuously.
///
/// The session file carried a flat `[Tab]` and one frame before this type existed,
/// so two separately positioned groups were written as one list and restored as one
/// group at one frame. The grouping was not decoded wrongly; it was never recorded.
public struct WindowGroup: Sendable, Equatable, Codable, Identifiable {
    /// Stable across a save and restore, so a later field can name a group without
    /// naming a position in an array that detaching and reordering both permute.
    public var id: UUID

    /// Left to right as the tab bar shows them.
    public var tabs: [Tab]

    /// Which tab this group is showing, by ``Tab/id``.
    ///
    /// An id rather than an index, and the difference is the whole reason this type
    /// exists: an index is only meaningful against a list that has not changed, and
    /// these lists change by exactly the operations being persisted. Detaching moves
    /// a tab to another group, reordering permutes one group, and
    /// ``SessionStore/reconciled(_:directoryExists:resolveAnchor:)`` drops tabs whose
    /// panes are gone, which shifts every index after them. `Workspace`'s
    /// `focusedTabIndex` needed clamping for precisely that reason.
    ///
    /// Still not trusted on the way in. An id naming no tab in this group resolves
    /// to the first tab, which is the repair `reconciled` already performs for an
    /// out-of-range index.
    public var selectedTab: UUID

    /// This group's own frame, or nil for a group that has never been placed.
    ///
    /// Per group rather than per session, which is the fix: one frame for the whole
    /// app was applied to whichever window happened to be built first, and that is
    /// only ever correct when there is one window.
    ///
    /// Nil is a launchable answer: AppKit picks a default frame. The caller still has
    /// to intersect a restored frame with the current screens, since a frame saved on
    /// a monitor that is no longer attached puts the window out of reach.
    public var frame: WindowFrame?

    /// How this group's sidebar was sized, or nil for a group that never opened one.
    ///
    /// **Per group, for the reason the frame is.** The width is taken from the panes,
    /// so it is a property of the window it was dragged in, and one session-level
    /// number meant dragging a column wide in one window silently resized every other
    /// window's on the next launch. Two windows on two repositories are exactly the
    /// case where the owner wants two widths, and the old shape could not hold them:
    /// the session recorded the focused window's and restored it to all of them.
    ///
    /// Not clamped here. The bounds belong to the view that lays the column out,
    /// since they depend on the window's height and on how many sections are stacked.
    public var sidebar: SidebarGeometry?

    /// No defaulted parameters, for the reason ``SessionSnapshot`` states: a field
    /// that defaults is a field a rebuild can silently drop, and `sidebar` was
    /// dropped that way for four days while every test passed.
    public init(id: UUID, tabs: [Tab], selectedTab: UUID, frame: WindowFrame?, sidebar: SidebarGeometry?) {
        self.id = id
        self.tabs = tabs
        self.selectedTab = selectedTab
        self.frame = frame
        self.sidebar = sidebar
    }

    /// A group of one tab, which is what opening a window gets.
    public init(tab: Tab, frame: WindowFrame? = nil) {
        self.init(id: UUID(), tabs: [tab], selectedTab: tab.id, frame: frame, sidebar: nil)
    }

    /// The tab the group is showing, or nil when `selectedTab` names none of them.
    ///
    /// Checked rather than trusted for the reason ``Workspace/focusedTab`` is: a
    /// decoded session can carry an id whose tab was dropped, and every caller that
    /// reads through here gets a nil it can repair instead of an index it cannot.
    public var selected: Tab? {
        tabs.first { $0.id == selectedTab }
    }

    /// Every pane this group shows, in tab order then visual order.
    public var paneIDs: [PaneID] {
        tabs.flatMap { $0.tree.paneIDs }
    }
}
