import Foundation
import Testing

@testable import WorkspaceLayout

/// The target-taking mutators, which exist because the control channel's caller is
/// a pane rather than the cursor.
///
/// Every rule here is behaviour the focused-pane methods structurally cannot
/// exhibit, since whatever they touched was the pane the user was typing in. None
/// of it is covered by ``WorkspaceTests``, and the three that matter are: a
/// mutation on a pane nobody is looking at moves nobody's focus, a mutation in a
/// background tab lands in that tab without switching to it, and no mutation
/// clears a zoom belonging to another pane.
@Suite struct WorkspaceTargetedMutationTests {
    /// Two tabs of two panes each, the user in the first one.
    ///
    /// Built by hand rather than by splitting, so a bug in `split(pane:)` cannot
    /// arrange for a close, a resize, or an equalize test to pass.
    private struct TwoTabsOfTwo {
        let visibleLeft = PaneID()
        let visibleRight = PaneID()
        let backgroundLeft = PaneID()
        let backgroundRight = PaneID()

        var workspace: Workspace {
            Workspace(
                tabs: [
                    Tab(
                        id: UUID(),
                        tree: .split(
                            axis: .horizontal,
                            ratio: 0.5,
                            first: .leaf(visibleLeft),
                            second: .leaf(visibleRight)
                        ),
                        focusedPane: visibleLeft,
                        zoomedPane: nil
                    ),
                    Tab(
                        id: UUID(),
                        tree: .split(
                            axis: .horizontal,
                            ratio: 0.5,
                            first: .leaf(backgroundLeft),
                            second: .leaf(backgroundRight)
                        ),
                        focusedPane: backgroundLeft,
                        zoomedPane: nil
                    ),
                ],
                focusedTabIndex: 0
            )
        }
    }

    /// One tab of three panes in a row, focus on the leftmost, nothing zoomed.
    ///
    /// Three rather than two because the heir rule needs an answer that differs from
    /// the pane already holding focus. Closing one of a pair promotes the other,
    /// which is the pane the cursor was in anyway, so a two-pane close test passes
    /// whether or not the heir rule was wrongly applied.
    private struct ThreePanesInARow {
        let left = PaneID()
        let middle = PaneID()
        let right = PaneID()

        var workspace: Workspace {
            Workspace(
                tabs: [Tab(
                    id: UUID(),
                    tree: .split(
                        axis: .horizontal,
                        ratio: 0.5,
                        first: .leaf(left),
                        second: .split(
                            axis: .horizontal,
                            ratio: 0.5,
                            first: .leaf(middle),
                            second: .leaf(right)
                        )
                    ),
                    focusedPane: left,
                    zoomedPane: nil
                )],
                focusedTabIndex: 0
            )
        }
    }

    /// One tab of three panes with the focused one zoomed, which is the only shape
    /// ``Workspace``'s zoom invariant allows: `zoomedPane` is nil or the tab's
    /// focused pane.
    private struct ZoomedTab {
        let zoomed = PaneID()
        let middle = PaneID()
        let last = PaneID()

        var workspace: Workspace {
            Workspace(
                tabs: [Tab(
                    id: UUID(),
                    tree: .split(
                        axis: .horizontal,
                        ratio: 0.5,
                        first: .leaf(zoomed),
                        second: .split(
                            axis: .horizontal,
                            ratio: 0.5,
                            first: .leaf(middle),
                            second: .leaf(last)
                        )
                    ),
                    focusedPane: zoomed,
                    zoomedPane: zoomed
                )],
                focusedTabIndex: 0
            )
        }
    }

    // Rule 1: a mutation on a pane that is not focused does not move focus.

    @Test func splittingAPaneThatIsNotFocusedLeavesTheCursorWhereItWas() {
        let panes = TwoTabsOfTwo()
        var workspace = panes.workspace
        let opened = PaneID()

        let split = workspace.split(
            pane: panes.visibleRight,
            axis: .vertical,
            newPane: opened,
            ratio: 0.5
        )

        // The split happened, and the caller gets the new id back to work with. What
        // it does not get is the owner's cursor: a background agent splitting itself
        // must not pull the keyboard out of the pane being typed in.
        #expect(split)
        #expect(workspace.focusedPane == panes.visibleLeft)
        #expect(workspace.focusedTab?.tree.paneIDs == [panes.visibleLeft, panes.visibleRight, opened])
    }

