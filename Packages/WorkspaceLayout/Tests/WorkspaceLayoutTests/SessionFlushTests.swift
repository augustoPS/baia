import Foundation
import Testing

@testable import WorkspaceLayout

/// The one-second window between the last window closing and the app writing its
/// session file.
///
/// Every test here is that sequence in the order the app runs it: the owner
/// changes something, the write is coalesced onto a timer, the window closes and
/// empties the window list, and the flush at termination arrives to find nothing
/// to snapshot. Before ``SessionFlush`` that flush wrote nothing and the change
/// was lost.
@Suite struct SessionFlushTests {
    /// Two snapshots that cannot be confused for one another, since every
    /// assertion here is about *which* one was written.
    private func snapshot(width: Double) -> SessionSnapshot {
        singleGroupSnapshot(
            workspace: Workspace(tabs: [Tab(pane: PaneID())], focusedTabIndex: 0),
            panes: [],
            windowFrame: WindowFrame(x: 0, y: 0, width: width, height: 600),
            sidebar: nil,
            fileTreeExpansions: nil
        )
    }

    // MARK: The bug

    /// **The regression.** A change coalesced in the last second, then the last
    /// window closing, then the terminate flush: the change lands.
    @Test func aWriteCoalescedBeforeTheLastWindowClosesStillLands() {
        var flush = SessionFlush()
        let lastSecond = snapshot(width: 1400)

        // The window is on its way out and the app takes its final reading.
        flush.hold(lastSecond)
        // `applicationWillTerminate` flushes, and by now `windows` is empty.
        let written = flush.resolve(live: nil)

        #expect(written == lastSecond)
    }

    /// The half that has to survive the fix: an empty workspace with nothing held
    /// writes nothing at all. A save that answered with an empty snapshot here
    /// would erase the session that a relaunch is supposed to restore.
    @Test func anEmptyWorkspaceWithNothingHeldWritesNothing() {
        var flush = SessionFlush()

        #expect(flush.resolve(live: nil) == nil)
    }

    /// A held snapshot answers once. A second flush finds nothing, because the
    /// moment it described has passed: answering again would rewrite a workspace
    /// the app has already left, and a window closed two launches ago would come
    /// back.
    @Test func aHeldSnapshotIsWrittenOnceAndNotAgain() {
        var flush = SessionFlush()
        flush.hold(snapshot(width: 1400))

        #expect(flush.resolve(live: nil) != nil)
        flush.didSave()
        #expect(flush.resolve(live: nil) == nil)
    }

    @Test func aHeldSnapshotSurvivesAFailedWriteForRetry() {
        var flush = SessionFlush()
        let held = snapshot(width: 1400)
        flush.hold(held)

        #expect(flush.resolve(live: nil) == held)
        // No didSave: the store refused or failed this write.
        #expect(flush.resolve(live: nil) == held)
    }

    // MARK: The ordinary path

    /// With a window still open, the live workspace wins. It is newer than
    /// anything held, by construction: the hold happens on the way out of the last
    /// window and a live snapshot is taken now.
    @Test func aLiveWorkspaceBeatsAnythingHeld() {
        var flush = SessionFlush()
        let stale = snapshot(width: 1400)
        let live = snapshot(width: 900)

        flush.hold(stale)

        #expect(flush.resolve(live: live) == live)
    }

    /// And it clears what was held. Closing one window of several holds nothing,
    /// but a window reopened after the last one closed must not leave a snapshot
    /// primed to overwrite the session on some later quit.
    @Test func aLiveWorkspaceDropsWhatWasHeld() {
        var flush = SessionFlush()
        flush.hold(snapshot(width: 1400))

        // A window opens again and a save runs while it is up.
        _ = flush.resolve(live: snapshot(width: 900))
        flush.didSave()
        // That window closes without anything being held for it, which is what
        // happens when it is not the last one, or when nothing changed.
        #expect(flush.resolve(live: nil) == nil)
    }

    /// Saves during a normal session neither hold nor consume anything, so the
    /// common path costs nothing and cannot accumulate state.
    @Test func ordinarySavesLeaveNothingBehind() {
        var flush = SessionFlush()
        let live = snapshot(width: 900)

        for _ in 0 ..< 5 {
            #expect(flush.resolve(live: live) == live)
        }
        #expect(flush == SessionFlush())
    }
}
