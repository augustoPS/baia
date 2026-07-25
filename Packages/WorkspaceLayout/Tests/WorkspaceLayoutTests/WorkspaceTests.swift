import Foundation
import Testing

@testable import WorkspaceLayout

@Suite struct WorkspaceTests {
    /// One tab, two panes side by side, focus on the left one.
    ///
    /// Built by hand rather than by calling `splitFocusedPane`, so a bug in the split
    /// cannot arrange for a close or a focus test to pass.
    private struct TwoPanes {
        let left = PaneID()
        let right = PaneID()

        var workspace: Workspace {
            Workspace(
                tabs: [Tab(
                    id: UUID(),
                    tree: .split(axis: .horizontal, ratio: 0.5, first: .leaf(left), second: .leaf(right)),
                    focusedPane: left,
                    zoomedPane: nil
                )],
                focusedTabIndex: 0
            )
        }
    }

    /// Three tabs of one pane each, focus on the middle one.
    private struct ThreeTabs {
        let first = PaneID()
        let second = PaneID()
        let third = PaneID()

        var workspace: Workspace {
            Workspace(
                tabs: [Tab(pane: first), Tab(pane: second), Tab(pane: third)],
                focusedTabIndex: 1
            )
        }
    }

    @Test func splittingTheFocusedPaneMovesFocusIntoTheNewOne() {
        let existing = PaneID()
        let opened = PaneID()
        var workspace = Workspace(pane: existing)

        let split = workspace.splitFocusedPane(axis: .horizontal, newPane: opened, ratio: 0.5)

        #expect(split)
        #expect(workspace.focusedPane == opened)
        #expect(workspace.focusedTab?.tree.paneIDs == [existing, opened])
    }

    @Test func splittingWithAnIDTheTabAlreadyHoldsChangesNothing() {
        let panes = TwoPanes()
        var workspace = panes.workspace
        let before = workspace

        let split = workspace.splitFocusedPane(axis: .vertical, newPane: panes.right, ratio: 0.5)

        #expect(!split)
        #expect(workspace == before)
    }

    @Test func splittingWhenTheFocusedPaneIsMissingFromItsOwnTreeChangesNothing() {
        // A decoded session can carry a focused pane its tree does not hold. The
        // mutators have to refuse rather than plant the new pane somewhere arbitrary,
        // and `reconciled` is what repairs the focus before the user notices.
        var workspace = Workspace(
            tabs: [Tab(id: UUID(), tree: .leaf(PaneID()), focusedPane: PaneID(), zoomedPane: nil)],
            focusedTabIndex: 0
        )
        let before = workspace

        let split = workspace.splitFocusedPane(axis: .horizontal, newPane: PaneID(), ratio: 0.5)

        #expect(!split)
        #expect(workspace == before)
    }

    @Test func closingAPaneFocusesTheSiblingThatTookItsSpace() {
        let panes = TwoPanes()
        var workspace = panes.workspace

        let closed = workspace.closeFocusedPane()

        #expect(closed)
        #expect(workspace.focusedPane == panes.right)
        #expect(workspace.focusedTab?.tree == .leaf(panes.right))
    }

    @Test func closingAPaneNextToASplitFocusesThatSplitsFirstPane() {
        let closing = PaneID()
        let heir = PaneID()
        let further = PaneID()
        // The sibling is a split, so the thing that took the space is a subtree. Its
        // first pane in visual order is the one now sitting where the cursor was.
        var workspace = Workspace(
            tabs: [Tab(
                id: UUID(),
                tree: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    first: .leaf(closing),
                    second: .split(axis: .vertical, ratio: 0.5, first: .leaf(heir), second: .leaf(further))
                ),
                focusedPane: closing,
                zoomedPane: nil
            )],
            focusedTabIndex: 0
        )

        let closed = workspace.closeFocusedPane()

