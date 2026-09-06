import Foundation
import Testing

@testable import WorkspaceLayout

/// The window between reading the session file at launch and opening what it
/// describes, once that reconciliation runs off the main thread.
///
/// Every test is a sequence the app can run: launch begins a restore, something
/// asks to save (autosave, the terminate flush, a Debug driver) before the
/// reconciled snapshot has come back, and then the result arrives, or never does
/// because the app quit first. The rule is that nothing may overwrite the file
/// the restore is still reading from, and a result may be applied at most once
/// and only if it is the one still expected.
@Suite struct SessionRestoreGateTests {
    @Test func aFreshGateAllowsSaves() {
        let gate = SessionRestoreGate()

        #expect(gate.allowsSave)
        #expect(!gate.isPending)
    }

    // MARK: Save preservation

    /// **The overwrite hole.** Windows opened while the restore is pending must
    /// not be written over the file the restore came from.
    @Test func aPendingRestoreRefusesSaves() {
        var gate = SessionRestoreGate()
        _ = gate.begin()

        #expect(gate.isPending)
        #expect(!gate.allowsSave)
    }

    @Test func completingThePendingRestoreReopensSaves() {
        var gate = SessionRestoreGate()
        let generation = gate.begin()

        let applied = gate.complete(generation)

        #expect(applied)
        #expect(gate.allowsSave)
        #expect(!gate.isPending)
    }

    @Test func cancellingThePendingRestoreReopensSaves() {
        var gate = SessionRestoreGate()
        _ = gate.begin()
        gate.cancel()

        #expect(gate.allowsSave)
        #expect(!gate.isPending)
    }

    // MARK: Late results

    /// The result is applied once. A second completion of the same generation
    /// is not a second restore.
    @Test func aGenerationCompletesAtMostOnce() {
        var gate = SessionRestoreGate()
        let generation = gate.begin()

        let first = gate.complete(generation)
        let second = gate.complete(generation)

        #expect(first)
        #expect(!second)
    }

    /// Quit during the wait: the process is on its way out and the file is
    /// untouched. A result that lands afterwards is discarded.
    @Test func aCancelledGenerationIsDiscardedWhenItCompletes() {
        var gate = SessionRestoreGate()
        let generation = gate.begin()
        gate.cancel()

        let applied = gate.complete(generation)

        #expect(!applied)
        #expect(gate.allowsSave)
    }

    /// Only the newest restore is expected. An older generation's late result
    /// cannot apply over the one that superseded it, and it does not reopen
    /// saves while the newer one is still pending.
    @Test func aSupersededGenerationIsDiscardedAndTheNewestStillPends() {
        var gate = SessionRestoreGate()
        let first = gate.begin()
        let second = gate.begin()

        let staleApplied = gate.complete(first)
        let stillPending = gate.isPending
        let saveWhileNewestPends = gate.allowsSave
        let newestApplied = gate.complete(second)

        #expect(!staleApplied)
        #expect(stillPending)
        #expect(!saveWhileNewestPends)
        #expect(newestApplied)
        #expect(gate.allowsSave)
    }

    @Test func generationsAreDistinct() {
        var gate = SessionRestoreGate()
        let first = gate.begin()
        gate.cancel()
        let second = gate.begin()

        #expect(first != second)
    }
}
