import Foundation

/// Every tab in one window, and which of them the keyboard is in.
///
/// Each mutating method returns whether the workspace changed, so a menu action
/// or a key handler can call it unconditionally and skip the relayout when the
/// answer is false. A false return leaves the value untouched, down to the last
/// field: nothing here half-applies an edit and then reports failure.
///
/// One invariant every mutator upholds: `zoomedPane` is either nil or the focused
/// pane of that tab. Focus has to sit on a pane the user can see, and a zoomed
/// pane is the only pane on screen, so moving focus or removing that pane leaves
/// zoom rather than hiding the cursor behind the zoomed view. Switching tabs does
/// not touch it, which is what lets a zoomed tab stay zoomed while the user works
/// somewhere else.
public struct Workspace: Sendable, Equatable, Codable {
    public var tabs: [Tab]

    /// Which tab is showing. Stored rather than derived from a tab id, since the
    /// tab bar's order is the thing the arrow keys walk.
    public var focusedTabIndex: Int

    public init(tabs: [Tab], focusedTabIndex: Int) {
        self.tabs = tabs
        self.focusedTabIndex = focusedTabIndex
    }

    /// A workspace of one tab showing one pane, which is what a first launch with
    /// no session file gets.
    public init(pane: PaneID) {
        self.init(tabs: [Tab(pane: pane)], focusedTabIndex: 0)
    }

    /// Nil when `focusedTabIndex` names no tab.
    ///
    /// `focusedTabIndex` is a plain stored `Int` that a decoded session can carry
    /// out of range, so this is checked rather than trusted. Every mutator goes
    /// through it, which turns a corrupt index into a workspace that refuses
    /// everything instead of a crash, and ``SessionStore/reconciled(_:directoryExists:)``
    /// is what brings the index back into range before that can be noticed.
    public var focusedTab: Tab? {
        tabs.indices.contains(focusedTabIndex) ? tabs[focusedTabIndex] : nil
    }

    public var focusedPane: PaneID? {
        focusedTab?.focusedPane
    }

    /// Splits the focused pane and moves focus into the new one.
    ///
    /// Focus follows the new pane because a split exists to start typing somewhere
    /// else; leaving focus behind would make every split a two-key action. False
    /// when the tree has no such pane, which is a decoded session with a focused
    /// pane that is not in its own tree.
    public mutating func splitFocusedPane(axis: SplitAxis, newPane: PaneID, ratio: Double) -> Bool {
        withFocusedTab { tab in
            guard let split = tab.tree.splitting(
                tab.focusedPane,
                axis: axis,
                newPane: newPane,
                ratio: ratio
            ) else { return false }
            tab.tree = split
            tab.focusedPane = newPane
            tab.zoomedPane = nil
            return true
        }
    }

    /// Closes the focused pane, or the whole tab when it was that tab's last pane.
    ///
    /// False, and no change at all, when it was the last pane of the last tab. The
    /// window has to keep showing something, and a workspace with no panes has no
    /// key that can get one back.
    ///
    /// Focus lands on the sibling that took the closed pane's space, and on that
    /// sibling's first pane in visual order when the sibling is itself a split.
    /// That is the pane now under the cursor's old position, so the cursor appears
    /// to stay where it was rather than jumping to the corner of the window.
    public mutating func closeFocusedPane() -> Bool {
        guard let tab = focusedTab, tab.tree.contains(tab.focusedPane) else { return false }

        guard let remaining = tab.tree.closing(tab.focusedPane) else {
            // The pane was the tab's only one, so closing it is closing the tab.
            // closeFocusedTab is what refuses the last tab, so the last pane of
            // the last tab is refused here without a second count of anything.
            return closeFocusedTab()
        }

        // A tree that gave back a non-nil `closing` had a split above the closed
        // leaf, so the sibling is always there and always holds a pane. The guard
        // is here because the alternative is two force unwraps on a path that
        // runs on every cmd+w.
        guard let heir = tab.tree.sibling(of: tab.focusedPane)?.paneIDs.first else { return false }

        tabs[focusedTabIndex].tree = remaining
        tabs[focusedTabIndex].focusedPane = heir
        tabs[focusedTabIndex].zoomedPane = nil
        return true
    }

