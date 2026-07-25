import Foundation
import Testing

@testable import WorkspaceLayout

@Suite final class SessionReconciliationTests {
    let fixture: DirectoryFixture

    init() throws {
        fixture = try DirectoryFixture()
    }

    /// A snapshot of one tab with two panes side by side, each with a working
    /// directory, focus on the second.
    private func twoPaneSnapshot(
        first: PaneID,
        second: PaneID,
        firstDirectory: String,
        secondDirectory: String
    ) -> SessionSnapshot {
        SessionSnapshot(
            workspace: Workspace(
                tabs: [Tab(
                    id: UUID(),
                    tree: .split(axis: .horizontal, ratio: 0.5, first: .leaf(first), second: .leaf(second)),
                    focusedPane: second,
                    zoomedPane: nil
                )],
                focusedTabIndex: 0
            ),
            panes: [
                PaneState(id: first, workingDirectory: firstDirectory, pinnedDirectory: nil),
                PaneState(id: second, workingDirectory: secondDirectory, pinnedDirectory: nil),
            ],
            windowFrame: nil
        )
    }

    /// Says yes to exactly the paths listed. A closure over a set rather than a
    /// directory tree, so a test about focus repair does not also depend on what the
    /// filesystem did.
    private func existing(_ paths: String...) -> (String) -> Bool {
        let known = Set(paths)
        return { known.contains($0) }
    }

    @Test func aPaneWhoseDirectoryVanishedIsDroppedAndReported() {
        let kept = PaneID()
        let gone = PaneID()
        let snapshot = twoPaneSnapshot(
            first: kept,
            second: gone,
            firstDirectory: "/kept",
            secondDirectory: "/gone"
        )

        let result = SessionStore.reconciled(snapshot, directoryExists: existing("/kept"))

        #expect(result.droppedPanes == [gone])
        #expect(result.snapshot.workspace.tabs[0].tree == .leaf(kept))
        #expect(result.snapshot.panes.map(\.id) == [kept])
    }

    @Test func droppingTheFocusedPaneMovesFocusToOneThatIsStillThere() {
        let kept = PaneID()
        let gone = PaneID()
        let snapshot = twoPaneSnapshot(
            first: kept,
            second: gone,
            firstDirectory: "/kept",
            secondDirectory: "/gone"
        )

        let result = SessionStore.reconciled(snapshot, directoryExists: existing("/kept"))

        // The dropped pane was the focused one. Leaving focus on it would give a
        // workspace where every mutator returns false, so no key could recover it.
        #expect(result.snapshot.workspace.focusedPane == kept)
    }

    @Test func aPaneWithNoRecordedDirectoryIsKept() {
        let never = PaneID()
        let snapshot = SessionSnapshot(
            workspace: Workspace(pane: never),
            panes: [PaneState(id: never, workingDirectory: nil, pinnedDirectory: nil)],
            windowFrame: nil
        )

        // Nil means the pane's surface had not come up when the session was written,
        // not that its directory is gone. Dropping it would make an early quit lose
        // every pane in the window.
        let result = SessionStore.reconciled(snapshot, directoryExists: { _ in false })

        #expect(result.droppedPanes.isEmpty)
        #expect(result.snapshot.workspace.tabs[0].tree == .leaf(never))
    }

    @Test func aPinnedDirectoryThatVanishedIsClearedWithoutDroppingThePane() {
        let pane = PaneID()
        let snapshot = SessionSnapshot(
            workspace: Workspace(pane: pane),
            panes: [PaneState(id: pane, workingDirectory: "/here", pinnedDirectory: "/gone")],
            windowFrame: nil
        )

        let result = SessionStore.reconciled(snapshot, directoryExists: existing("/here"))

        // A pin is a preference about a pane, not its reason to exist, and
        // `AnchorResolver` already treats a stale pin as data to repair.
        #expect(result.droppedPanes.isEmpty)
        #expect(result.snapshot.panes == [PaneState(id: pane, workingDirectory: "/here", pinnedDirectory: nil)])
    }

    @Test func aTabWhoseEveryPaneVanishedIsRemoved() {
        let firstTabPane = PaneID()
        let survivor = PaneID()
        let snapshot = SessionSnapshot(
            workspace: Workspace(
                tabs: [Tab(pane: firstTabPane), Tab(pane: survivor)],
                focusedTabIndex: 0
            ),
            panes: [
                PaneState(id: firstTabPane, workingDirectory: "/gone", pinnedDirectory: nil),
                PaneState(id: survivor, workingDirectory: "/here", pinnedDirectory: nil),
            ],
            windowFrame: nil
        )

        let result = SessionStore.reconciled(snapshot, directoryExists: existing("/here"))

        #expect(result.snapshot.workspace.tabs.count == 1)
        #expect(result.snapshot.workspace.focusedPane == survivor)
    }

    @Test func aSessionWhereEverythingVanishedIsAnEmptyWorkspaceRatherThanNothing() {
        let first = PaneID()
        let second = PaneID()
        let snapshot = twoPaneSnapshot(
            first: first,
            second: second,
            firstDirectory: "/gone",
            secondDirectory: "/also-gone"
        )

        let result = SessionStore.reconciled(snapshot, directoryExists: { _ in false })

        // Nil would make the caller handle a second "no session" case that behaves
        // exactly like the first launch it already handles. An empty workspace with an
        // in-range index is launchable as it stands.
        #expect(result.snapshot.workspace.tabs.isEmpty)
        #expect(result.snapshot.workspace.focusedTabIndex == 0)
        #expect(result.droppedPanes == [first, second])
    }

