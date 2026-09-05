import Foundation

/// One pane's report authority and the exact future turn where it expires.
///
/// The store, its published revision and its timer live together so a caller
/// cannot replace one without cancelling the deadline owned by the other.
/// Accept and release are synchronous; ``onExpiry`` is reserved for the one
/// transition that has no incoming event to publish it.
@MainActor
public final class ReportTimeline {
    public var onExpiry: ((ReportRevision) -> Void)?

    public private(set) var revision = ReportStore().revision(at: .distantPast)

    private var store = ReportStore()
    private var timer: Timer?

    public init() {}

    /// Records a report and arms the effective store's deadline.
    ///
    /// Re-arming also happens for a superseded input. If the accepted report is
    /// still live its deadline stays the same; if it elapsed before this turn,
    /// the obsolete timer is cancelled instead of remaining queued.
    @discardableResult
    public func accept(_ report: PaneReport) -> ReportStore.Acceptance {
        let acceptance = store.accept(report)
        revision = store.revision(at: Date())
        scheduleCurrentDeadline()
        return acceptance
    }

    /// Hands authority back immediately and cancels the future transition.
    public func release() {
        store.release()
        timer?.invalidate()
        timer = nil
        revision = store.revision(at: Date())
    }

    /// Cancels owned work at pane teardown without changing its final evidence.
    public func cancel() {
        timer?.invalidate()
        timer = nil
    }

    private func scheduleCurrentDeadline() {
        timer?.invalidate()
        timer = nil
        guard let deadline = revision.nextExpiry else { return }
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deadlineReached()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Revalidates before publishing, fencing an early or already-queued timer.
    private func deadlineReached() {
        let next = store.revision(at: Date())
        if next.nextExpiry != nil {
            revision = next
            scheduleCurrentDeadline()
            return
        }
        timer?.invalidate()
        timer = nil
        guard next != revision else { return }
        revision = next
        onExpiry?(next)
    }

    isolated deinit {
        timer?.invalidate()
    }
}