    /// Moves focus to the pane in that direction, if there is one.
    ///
    /// Resolved against ``LayoutRect/unit`` rather than the window's real frame.
    /// The pane the geometry picks is the same under any positive scaling of the
    /// two axes, so passing the frame in would add a parameter to every caller and
    /// change no answer. It would also make the first arrow key after launch fail,
    /// since the frame is not known until the window has laid out once.
    ///
    /// Leaving the zoomed pane leaves zoom, because the pane being moved to is not
    /// on screen while another pane fills the tab.
    public mutating func moveFocus(_ direction: FocusDirection) -> Bool {
        withFocusedTab { tab in
            guard let target = tab.tree.neighbour(
                of: tab.focusedPane,
                direction: direction,
                in: .unit
            ) else { return false }
            tab.focusedPane = target
            tab.zoomedPane = nil
            return true
        }
    }

    /// Focuses a named pane, which is what a click on a surface reports.
    ///
    /// The containment check is the whole point. The app learns about focus from
    /// a terminal callback that can arrive after the pane was closed, and a
    /// focused id that names no pane in the tree would leave every later
    /// `moveFocus` and `closeFocusedPane` operating from nowhere and silently
    /// doing nothing. False when the pane is absent or already focused, so the
    /// caller can skip redrawing.
    public mutating func focusPane(_ pane: PaneID) -> Bool {
        withFocusedTab { tab in
            guard tab.focusedPane != pane, tab.tree.contains(pane) else { return false }
            tab.focusedPane = pane
            tab.zoomedPane = nil
            return true
        }
    }

    /// Moves focus to the next pane in visual order, wrapping. False when the tab
    /// has one pane, since there is nowhere to go.
    public mutating func focusNextPane() -> Bool {
        withFocusedTab { tab in
            guard let next = tab.tree.pane(after: tab.focusedPane) else { return false }
            tab.focusedPane = next
            tab.zoomedPane = nil
            return true
        }
    }

    /// Moves the divider of the split at `path` in the focused tab.
    ///
    /// The only way a finished drag reaches the model. Without it the ratio lives
    /// nowhere but in the split view, and the next layout pass, rebuild, or launch
    /// restores whatever the tree still says.
    ///
    /// False when the tab is zoomed, because a zoomed tab shows one pane and no
    /// divider at all, so a ratio arriving then comes from a view that is no longer
    /// on screen. False when the path names no split, and false when the clamped
    /// value is the one already stored, so the caller can skip the session write.
    ///
    /// Focus is deliberately untouched: dragging a divider is not a way of choosing
    /// which pane to type in, and moving the cursor out from under the user's hands
    /// would be a worse surprise than the divider moving.
    public mutating func setRatio(at path: SplitPath, to ratio: Double) -> Bool {
        withFocusedTab { tab in
            guard tab.zoomedPane == nil else { return false }
            guard let moved = tab.tree.replacingRatio(at: path, with: ratio) else { return false }
            tab.tree = moved
            return true
        }
    }

    /// Grows the focused pane in that direction by one keyboard step.
    ///
    /// The divider that moves is the one touching the focused pane's edge that
    /// way, which ``PaneTree/adjustingRatio(forPane:direction:by:)`` resolves.
    /// False when there is no divider that way, when it is already against the
    /// clamp, and when the tab is zoomed, all of which mean the caller writes no
    /// session and pushes nothing into the views.
    ///
    /// Zoom refuses for the same reason ``setRatio(at:to:)`` does: a zoomed tab
    /// shows one pane and no divider, so a key that moved one would change a
    /// layout the user cannot see and spring it on them at the next unzoom.
    ///
    /// Focus is untouched. Resizing a pane is done from inside it, and moving the
    /// cursor out of the pane the user is growing would be absurd.
    public mutating func resizeFocusedPane(_ direction: FocusDirection, by delta: Double) -> Bool {
        withFocusedTab { tab in
            guard tab.zoomedPane == nil else { return false }
            guard let moved = tab.tree.adjustingRatio(
                forPane: tab.focusedPane,
                direction: direction,
                by: delta
            ) else { return false }
            tab.tree = moved
            return true
        }
    }