    @Test func splittingTheFocusedPaneMovesFocusIntoTheNewOne() {
        let panes = TwoTabsOfTwo()
        var workspace = panes.workspace
        let opened = PaneID()

        let split = workspace.split(
            pane: panes.visibleLeft,
            axis: .vertical,
            newPane: opened,
            ratio: 0.5
        )

        // The sole exception to rule 1, and the reason it is one: a pane splitting
        // itself while it holds the cursor is asking to type in the new pane.
        #expect(split)
        #expect(workspace.focusedPane == opened)
    }

    @Test func resizingAPaneThatIsNotFocusedLeavesTheCursorWhereItWas() {
        let panes = TwoTabsOfTwo()
        var workspace = panes.workspace

        let grew = workspace.resize(pane: panes.visibleRight, direction: .left, by: 0.1)

        #expect(grew)
        #expect(workspace.focusedTab?.tree.ratio(at: SplitPath()) == 0.4)
        #expect(workspace.focusedPane == panes.visibleLeft)
    }

    @Test func equalizingByAPaneThatIsNotFocusedLeavesTheCursorWhereItWas() {
        let panes = TwoTabsOfTwo()
        var workspace = panes.workspace
        _ = workspace.setRatio(at: SplitPath(), to: 0.2)

        let evened = workspace.equalize(tabContaining: panes.visibleRight)

        #expect(evened)
        #expect(workspace.focusedTab?.tree.ratio(at: SplitPath()) == 0.5)
        #expect(workspace.focusedPane == panes.visibleLeft)
    }

    // Rule 2: the heir rule is the closed pane's own, and a background close does
    // not spend it.

    @Test func closingAPaneThatIsNotFocusedLeavesTheCursorWhereItWas() {
        let panes = ThreePanesInARow()
        var workspace = panes.workspace

        let closed = workspace.close(pane: panes.right)

        // The heir rule exists to put the cursor where the cursor already was. The
        // cursor was never in the closed pane, so there is nothing to put back, and
        // spending the rule anyway would move the owner into `middle`.
        #expect(closed)
        #expect(workspace.focusedPane == panes.left)
        #expect(workspace.focusedTab?.tree.paneIDs == [panes.left, panes.middle])
    }

    @Test func closingTheFocusedPaneFocusesTheSiblingThatTookItsSpace() {
        let panes = ThreePanesInARow()
        var workspace = panes.workspace
        _ = workspace.focusPane(panes.right)

        let closed = workspace.close(pane: panes.right)

        #expect(closed)
        #expect(workspace.focusedPane == panes.middle)
    }

    // Rule 3: no mutation clears a zoom belonging to another pane.

    @Test func splittingIntoATabAnotherPaneHasZoomedIsRefused() {
        let panes = ZoomedTab()
        var workspace = panes.workspace
        let before = workspace

        let split = workspace.split(pane: panes.middle, axis: .vertical, newPane: PaneID(), ratio: 0.5)

        // A zoomed tab shows one pane, so this split would be invisible until the
        // owner's zoom was cleared. Refusing is the only answer that neither lies
        // about the layout nor unzooms someone else's view; the caller turns the
        // false into `refused`.
        #expect(!split)
        #expect(workspace == before)
    }

    @Test func splittingTheZoomedPaneItselfClearsOnlyItsOwnZoom() {
        let panes = ZoomedTab()
        var workspace = panes.workspace
        let opened = PaneID()

        let split = workspace.split(pane: panes.zoomed, axis: .vertical, newPane: opened, ratio: 0.5)

        // The zoom being cleared is the caller's, and it has to be: focus moved into
        // the new pane, and zoom follows focus.
        #expect(split)
        #expect(workspace.focusedPane == opened)
        #expect(workspace.focusedTab?.zoomedPane == nil)
    }

    @Test func closingAPaneThatIsNotFocusedLeavesAnotherPanesZoomAlone() {
        let panes = ZoomedTab()
        var workspace = panes.workspace

        let closed = workspace.close(pane: panes.last)

        #expect(closed)
        #expect(workspace.focusedTab?.zoomedPane == panes.zoomed)
        #expect(workspace.focusedPane == panes.zoomed)
    }

