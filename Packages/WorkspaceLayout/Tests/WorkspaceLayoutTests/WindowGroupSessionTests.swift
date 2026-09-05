import Foundation
import Testing

@testable import WorkspaceLayout

/// The R05 fixtures: **two actual groups**, not one flat tab list.
///
/// The audit's coverage note is what this suite answers. Every earlier session test
/// built a single-group snapshot, so they "preserve only the representation they
/// were given" and could not have caught the loss: a schema that cannot express two
/// groups round trips a one-group fixture perfectly. So every fixture here holds two
/// groups with different frames, different tab counts and different selections, and
/// the assertions are about telling them apart.
@Suite struct WindowGroupSessionTests {
    /// Two groups that cannot be confused: the left one has two tabs and selects the
    /// second, the right one has one tab, and their frames do not overlap.
    ///
    /// Built by hand rather than through a mutator, so a bug in ``Workspace`` cannot
    /// make a persistence test pass.
    private func twoGroups() -> (snapshot: SessionSnapshot, left: WindowGroup, right: WindowGroup) {
        let a = PaneID()
        let b = PaneID()
        let c = PaneID()
        let firstTab = Tab(
            id: UUID(),
            tree: .split(axis: .horizontal, ratio: 0.35, first: .leaf(a), second: .leaf(b)),
            focusedPane: b,
            zoomedPane: nil
        )
        let secondTab = Tab(pane: c)
        let detached = Tab(pane: PaneID())

        let left = WindowGroup(
            id: UUID(),
            tabs: [firstTab, secondTab],
            selectedTab: secondTab.id,
            frame: WindowFrame(x: 0, y: 0, width: 1200, height: 800),
            sidebar: SidebarGeometry(width: 320, splitHeight: 180)
        )
        let right = WindowGroup(
            id: UUID(),
            tabs: [detached],
            selectedTab: detached.id,
            frame: WindowFrame(x: 1400, y: 220, width: 900, height: 640),
            // Deliberately different from the left group's: one session-wide sidebar
            // could not have held both, and that is the second half of the R05 loss.
            sidebar: SidebarGeometry(width: 240, splitHeight: 400)
        )
        let snapshot = SessionSnapshot(
            groups: [left, right],
            activeGroup: right.id,
            panes: (left.paneIDs + right.paneIDs).map {
                PaneState(id: $0, workingDirectory: "/here", pinnedDirectory: nil, createdBy: nil)
            },
            fileTreeExpansions: nil
        )
        return (snapshot, left, right)
    }

    // MARK: The defect

    /// **The regression.** Two separately positioned groups survive the file as two
    /// groups, each keeping its own frame, tab order and selection.
    ///
    /// Before this schema the snapshot held one flat `[Tab]` and one `windowFrame`,
    /// so this fixture would come back as a single group of three tabs at one frame.
    @Test func twoSeparatelyPositionedGroupsSurviveTheFile() throws {
        let (snapshot, left, right) = twoGroups()

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        #expect(decoded == snapshot)
        #expect(decoded.groups.count == 2)
        #expect(decoded.groups[0].frame == left.frame)
        #expect(decoded.groups[1].frame == right.frame)
        // Not merged into one list, which is the exact shape the old schema forced.
        #expect(decoded.groups.map(\.tabs.count) == [2, 1])
    }

    /// The selection is per group, and the two groups disagree about which tab is
    /// showing. One session-wide index could not have carried this.
    @Test func eachGroupKeepsItsOwnSelectedTab() throws {
        let (snapshot, left, right) = twoGroups()

        let decoded = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: try JSONEncoder().encode(snapshot)
        )