    /// Puts every divider in the focused tab back to the middle.
    ///
    /// False when the tab is already even, so the escape hatch from a layout that
    /// got away from the user costs nothing when it was not needed. False when
    /// zoomed, matching ``resizeFocusedPane(_:by:)``.
    public mutating func equalizeFocusedTab() -> Bool {
        withFocusedTab { tab in
            guard tab.zoomedPane == nil else { return false }
            let even = tab.tree.equalized
            guard even != tab.tree else { return false }
            tab.tree = even
            return true
        }
    }

    /// Zooms the focused pane, or unzooms when it is already the zoomed one.
    ///
    /// A single-pane tab can be zoomed. The state renders as nothing, and making
    /// the toggle depend on the pane count would put tree shape into a menu item's
    /// enabled state for no gain, since the next split clears the zoom anyway.
    public mutating func toggleZoomOnFocusedPane() -> Bool {
        withFocusedTab { tab in
            tab.zoomedPane = tab.zoomedPane == tab.focusedPane ? nil : tab.focusedPane
            return true
        }
    }

    /// Appends a tab showing `pane` and focuses it. A new tab the user cannot see
    /// is not what cmd+t means, so this has no failure to report.
    public mutating func addTab(pane: PaneID) {
        tabs.append(Tab(pane: pane))
        focusedTabIndex = tabs.count - 1
    }

    /// Closes the focused tab, taking every pane in it.
    ///
    /// False for the last tab, for the same reason `closeFocusedPane` refuses the
    /// last pane: the window keeps showing something.
    ///
    /// Focus goes to whichever tab slid into the closed one's position, and to the
    /// new last tab when the closed one was at the end. Clamping rather than always
    /// stepping left keeps the tab under the same slot in the tab bar, which is
    /// where the eye already is.
    public mutating func closeFocusedTab() -> Bool {
        guard tabs.count > 1, tabs.indices.contains(focusedTabIndex) else { return false }
        tabs.remove(at: focusedTabIndex)
        focusedTabIndex = min(focusedTabIndex, tabs.count - 1)
        return true
    }

    /// Focuses the tab at `index`. False for an index no tab has, which is what
    /// cmd+5 in a three-tab window is, and false for the tab that is already
    /// focused.
    public mutating func focusTab(at index: Int) -> Bool {
        guard tabs.indices.contains(index), index != focusedTabIndex else { return false }
        focusedTabIndex = index
        return true
    }

    /// Focuses the next tab, wrapping past the last.
    ///
    /// The empty guard is not decoration: `%` on an empty collection's count traps,
    /// and a reconciled session that lost every tab is an empty workspace rather
    /// than nil.
    public mutating func focusNextTab() {
        guard !tabs.isEmpty else { return }
        focusedTabIndex = (max(focusedTabIndex, 0) + 1) % tabs.count
    }

    /// Focuses the previous tab, wrapping past the first.
    public mutating func focusPreviousTab() {
        guard !tabs.isEmpty else { return }
        let current = min(max(focusedTabIndex, 0), tabs.count - 1)
        focusedTabIndex = (current + tabs.count - 1) % tabs.count
    }

    /// Runs `change` against the focused tab in place, and reports false without
    /// calling it when there is no focused tab.
    ///
    /// A closure rather than an optional index dance repeated in six methods: the
    /// inout access is what keeps a mutator from copying a tab, editing the copy,
    /// and writing it back over a tab something else changed in between.
    private mutating func withFocusedTab(_ change: (inout Tab) -> Bool) -> Bool {
        guard tabs.indices.contains(focusedTabIndex) else { return false }
        return change(&tabs[focusedTabIndex])
    }
}