    @Test func resizingATabAnotherPaneHasZoomedIsRefused() {
        let panes = ZoomedTab()
        var workspace = panes.workspace
        let before = workspace

        let grew = workspace.resize(pane: panes.middle, direction: .left, by: 0.1)

        // Same answer `resizeFocusedPane` gives: a zoomed tab shows no divider, so
        // there is nothing to move.
        #expect(!grew)
        #expect(workspace == before)
    }

    @Test func equalizingATabAnotherPaneHasZoomedIsRefused() {
        let panes = ZoomedTab()
        var workspace = panes.workspace
        let before = workspace

        let evened = workspace.equalize(tabContaining: panes.middle)

        #expect(!evened)
        #expect(workspace == before)
    }

    // A caller in a tab nobody is looking at is still addressable, and reaching it
    // does not bring it forward.

    @Test func splittingAPaneInABackgroundTabLandsThereWithoutSwitchingTabs() {
        let panes = TwoTabsOfTwo()
        var workspace = panes.workspace
        let opened = PaneID()

        let split = workspace.split(
            pane: panes.backgroundLeft,
            axis: .vertical,
            newPane: opened,
            ratio: 0.5
        )

        #expect(split)
        #expect(workspace.focusedTabIndex == 0)
        #expect(workspace.tabs[1].tree.paneIDs == [panes.backgroundLeft, opened, panes.backgroundRight])
        #expect(workspace.tabs[0].tree.paneIDs == [panes.visibleLeft, panes.visibleRight])
    }

    @Test func splittingAFocusedPaneOfABackgroundTabMovesOnlyThatTabsFocus() {
        let panes = TwoTabsOfTwo()
        var workspace = panes.workspace
        let opened = PaneID()

        _ = workspace.split(pane: panes.backgroundLeft, axis: .vertical, newPane: opened, ratio: 0.5)

        // Focus is per tab, so the background tab remembers the new pane for when the
        // user comes back, and the tab they are actually in is untouched.
        #expect(workspace.tabs[1].focusedPane == opened)
        #expect(workspace.focusedPane == panes.visibleLeft)
    }

    @Test func resizingAPaneInABackgroundTabMovesThatTabsDivider() {
        let panes = TwoTabsOfTwo()
        var workspace = panes.workspace

        let grew = workspace.resize(pane: panes.backgroundLeft, direction: .right, by: 0.1)

        #expect(grew)
        #expect(workspace.tabs[1].tree.ratio(at: SplitPath()) == 0.6)
        #expect(workspace.tabs[0].tree.ratio(at: SplitPath()) == 0.5)
        #expect(workspace.focusedTabIndex == 0)
    }

    @Test func equalizingByAPaneInABackgroundTabEvensThatTab() {
        let panes = TwoTabsOfTwo()
        var workspace = panes.workspace
        workspace.tabs[1].tree = .split(
            axis: .horizontal,
            ratio: 0.2,
            first: .leaf(panes.backgroundLeft),
            second: .leaf(panes.backgroundRight)
        )

        let evened = workspace.equalize(tabContaining: panes.backgroundRight)

        #expect(evened)
        #expect(workspace.tabs[1].tree.ratio(at: SplitPath()) == 0.5)
        #expect(workspace.focusedTabIndex == 0)
    }

    @Test func closingTheOnlyPaneOfABackgroundTabClosesItAndKeepsTheUserInTheirTab() {
        let panes = TwoTabsOfTwo()
        var workspace = panes.workspace
        let alone = PaneID()
        workspace.tabs.insert(Tab(pane: alone), at: 0)
        workspace.focusedTabIndex = 1

        let closed = workspace.close(pane: alone)

        // The closed tab was to the left of the user's, so every tab after it slid one
        // slot left and the index has to follow. Leaving it alone would move the user
        // a tab to the right for closing something they were not looking at.
        #expect(closed)
        #expect(workspace.tabs.count == 2)
        #expect(workspace.focusedPane == panes.visibleLeft)
    }