        #expect(decoded.groups[0].selectedTab == left.tabs[1].id)
        #expect(decoded.groups[0].selected?.id == left.tabs[1].id)
        #expect(decoded.groups[1].selectedTab == right.tabs[0].id)
    }

    /// The keyboard comes back in the group it was in, which here is the detached
    /// one rather than the first in the list.
    @Test func theActiveGroupIsTheOneThatHeldTheKeyboard() throws {
        let (snapshot, _, right) = twoGroups()

        let decoded = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: try JSONEncoder().encode(snapshot)
        )

        #expect(decoded.activeGroup == right.id)
        #expect(decoded.active?.id == right.id)
        #expect(decoded.selectedPane == right.tabs[0].focusedPane)
    }

    /// A tab dragged out of a group becomes its own group with its own frame, and
    /// the group it left keeps the tabs it still has in their order.
    @Test func aDetachedTabIsItsOwnGroupAndTheOriginalKeepsTheRest() throws {
        let (snapshot, left, _) = twoGroups()
        var detaching = snapshot
        let moved = left.tabs[1]

        // What a drag-out produces: the tab leaves one group and arrives as a group.
        detaching.groups[0].tabs = [left.tabs[0]]
        detaching.groups[0].selectedTab = left.tabs[0].id
        detaching.groups.append(
            WindowGroup(id: UUID(), tabs: [moved], selectedTab: moved.id,
                        frame: WindowFrame(x: 300, y: 300, width: 700, height: 500),
                        sidebar: nil)
        )

        let decoded = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: try JSONEncoder().encode(detaching)
        )

        #expect(decoded.groups.count == 3)
        #expect(decoded.groups[0].tabs.map(\.id) == [left.tabs[0].id])
        #expect(decoded.groups[2].tabs.map(\.id) == [moved.id])
        #expect(decoded.groups[2].frame?.x == 300)
    }

    /// Reordering within one group is a permutation of that group's tabs and touches
    /// nothing else. The id-based selection follows the tab rather than the slot.
    @Test func reorderingTabsInOneGroupKeepsTheSelectionOnTheSameTab() throws {
        let (snapshot, left, _) = twoGroups()
        var reordered = snapshot
        reordered.groups[0].tabs = [left.tabs[1], left.tabs[0]]

        let decoded = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: try JSONEncoder().encode(reordered)
        )

        #expect(decoded.groups[0].tabs.map(\.id) == [left.tabs[1].id, left.tabs[0].id])
        // Still the same tab, now first rather than second. An index would have
        // followed the slot and quietly selected the other tab.
        #expect(decoded.groups[0].selected?.id == left.tabs[1].id)
        #expect(decoded.groups[1].tabs.map(\.id) == snapshot.groups[1].tabs.map(\.id))
    }

    /// **The second half of the R05 loss.** Each group keeps its own sidebar width,
    /// which one session-level number could not hold: the file recorded the focused
    /// window's and restored it to every window, so dragging one column wide resized
    /// the other on the next launch.
    @Test func eachGroupKeepsItsOwnSidebarGeometry() throws {
        let (snapshot, left, right) = twoGroups()

        let decoded = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: try JSONEncoder().encode(snapshot)
        )

        #expect(decoded.groups[0].sidebar == left.sidebar)
        #expect(decoded.groups[1].sidebar == right.sidebar)
        #expect(decoded.groups[0].sidebar != decoded.groups[1].sidebar)
    }

    /// A group that never opened a sidebar records none, and the group beside it
    /// keeps its own rather than inheriting or imposing one.
    @Test func aGroupWithNoSidebarDoesNotTakeItsNeighboursOne() throws {
        let (snapshot, _, _) = twoGroups()
        var mixed = snapshot
        mixed.groups[1].sidebar = nil

        let decoded = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: try JSONEncoder().encode(mixed)
        )

        #expect(decoded.groups[0].sidebar?.width == 320)
        #expect(decoded.groups[1].sidebar == nil)
    }

    /// Reconciliation carries each group's sidebar through, which is the field that
    /// was once dropped in exactly this rebuild.
    @Test func eachGroupsSidebarSurvivesReconciliation() {
        let (snapshot, left, right) = twoGroups()

        let (reconciled, _) = SessionStore.reconciled(
            snapshot,
            directoryExists: { _ in true },
            resolveAnchor: { $0.workingDirectory }
        )

        #expect(reconciled.groups[0].sidebar == left.sidebar)
        #expect(reconciled.groups[1].sidebar == right.sidebar)
    }

    // MARK: Missing directories

    /// A group whose every pane's directory vanished is dropped whole, and the other
    /// group is untouched. An empty window would restore a frame with nothing in it.
    @Test func aGroupWhoseEveryDirectoryVanishedIsDroppedAndTheOtherSurvives() {
        let (snapshot, left, right) = twoGroups()
        var mixed = snapshot
        mixed.panes = snapshot.panes.map { pane in
            var moved = pane
            moved.workingDirectory = right.paneIDs.contains(pane.id) ? "/gone" : "/here"
            return moved
        }

        let (reconciled, dropped) = SessionStore.reconciled(
            mixed,
            directoryExists: { $0 == "/here" },
            resolveAnchor: { $0.workingDirectory }
        )

        #expect(reconciled.groups.count == 1)
        #expect(reconciled.groups[0].id == left.id)
        #expect(Set(dropped) == Set(right.paneIDs))
        // The keyboard was in the group that went, so it lands in the one that is
        // left rather than naming a window that does not exist.
        #expect(reconciled.activeGroup == left.id)
    }

    /// Losing one tab's panes leaves the group, its other tab, and its frame.
    @Test func aGroupSurvivesLosingOneOfItsTabs() throws {
        let (snapshot, left, _) = twoGroups()
        let firstTabPanes = Set(left.tabs[0].tree.paneIDs)
        var mixed = snapshot
        mixed.panes = snapshot.panes.map { pane in
            var moved = pane
            moved.workingDirectory = firstTabPanes.contains(pane.id) ? "/gone" : "/here"
            return moved
        }

        let (reconciled, _) = SessionStore.reconciled(
            mixed,
            directoryExists: { $0 == "/here" },
            resolveAnchor: { $0.workingDirectory }
        )

        let survivor = try #require(reconciled.groups.first { $0.id == left.id })
        #expect(survivor.tabs.map(\.id) == [left.tabs[1].id])
        #expect(survivor.frame == left.frame)
        #expect(survivor.selectedTab == left.tabs[1].id)
    }

    /// Everything vanishing yields no groups and nothing claiming to be active,
    /// which the caller already handles as a first launch.
    @Test func everyGroupVanishingIsNoGroupsRatherThanNothing() {
        let (snapshot, _, _) = twoGroups()

        let (reconciled, dropped) = SessionStore.reconciled(
            snapshot,
            directoryExists: { _ in false },
            resolveAnchor: { $0.workingDirectory }
        )

        #expect(reconciled.groups.isEmpty)
        #expect(reconciled.activeGroup == nil)
        #expect(dropped.count == snapshot.shownPaneIDs.count)
    }

    /// A group that is still whole comes back byte-identical, so reconciliation
    /// cannot be quietly rebuilding a field it forgot to carry.
    @Test func groupsThatAreStillGoodComeBackUnchanged() {
        let (snapshot, _, _) = twoGroups()

        let (reconciled, dropped) = SessionStore.reconciled(
            snapshot,
            directoryExists: { _ in true },
            resolveAnchor: { $0.workingDirectory }
        )

        #expect(reconciled == snapshot)
        #expect(dropped.isEmpty)
    }
}