    @Test func aFocusedTabIndexPastTheEndIsBroughtBackIntoRange() {
        let snapshot = SessionSnapshot(
            workspace: Workspace(tabs: [Tab(pane: PaneID()), Tab(pane: PaneID())], focusedTabIndex: 9),
            panes: [],
            windowFrame: nil
        )

        let result = SessionStore.reconciled(snapshot, directoryExists: { _ in true })

        // Clamped to the last tab rather than reset to the first: losing a tab at the
        // end should not also move the user to the other end of the tab bar.
        #expect(result.snapshot.workspace.focusedTabIndex == 1)
        #expect(result.snapshot.workspace.focusedTab != nil)
    }

    @Test func aNegativeFocusedTabIndexIsBroughtBackIntoRange() {
        let snapshot = SessionSnapshot(
            workspace: Workspace(tabs: [Tab(pane: PaneID())], focusedTabIndex: -3),
            panes: [],
            windowFrame: nil
        )

        let result = SessionStore.reconciled(snapshot, directoryExists: { _ in true })

        #expect(result.snapshot.workspace.focusedTabIndex == 0)
    }

    @Test func aZoomOnAPaneThatVanishedIsCleared() {
        let kept = PaneID()
        let gone = PaneID()
        var snapshot = twoPaneSnapshot(
            first: kept,
            second: gone,
            firstDirectory: "/kept",
            secondDirectory: "/gone"
        )
        snapshot.workspace.tabs[0].zoomedPane = gone

        let result = SessionStore.reconciled(snapshot, directoryExists: existing("/kept"))

        // A zoom pointing at a pane nothing will create renders as an empty tab, and
        // the pane that is there never gets laid out at all.
        #expect(result.snapshot.workspace.tabs[0].zoomedPane == nil)
    }

    @Test func aZoomOnAPaneThatIsNoLongerFocusedIsCleared() {
        let kept = PaneID()
        let gone = PaneID()
        var snapshot = twoPaneSnapshot(
            first: kept,
            second: gone,
            firstDirectory: "/kept",
            secondDirectory: "/gone"
        )
        // The zoom is on the pane that survives, but focus was on the one that did not.
        // Both come back pointing at the survivor or the zoom is a pane on screen with
        // the cursor somewhere else, which is the invariant Workspace keeps.
        snapshot.workspace.tabs[0].zoomedPane = kept

        let result = SessionStore.reconciled(snapshot, directoryExists: existing("/kept"))

        #expect(result.snapshot.workspace.tabs[0].zoomedPane == kept)
        #expect(result.snapshot.workspace.focusedPane == kept)
    }

    @Test func aPaneStateNoTabShowsIsDroppedWithoutBeingReported() {
        let shown = PaneID()
        let leftover = PaneID()
        let snapshot = SessionSnapshot(
            workspace: Workspace(pane: shown),
            panes: [
                PaneState(id: shown, workingDirectory: "/here", pinnedDirectory: nil),
                PaneState(id: leftover, workingDirectory: "/gone", pinnedDirectory: nil),
            ],
            windowFrame: nil
        )

        let result = SessionStore.reconciled(snapshot, directoryExists: existing("/here"))

        // Reporting it would name a pane the caller was never going to create, and the
        // caller's list of dropped panes is what it uses to tell the user what it
        // could not restore.
        #expect(result.droppedPanes.isEmpty)
        #expect(result.snapshot.panes.map(\.id) == [shown])
    }

    @Test func aSessionThatIsStillGoodComesBackUnchanged() {
        let first = PaneID()
        let second = PaneID()
        let snapshot = twoPaneSnapshot(
            first: first,
            second: second,
            firstDirectory: "/one",
            secondDirectory: "/two"
        )

        let result = SessionStore.reconciled(snapshot, directoryExists: existing("/one", "/two"))

        // The test that keeps every repair above honest: a reconcile that rebuilt the
        // tree, resorted the panes, or reset focus unconditionally would pass all of
        // them and fail this one.
        #expect(result.snapshot == snapshot)
        #expect(result.droppedPanes.isEmpty)
    }

    @Test func reconcilingAgainstTheRealFilesystemDropsTheDirectoryThatWasDeleted() throws {
        let kept = PaneID()
        let gone = PaneID()
        let keptDirectory = try fixture.directory("kept")
        let goneDirectory = fixture.root.appending(path: "deleted-since-the-last-launch")
        let snapshot = twoPaneSnapshot(
            first: kept,
            second: gone,
            firstDirectory: keptDirectory.path(percentEncoded: false),
            secondDirectory: goneDirectory.path(percentEncoded: false)
        )

        // The predicate the app actually passes, against a real tree. A set-backed
        // closure proves the repair logic; only this proves the repair logic is being
        // handed the shape of path `FileManager` agrees with, trailing slash and all.
        let result = SessionStore.reconciled(snapshot) {
            FileManager.default.fileExists(atPath: $0)
        }

        #expect(result.droppedPanes == [gone])
        #expect(result.snapshot.workspace.tabs[0].tree == .leaf(kept))
    }
}