    @Test func closingTheLastPaneOfTheLastTabIsRefused() {
        let alone = PaneID()
        var workspace = Workspace(pane: alone)
        let before = workspace

        let closed = workspace.close(pane: alone)

        #expect(!closed)
        #expect(workspace == before)
    }

    // A pane no tab holds is not a target, and saying so is what keeps a stale id
    // from landing somewhere arbitrary.

    @Test func mutatingAPaneNoTabHoldsChangesNothing() {
        let panes = TwoTabsOfTwo()
        var workspace = panes.workspace
        let before = workspace
        let stranger = PaneID()

        let split = workspace.split(pane: stranger, axis: .vertical, newPane: PaneID(), ratio: 0.5)
        let closed = workspace.close(pane: stranger)
        let grew = workspace.resize(pane: stranger, direction: .left, by: 0.1)
        let evened = workspace.equalize(tabContaining: stranger)

        #expect(!split)
        #expect(!closed)
        #expect(!grew)
        #expect(!evened)
        #expect(workspace == before)
    }

    // A move, which is the one mutator that changes where a pane sits without
    // changing which panes exist.

    @Test func movingAPaneRearrangesItsTabAndMovesNobodysFocus() {
        let panes = ThreePanesInARow()
        var workspace = panes.workspace

        let moved = workspace.move(
            pane: panes.right,
            beside: panes.left,
            axis: .vertical,
            before: false
        )

        #expect(moved)
        // Visual order, so this says where the pane went and not merely that
        // something changed: `right` now sits under `left`, ahead of `middle`.
        #expect(workspace.tabs[0].tree.paneIDs == [panes.left, panes.right, panes.middle])
        // Focus is untouched for `resize`'s reason: the caller can be a pane
        // nobody is looking at, and rearranging panes is never a reason to move a
        // cursor that is somewhere else.
        #expect(workspace.focusedPane == panes.left)
    }

    @Test func movingAPaneInABackgroundTabLandsThereWithoutSwitchingTabs() {
        let panes = TwoTabsOfTwo()
        var workspace = panes.workspace

        let moved = workspace.move(
            pane: panes.backgroundRight,
            beside: panes.backgroundLeft,
            axis: .vertical,
            before: false
        )

        #expect(moved)
        #expect(workspace.focusedTabIndex == 0)
        #expect(workspace.tabs[1].tree == .split(
            axis: .vertical,
            ratio: 0.5,
            first: .leaf(panes.backgroundLeft),
            second: .leaf(panes.backgroundRight)
        ))
        #expect(workspace.tabs[0].tree == panes.workspace.tabs[0].tree)
    }

    @Test func movingWithinATabAnotherPaneHasZoomedIsRefused() {
        let panes = ZoomedTab()
        var workspace = panes.workspace
        let before = workspace

        let moved = workspace.move(
            pane: panes.last,
            beside: panes.middle,
            axis: .vertical,
            before: true
        )

        // `resize`'s answer for `resize`'s reason: a zoomed tab shows one pane, so
        // the rearrangement would be invisible until a zoom this caller does not
        // own was cleared. Refused rather than unzoomed, matching `split`.
        #expect(!moved)
        #expect(workspace == before)
    }

    @Test func movingBesideAPaneInAnotherTabIsRefused() {
        let panes = TwoTabsOfTwo()
        var workspace = panes.workspace
        let before = workspace

        let moved = workspace.move(
            pane: panes.visibleLeft,
            beside: panes.backgroundLeft,
            axis: .horizontal,
            before: false
        )

        // A move is one tree's operation. Carrying a pane between tabs would let
        // one empty out, which is a tab close nobody asked for, so the tab holding
        // the pane is the only tree consulted and a target it does not hold reads
        // as a target that does not exist.
        #expect(!moved)
        #expect(workspace == before)
    }

    @Test func aPaneResolvesToTheTabThatHoldsIt() {
        let panes = TwoTabsOfTwo()
        let workspace = panes.workspace

        #expect(workspace.tabIndex(containing: panes.visibleRight) == 0)
        #expect(workspace.tabIndex(containing: panes.backgroundRight) == 1)
        #expect(workspace.tabIndex(containing: PaneID()) == nil)
    }
}
