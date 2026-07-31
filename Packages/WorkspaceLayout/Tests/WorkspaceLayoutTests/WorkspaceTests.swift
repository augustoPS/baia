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

    /// One tab holding two splits on the same spine, focus on the leftmost pane.
    private struct NestedSplits {
        let a = PaneID()
        let b = PaneID()
        let c = PaneID()

        var workspace: Workspace {
            Workspace(
                tabs: [Tab(
                    id: UUID(),
                    tree: .split(
                        axis: .horizontal,
                        ratio: 0.5,
                        first: .leaf(a),
                        second: .split(axis: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
                    ),
                    focusedPane: a,
                    zoomedPane: nil
                )],
                focusedTabIndex: 0
            )
        }
    }

    @Test func setRatioAtPathMovesTheFocusedTabsSplit() {
        let panes = NestedSplits()
        var workspace = panes.workspace

        let moved = workspace.setRatio(at: SplitPath([1]), to: 0.25)

        #expect(moved)
        #expect(workspace.focusedTab?.tree.ratio(at: SplitPath([1])) == 0.25)
        // The outer divider is where the user left it. A drag reports the split it
        // is the divider of, and nothing above it may move with it.
        #expect(workspace.focusedTab?.tree.ratio(at: SplitPath()) == 0.5)
    }

    @Test func setRatioWhileZoomedIsRefused() {
        let panes = NestedSplits()
        var workspace = panes.workspace
        _ = workspace.toggleZoomOnFocusedPane()
        let before = workspace

        let moved = workspace.setRatio(at: SplitPath([1]), to: 0.25)

        // A zoomed tab shows one pane and no divider at all, so a ratio arriving
        // while zoomed is a stale report from a view that is no longer on screen.
        #expect(!moved)
        #expect(workspace == before)
    }

    @Test func setRatioAtAPathThatNamesNoSplitIsRefused() {
        let panes = NestedSplits()
        var workspace = panes.workspace
        let before = workspace

        let intoALeaf = workspace.setRatio(at: SplitPath([0]), to: 0.25)
        let offTheBottom = workspace.setRatio(at: SplitPath([1, 1]), to: 0.25)

        #expect(!intoALeaf)
        #expect(!offTheBottom)
        #expect(workspace == before)
    }

    @Test func setRatioToTheValueTheSplitAlreadyHasIsRefused() {
        let panes = NestedSplits()
        var workspace = panes.workspace
        let before = workspace

        // False so the caller skips the session write. A click on a divider that
        // moves it by nothing still ends a drag.
        let moved = workspace.setRatio(at: SplitPath(), to: 0.5)

        #expect(!moved)
        #expect(workspace == before)
    }

    @Test func setRatioLeavesEveryOtherTabAlone() {
        let tabs = ThreeTabs()
        var workspace = tabs.workspace
        let other = PaneID()
        workspace.tabs[1].tree = .split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(tabs.second),
            second: .leaf(other)
        )
        workspace.tabs[0].tree = .split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(tabs.first),
            second: .leaf(PaneID())
        )
        let untouched = workspace.tabs[0].tree

        let moved = workspace.setRatio(at: SplitPath(), to: 0.2)

        #expect(moved)
        #expect(workspace.tabs[1].tree.ratio(at: SplitPath()) == 0.2)
        #expect(workspace.tabs[0].tree == untouched)
    }

    @Test func resizingTheFocusedPaneMovesTheDividerItTouches() {
        let panes = NestedSplits()
        var workspace = panes.workspace

        // Focus is on `a`, the whole left column, so the only divider it can move
        // is the root one, and growing right pushes it away from the origin.
        let grew = workspace.resizeFocusedPane(.right, by: 0.1)

        #expect(grew)
        #expect(workspace.focusedTab?.tree.ratio(at: SplitPath()) == 0.6)
        #expect(workspace.focusedTab?.tree.ratio(at: SplitPath([1])) == 0.5)
    }

    @Test func resizingWithNoDividerThatWayIsRefused() {
        let panes = NestedSplits()
        var workspace = panes.workspace
        let before = workspace

        // `a` is against the left edge of the window and spans its full height,
        // so three of the four keys have nothing to move. Refusing rather than
        // reaching for some other divider is the whole contract: a key that does
        // nothing is readable, a key that resizes a pane across the window is not.
        let left = workspace.resizeFocusedPane(.left, by: 0.1)
        let up = workspace.resizeFocusedPane(.up, by: 0.1)
        let down = workspace.resizeFocusedPane(.down, by: 0.1)

        #expect(!left)
        #expect(!up)
        #expect(!down)
        #expect(workspace == before)
    }

    @Test func resizingWhileZoomedIsRefused() {
        let panes = NestedSplits()
        var workspace = panes.workspace
        _ = workspace.toggleZoomOnFocusedPane()
        let before = workspace

        let grew = workspace.resizeFocusedPane(.right, by: 0.1)

        // A zoomed tab shows one pane and no divider, so the key would move
        // something the user cannot see and spring it on them at the next unzoom.
        #expect(!grew)
        #expect(workspace == before)
    }

    @Test func resizingLeavesFocusWhereItWas() {
        let panes = NestedSplits()
        var workspace = panes.workspace

        _ = workspace.resizeFocusedPane(.right, by: 0.1)

        // Resizing is done from inside the pane being resized. Moving the cursor
        // out of it, the way a split or a close does, would make the next
        // keystroke land somewhere else.
        #expect(workspace.focusedPane == panes.a)
    }

    @Test func equalizingEvensASplitOutOfShape() {
        let panes = NestedSplits()
        var workspace = panes.workspace
        _ = workspace.setRatio(at: SplitPath(), to: 0.2)
        _ = workspace.setRatio(at: SplitPath([1]), to: 0.9)

        let evened = workspace.equalizeFocusedTab()

        // Back to the fixture, which is halves. A pane beside a column is one slot
        // against one slot, and the column's own two are one against one again, so
        // this arrangement is the case where evening siblings and halving every
        // split agree. `equalizedEvensColumnsRatherThanPanes` is where they part.
        #expect(evened)
        #expect(workspace.focusedTab?.tree == panes.workspace.focusedTab?.tree)
    }

    @Test func equalizingAnAlreadyEvenTabIsRefused() {
        let panes = NestedSplits()
        var workspace = panes.workspace
        let before = workspace

        let evened = workspace.equalizeFocusedTab()

        // False so the caller skips the session write and the divider push. The
        // key is the escape hatch from a layout that got away from the user, and
        // it should cost nothing when it was not needed.
        #expect(!evened)
        #expect(workspace == before)
    }

    @Test func resizingLeavesEveryOtherTabAlone() {
        let tabs = ThreeTabs()
        var workspace = tabs.workspace
        let other = PaneID()
        workspace.tabs[0].tree = .split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(tabs.first),
            second: .leaf(other)
        )
        let untouched = workspace.tabs[0].tree
        workspace.tabs[1].tree = .split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(tabs.second),
            second: .leaf(PaneID())
        )

        let grew = workspace.resizeFocusedPane(.right, by: 0.1)

        #expect(grew)
        #expect(workspace.tabs[1].tree.ratio(at: SplitPath()) == 0.6)
        #expect(workspace.tabs[0].tree == untouched)
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
