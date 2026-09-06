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

    /// A Files binding can disappear before its first listing is admitted to
    /// the pool. The queued listing must not enter after the binding is gone.
    @Test func droppingABindingBeforeItsFirstExecutionCancelsTheQueuedListing() async {
        let executor = FilesystemExecutor(
            label: "pasqualotto.baia.tests.filesystem-drop-queued",
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

        let listingLog = FilesystemLog()
        var binding: DirectoryTreeBinding? = DirectoryTreeBinding(executor: executor) { root in
            listingLog.start(root.lastPathComponent)
            listingLog.finish()
            return []
        }
        weak let weakBinding = binding
        binding?.refresh(URL(filePath: "/tmp/obsolete", directoryHint: .isDirectory))
        binding = nil
        #expect(weakBinding == nil)

        let drainLog = FilesystemLog()
        let drain = LatestFilesystemTask<Int, Int>(executor: executor) { value in
            drainLog.start(String(value))
            drainLog.finish()
            return value
        }
        drain.submit(1) { _ in }
        blockerRelease.signal()

        #expect(await eventually { drainLog.finished == 1 })
        #expect(listingLog.started.isEmpty)
    }

    /// Repointing a binding while its first operation waits in the shared pool
    /// updates that queued work. Only the newest root may enter the filesystem.
    @Test func aQueuedBindingListingEntersOnlyTheNewestRoot() async {
        let executor = FilesystemExecutor(
            label: "pasqualotto.baia.tests.filesystem-queued-latest",
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

        let log = FilesystemLog()
        let binding = DirectoryTreeBinding(executor: executor) { root in
            let name = root.lastPathComponent
            log.start(name)
            log.finish()
            return [ScriptedReader.node("from-\(name)")]
        }
        binding.onChange = { _ in }
        binding.refresh(URL(filePath: "/tmp/root-a", directoryHint: .isDirectory))

        // A different consumer queues behind the binding's original slot.
        // Updating the binding must update that slot, not cancel it and append
        // replacement operations behind unrelated work.
        let sentinel = LatestFilesystemTask<String, String>(executor: executor) { value in
            log.start(value)
            log.finish()
            return value
        }
        sentinel.submit("sentinel") { _ in }
        binding.refresh(URL(filePath: "/tmp/root-b", directoryHint: .isDirectory))
        binding.refresh(URL(filePath: "/tmp/root-c", directoryHint: .isDirectory))

        blockerRelease.signal()
        #expect(await eventually { binding.nodes.map(\.name) == ["from-root-c"] })
        #expect(await eventually { log.finished == 2 })
        #expect(log.started == ["root-c", "sentinel"])
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

    /// Removing the pending overwrite would run all 100 obsolete roots after A
    /// unblocks. Removing the binding generation guard would publish A's node
    /// after the displayed root had already changed.
    @Test func blockedListingKeepsOnlyTheLatestPendingRootAndConvergesToIt() async throws {
        let executor = FilesystemExecutor(
            label: "pasqualotto.baia.tests.filesystem-latest",
            maxConcurrentOperations: 1
        )
        let firstRelease = DispatchSemaphore(value: 0)
        let log = FilesystemLog()
        let binding = DirectoryTreeBinding(executor: executor) { root in
            let name = root.lastPathComponent
            log.start(name)
            if name == "root-0" {
                _ = firstRelease.wait(timeout: .now() + 2)
            }
            log.finish()
            return [ScriptedReader.node("from-\(name)")]
        }
        var deliveries: [[FileTreeNode]] = []
        binding.onChange = { deliveries.append($0) }

        binding.refresh(URL(filePath: "/tmp/seed", directoryHint: .isDirectory))
        #expect(await eventually { binding.nodes.map(\.name) == ["from-seed"] })

        binding.refresh(URL(filePath: "/tmp/root-0", directoryHint: .isDirectory))
        // Root identity changed, so the seed tree is gone before root-0's
        // deliberately blocked listing has any chance to answer.
        #expect(binding.nodes.isEmpty)
        #expect(await eventually { log.started == ["seed", "root-0"] })

        for index in 1 ..< 100 {
            binding.refresh(URL(filePath: "/tmp/root-\(index)", directoryHint: .isDirectory))
        }

        // The running syscall is left alone and there is one pending answer,
        // not one queued operation per root change.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(log.started == ["seed", "root-0"])
        #expect(binding.nodes.isEmpty)

        firstRelease.signal()
        #expect(await eventually { binding.nodes.map(\.name) == ["from-root-99"] })
        #expect(log.started == ["seed", "root-0", "root-99"])
        #expect(!deliveries.contains { $0.map(\.name) == ["from-root-0"] })
    }

    /// Running the listing inline would hold this actor for the seam's 300 ms
    /// timeout. The production boundary owes an immediate clear and returns
    /// while the filesystem worker remains blocked.
    @Test func aBlockedListingClearsImmediatelyWithoutBlockingMainActorWork() async {
        let executor = FilesystemExecutor(
            label: "pasqualotto.baia.tests.filesystem-responsive",
            maxConcurrentOperations: 1
        )
        let log = FilesystemLog()
        let binding = DirectoryTreeBinding(executor: executor) { root in
            log.start(root.lastPathComponent)
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + .milliseconds(300))
            log.finish()
            return [ScriptedReader.node("late")]
        }
        binding.onChange = { _ in }

        let startedAt = ProcessInfo.processInfo.systemUptime
        binding.refresh(URL(filePath: "/tmp/blocked", directoryHint: .isDirectory))
        let returnedAfter = ProcessInfo.processInfo.systemUptime - startedAt

        #expect(returnedAfter < 0.05)
        #expect(binding.nodes.isEmpty)
        #expect(await eventually { log.started == ["blocked"] })
        #expect(!log.ranOnMain)
        // Reaching this assertion while the listing is still held is the direct
        // proof that unrelated main-actor work remains runnable.
        #expect(log.finished == 0)
        #expect(await eventually { log.finished == 1 })
    }

    /// Removing the post-callback generation check lets the outer A request run
    /// after `onChange` has synchronously redirected the binding to B.
    @Test func aClearCallbackThatChangesRootCannotSubmitTheSupersededOuterListing() async {
        let executor = FilesystemExecutor(
            label: "pasqualotto.baia.tests.filesystem-reentrant",
            maxConcurrentOperations: 1
        )
        let log = FilesystemLog()
        let binding = DirectoryTreeBinding(executor: executor) { root in
            log.start(root.lastPathComponent)
            log.finish()
            return [ScriptedReader.node("from-\(root.lastPathComponent)")]
        }
        let b = URL(filePath: "/tmp/root-b", directoryHint: .isDirectory)
        var redirected = false
        binding.onChange = { nodes in
            guard nodes.isEmpty, !redirected else { return }
            redirected = true
            binding.refresh(b)
        }

        binding.refresh(URL(filePath: "/tmp/root-a", directoryHint: .isDirectory))

        #expect(await eventually { binding.nodes.map(\.name) == ["from-root-b"] })
        #expect(await eventually { log.finished >= 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(log.started == ["root-b"])
        #expect(binding.root == b)
    }

    /// Dropping a Files surface drops its binding. Its blocked syscall may
    /// finish, but a root queued behind that syscall must not run afterward.
    @Test func droppingABindingCancelsItsPendingListing() async {
        let executor = FilesystemExecutor(
            label: "pasqualotto.baia.tests.filesystem-drop",
            maxConcurrentOperations: 1
        )
        let release = DispatchSemaphore(value: 0)
        let log = FilesystemLog()
        var binding: DirectoryTreeBinding? = DirectoryTreeBinding(executor: executor) { root in
            log.start(root.lastPathComponent)
            if root.lastPathComponent == "root-a" {
                _ = release.wait(timeout: .now() + 2)
            }
            log.finish()
            return []
        }
        weak var weakBinding: DirectoryTreeBinding?
        weakBinding = binding

        binding?.refresh(URL(filePath: "/tmp/root-a", directoryHint: .isDirectory))
        #expect(await eventually { log.started == ["root-a"] })
        binding?.refresh(URL(filePath: "/tmp/root-b", directoryHint: .isDirectory))
        binding = nil
        #expect(weakBinding == nil)

        release.signal()
        #expect(await eventually { log.finished >= 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(log.started == ["root-a"])
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