        #expect(closed)
        #expect(workspace.focusedPane == heir)
    }

    @Test func closingTheLastPaneInARowFocusesItsNeighbourAndNotTheFirstPane() {
        let far = PaneID()
        let heir = PaneID()
        let closing = PaneID()
        // Three panes in a row, closing the rightmost. The pane that took the space is
        // the middle one, while the first pane of what is left is the one at the far
        // end. Focusing that instead would throw the cursor across the whole window,
        // and the two answers only differ when the closed pane is a second child, which
        // is why the other close tests cannot pin this.
        var workspace = Workspace(
            tabs: [Tab(
                id: UUID(),
                tree: .split(
                    axis: .horizontal,
                    ratio: 0.5,
                    first: .leaf(far),
                    second: .split(axis: .horizontal, ratio: 0.5, first: .leaf(heir), second: .leaf(closing))
                ),
                focusedPane: closing,
                zoomedPane: nil
            )],
            focusedTabIndex: 0
        )

        let closed = workspace.closeFocusedPane()

        #expect(closed)
        #expect(workspace.focusedPane == heir)
        #expect(workspace.focusedTab?.tree == .split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(far),
            second: .leaf(heir)
        ))
    }

    @Test func closingTheOnlyPaneOfTheOnlyTabIsRefused() {
        var workspace = Workspace(pane: PaneID())
        let before = workspace

        let closed = workspace.closeFocusedPane()

        #expect(!closed)
        #expect(workspace == before)
    }

    @Test func closingTheOnlyPaneOfATabClosesTheTab() {
        let panes = ThreeTabs()
        var workspace = panes.workspace

        let closed = workspace.closeFocusedPane()

        #expect(closed)
        #expect(workspace.tabs.count == 2)
        #expect(workspace.focusedPane == panes.third)
    }

    @Test func movingFocusCrossesToTheNeighbouringPane() {
        let panes = TwoPanes()
        var workspace = panes.workspace

        let moved = workspace.moveFocus(.right)

        #expect(moved)
        #expect(workspace.focusedPane == panes.right)
    }

    @Test func movingFocusOffTheEdgeIsRefused() {
        let panes = TwoPanes()
        var workspace = panes.workspace
        let before = workspace

        let left = workspace.moveFocus(.left)
        let up = workspace.moveFocus(.up)

        #expect(!left)
        #expect(!up)
        #expect(workspace == before)
    }

    @Test func movingFocusLeavesZoom() {
        let panes = TwoPanes()
        var workspace = panes.workspace
        _ = workspace.toggleZoomOnFocusedPane()

        let moved = workspace.moveFocus(.right)

        // The zoomed pane is the only one on screen, so keeping the zoom would put the
        // cursor in a pane hidden behind it.
        #expect(moved)
        #expect(workspace.focusedTab?.zoomedPane == nil)
    }

    @Test func cyclingPanesMovesInVisualOrderAndWraps() {
        let panes = TwoPanes()
        var workspace = panes.workspace

        let forward = workspace.focusNextPane()
        let wrapped = workspace.focusNextPane()

        #expect(forward)
        #expect(wrapped)
        #expect(workspace.focusedPane == panes.left)
    }

    @Test func cyclingPanesInASinglePaneTabIsRefused() {
        var workspace = Workspace(pane: PaneID())
        let before = workspace

        let cycled = workspace.focusNextPane()

        #expect(!cycled)
        #expect(workspace == before)
    }

    @Test func zoomTogglesOnAndOffTheFocusedPane() {
        let panes = TwoPanes()
        var workspace = panes.workspace

        let on = workspace.toggleZoomOnFocusedPane()
        let zoomed = workspace.focusedTab?.zoomedPane
        let off = workspace.toggleZoomOnFocusedPane()

        #expect(on)
        #expect(zoomed == panes.left)
        #expect(off)
        #expect(workspace.focusedTab?.zoomedPane == nil)
    }

    @Test func zoomLeavesTheTreeAlone() {
        let panes = TwoPanes()
        var workspace = panes.workspace
        let tree = workspace.focusedTab?.tree

        _ = workspace.toggleZoomOnFocusedPane()

        // Zoom is presentation. Rebuilding the tree for it would mean rebuilding it
        // again on the way out, and a released `TerminalView` takes its shell and its
        // scrollback with it.
        #expect(workspace.focusedTab?.tree == tree)
    }

    @Test func splittingWhileZoomedLeavesZoom() {
        let panes = TwoPanes()
        var workspace = panes.workspace
        _ = workspace.toggleZoomOnFocusedPane()

        let split = workspace.splitFocusedPane(axis: .vertical, newPane: PaneID(), ratio: 0.5)

        #expect(split)
        #expect(workspace.focusedTab?.zoomedPane == nil)
    }

    @Test func closingTheZoomedPaneLeavesNoZoomedIDBehind() {
        let panes = TwoPanes()
        var workspace = panes.workspace
        _ = workspace.toggleZoomOnFocusedPane()

        let closed = workspace.closeFocusedPane()

        // A zoom pointing at a pane that is gone renders as an empty tab, and the pane
        // that is actually there never gets laid out.
        #expect(closed)
        #expect(workspace.focusedTab?.zoomedPane == nil)
        #expect(workspace.focusedTab?.tree == .leaf(panes.right))
    }

    @Test func zoomSurvivesATabSwitch() {
        let panes = ThreeTabs()
        var workspace = panes.workspace
        _ = workspace.toggleZoomOnFocusedPane()

        _ = workspace.focusTab(at: 0)
        _ = workspace.focusTab(at: 1)

        // Per tab, not per window: a zoomed tab is still zoomed when the user comes
        // back to it, which is what makes zoom usable while a build runs.
        #expect(workspace.focusedTab?.zoomedPane == panes.second)
    }

    @Test func addingATabFocusesIt() {
        let opened = PaneID()
        var workspace = Workspace(pane: PaneID())

        workspace.addTab(pane: opened)

        #expect(workspace.tabs.count == 2)
        #expect(workspace.focusedTabIndex == 1)
        #expect(workspace.focusedPane == opened)
    }

    @Test func closingTheLastRemainingTabIsRefused() {
        var workspace = Workspace(pane: PaneID())
        let before = workspace

        let closed = workspace.closeFocusedTab()

        #expect(!closed)
        #expect(workspace == before)
    }

    @Test func closingATabFocusesWhicheverSlidIntoItsSlot() {
        let panes = ThreeTabs()
        var workspace = panes.workspace

        let closed = workspace.closeFocusedTab()

        #expect(closed)
        #expect(workspace.focusedTabIndex == 1)
        #expect(workspace.focusedPane == panes.third)
    }

    @Test func closingTheLastTabInTheBarFocusesTheOneBeforeIt() {
        let panes = ThreeTabs()
        var workspace = panes.workspace
        _ = workspace.focusTab(at: 2)

        let closed = workspace.closeFocusedTab()

        // The clamp, which the middle-tab case never reaches: without it the index
        // would name a tab that is no longer there and every key would go dead.
        #expect(closed)
        #expect(workspace.focusedTabIndex == 1)
        #expect(workspace.focusedPane == panes.second)
    }

    @Test func focusingATabIndexNoTabHasIsRefused() {
        let panes = ThreeTabs()
        var workspace = panes.workspace
        let before = workspace

        // cmd+5 in a three-tab window, and the negative index a hand-edited session can
        // carry.
        let past = workspace.focusTab(at: 4)
        let negative = workspace.focusTab(at: -1)

        #expect(!past)
        #expect(!negative)
        #expect(workspace == before)
    }

    @Test func focusingTheTabThatIsAlreadyFocusedReportsNoChange() {
        let panes = ThreeTabs()
        var workspace = panes.workspace

        let refocused = workspace.focusTab(at: 1)

        #expect(!refocused)
        #expect(workspace.focusedTabIndex == 1)
    }

    @Test func tabFocusWrapsAtBothEnds() {
        let panes = ThreeTabs()
        var workspace = panes.workspace

        workspace.focusNextTab()
        #expect(workspace.focusedTabIndex == 2)
        workspace.focusNextTab()
        #expect(workspace.focusedTabIndex == 0)
        workspace.focusPreviousTab()
        #expect(workspace.focusedTabIndex == 2)
    }

    @Test func tabFocusOnAnEmptyWorkspaceDoesNotDivideByTheTabCount() {
        // A reconciled session that lost every tab is an empty workspace, and `%` by an
        // empty collection's count traps rather than answering anything.
        var workspace = Workspace(tabs: [], focusedTabIndex: 0)

        workspace.focusNextTab()
        workspace.focusPreviousTab()

        #expect(workspace.focusedTab == nil)
        #expect(workspace.focusedPane == nil)
    }

    @Test func anOutOfRangeStoredIndexHasNoFocusedTab() {
        let workspace = Workspace(tabs: [Tab(pane: PaneID())], focusedTabIndex: 7)

        // Checked rather than trusted, since `focusedTabIndex` is a plain stored Int a
        // session file can carry out of range.
        #expect(workspace.focusedTab == nil)
        #expect(workspace.focusedPane == nil)
    }

    @Test func everyMutatorRefusedOnAnOutOfRangeIndexChangesNothing() {
        var workspace = Workspace(tabs: [Tab(pane: PaneID())], focusedTabIndex: 7)
        let before = workspace

        // Including toggleZoom, the one mutator that otherwise always succeeds. A
        // partial edit here would be a workspace that reports failure and mutates
        // anyway, which is the shape of bug that makes a Bool return worthless.
        let split = workspace.splitFocusedPane(axis: .horizontal, newPane: PaneID(), ratio: 0.5)
        let closedPane = workspace.closeFocusedPane()
        let closedTab = workspace.closeFocusedTab()
        let moved = workspace.moveFocus(.right)
        let cycled = workspace.focusNextPane()
        let zoomed = workspace.toggleZoomOnFocusedPane()
        let focused = workspace.focusPane(PaneID())

        #expect(!split)
        #expect(!closedPane)
        #expect(!closedTab)
        #expect(!moved)
        #expect(!cycled)
        #expect(!zoomed)
        #expect(!focused)
        #expect(workspace == before)
    }

    /// A click reports focus by pane id, and the id can name a pane that has
    /// since been closed. Accepting it would leave `focusedPane` pointing outside
    /// the tree, after which every later `moveFocus` and `closeFocusedPane`
    /// resolves from nowhere and silently does nothing.
    @Test func focusingAPaneThatIsNotInTheTreeIsRefused() {
        let first = PaneID()
        let second = PaneID()
        var workspace = Workspace(pane: first)
        let didSplit = workspace.splitFocusedPane(axis: .horizontal, newPane: second, ratio: 0.5)
        #expect(didSplit)
        let before = workspace

        let didFocus = workspace.focusPane(PaneID())

        #expect(!didFocus)
        #expect(workspace == before)
    }

    @Test func focusingAPaneMovesFocusAndClearsTheZoom() {
        let first = PaneID()
        let second = PaneID()
        var workspace = Workspace(pane: first)
        let didSplit = workspace.splitFocusedPane(axis: .horizontal, newPane: second, ratio: 0.5)
        #expect(didSplit)
        let didZoom = workspace.toggleZoomOnFocusedPane()
        #expect(didZoom)
        #expect(workspace.focusedTab?.zoomedPane == second)

        let didFocus = workspace.focusPane(first)

        #expect(didFocus)
        #expect(workspace.focusedPane == first)
        // The zoom has to clear, or the window would keep rendering the pane the
        // user just clicked away from.
        #expect(workspace.focusedTab?.zoomedPane == nil)
    }

    @Test func focusingTheAlreadyFocusedPaneReportsNoChange() {
        let first = PaneID()
        var workspace = Workspace(pane: first)
        let before = workspace

        let didFocus = workspace.focusPane(first)

        #expect(!didFocus)
        #expect(workspace == before)
    }
}
