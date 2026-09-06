import Foundation
import Testing

@testable import GitWorkspace

/// Thread-safe observations for the filesystem executor tests. The seams block
/// real worker operations; only the directory contents are scripted.
private final class FilesystemLog: @unchecked Sendable {
    private let lock = NSLock()
    private var startedValues: [String] = []
    private var finishedCount = 0
    private var mainThreadFlags: [Bool] = []

    var started: [String] { lock.withLock { startedValues } }
    var finished: Int { lock.withLock { finishedCount } }
    var ranOnMain: Bool { lock.withLock { mainThreadFlags.contains(true) } }

    func start(_ value: String) {
        lock.withLock {
            startedValues.append(value)
            mainThreadFlags.append(Thread.isMainThread)
        }
    }

    func finish() {
        lock.withLock { finishedCount += 1 }
    }
}

private final class RetainedFilesystemValue: @unchecked Sendable {}

private final class FilesystemTaskBox: @unchecked Sendable {
    var task: LatestFilesystemTask<String, String>?
}

@Suite(.serialized) @MainActor final class FilesystemExecutorTests {
    private func eventually(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The executor can be full even though this lane has not entered its
    /// operation. Cancelling that queued first submission must free the lane
    /// for a newer request without letting the cancelled input run first.
    @Test func cancellingAFirstSubmissionBlockedInTheExecutorPreventsFilesystemEntry() async {
        let executor = FilesystemExecutor(
            label: "pasqualotto.baia.tests.filesystem-queued-cancel",
            maxConcurrentOperations: 1
        )
        let blockerRelease = DispatchSemaphore(value: 0)
        let blockerLog = FilesystemLog()
        let blocker = LatestFilesystemTask<Int, Int>(executor: executor) { value in
            blockerLog.start(String(value))
            _ = blockerRelease.wait(timeout: .now() + 5)
            blockerLog.finish()
            return value
        }
        blocker.submit(0) { _ in }
        #expect(await eventually { blockerLog.started == ["0"] })

        let log = FilesystemLog()
        let task = LatestFilesystemTask<String, String>(executor: executor) { value in
            log.start(value)
            log.finish()
            return value
        }
        task.submit("cancelled") { _ in }
        task.cancelPending()

        let drainLog = FilesystemLog()
        let drain = LatestFilesystemTask<Int, Int>(executor: executor) { value in
            drainLog.start(String(value))
            drainLog.finish()
            return value
        }
        drain.submit(1) { _ in }

        blockerRelease.signal()
        #expect(await eventually { drainLog.finished == 1 })
        #expect(log.started.isEmpty)

        task.submit("current") { _ in }
        #expect(await eventually { log.finished == 1 })
        #expect(log.started == ["current"])
    }

    /// Cancellation must release the queued submission's input and completion
    /// capture while another lane still holds the only executor worker.
    @Test func cancellingAQueuedSubmissionReleasesItsCapturedValuesPromptly() async {
        let executor = FilesystemExecutor(
            label: "pasqualotto.baia.tests.filesystem-queued-retention",
            maxConcurrentOperations: 1
        )
        let blockerRelease = DispatchSemaphore(value: 0)
        let blockerLog = FilesystemLog()
        let blocker = LatestFilesystemTask<Int, Int>(executor: executor) { value in
            blockerLog.start(String(value))
            _ = blockerRelease.wait(timeout: .now() + 2)
            blockerLog.finish()
            return value
        }
        blocker.submit(0) { _ in }
        #expect(await eventually { blockerLog.started == ["0"] })

        let task = LatestFilesystemTask<RetainedFilesystemValue, Int>(executor: executor) { _ in 0 }
        var input: RetainedFilesystemValue? = RetainedFilesystemValue()
        var completionCapture: RetainedFilesystemValue? = RetainedFilesystemValue()
        weak let weakInput = input
        weak let weakCompletionCapture = completionCapture
        task.submit(input!) { [completionCapture] _ in
            _ = completionCapture
        }
        input = nil
        completionCapture = nil
        #expect(weakInput != nil)
        #expect(weakCompletionCapture != nil)

        task.cancelPending()

        #expect(await eventually(0.2) {
            weakInput == nil && weakCompletionCapture == nil
        })
        blockerRelease.signal()
    }

    /// Cancellation clears only work behind an entered syscall. The entered
    /// request returns, and a later submission still becomes the next request.
    @Test func cancellingPendingWorkLeavesTheEnteredRequestAndRunsANewerSubmission() async {
        let executor = FilesystemExecutor(
            label: "pasqualotto.baia.tests.filesystem-running-cancel",
            maxConcurrentOperations: 1
        )
        let firstRelease = DispatchSemaphore(value: 0)
        let log = FilesystemLog()
        let task = LatestFilesystemTask<String, String>(executor: executor) { value in
            log.start(value)
            if value == "running" {
                _ = firstRelease.wait(timeout: .now() + 2)
            }
            log.finish()
            return value
        }
        task.submit("running") { _ in }
        #expect(await eventually { log.started == ["running"] })

        task.submit("obsolete-b") { _ in }
        task.submit("obsolete-c") { _ in }
        task.cancelPending()
        task.submit("newest") { _ in }
        firstRelease.signal()

        #expect(await eventually { log.finished == 2 })
        #expect(log.started == ["running", "newest"])
    }

    /// Completion runs before the lane advances. Reentrant submissions from
    /// that callback must therefore keep only their newest pending value.
    @Test func aReentrantCompletionRunsOnlyItsNewestPendingSubmission() async {
        let executor = FilesystemExecutor(
            label: "pasqualotto.baia.tests.filesystem-reentrant-completion",
            maxConcurrentOperations: 1
        )
        let log = FilesystemLog()
        let box = FilesystemTaskBox()
        let task = LatestFilesystemTask<String, String>(executor: executor) { value in
            log.start(value)
            log.finish()
            return value
        }
        box.task = task
        task.submit("first") { value in
            guard value == "first" else { return }
            box.task?.submit("obsolete") { _ in }
            box.task?.submit("newest") { _ in }
        }

        #expect(await eventually { log.finished == 2 })
        #expect(log.started == ["first", "newest"])
    }

    /// Raising `maxConcurrentOperations` accidentally, or dispatching around
    /// the pool from a task lane, starts more than two blocked filesystem calls.
    @Test func theSharedExecutorNeverRunsMoreThanItsFixedWorkerBound() async {
        let executor = FilesystemExecutor(
            label: "pasqualotto.baia.tests.filesystem-bound",
            maxConcurrentOperations: 2
        )
        let release = DispatchSemaphore(value: 0)
        let log = FilesystemLog()
        var tasks: [LatestFilesystemTask<String, String>] = []

        for index in 0 ..< 8 {
            let task = LatestFilesystemTask<String, String>(executor: executor) { value in
                log.start(value)
                _ = release.wait(timeout: .now() + 2)
                log.finish()
                return value
            }
            tasks.append(task)
            task.submit("task-\(index)") { _ in }
        }

        #expect(await eventually { log.started.count == 2 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(log.started.count == 2)

        for _ in tasks { release.signal() }
        #expect(await eventually { log.finished == tasks.count })
    }
}
