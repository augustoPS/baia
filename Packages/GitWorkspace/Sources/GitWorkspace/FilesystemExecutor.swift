import Foundation

/// A fixed-width executor for synchronous filesystem calls.
///
/// A filesystem syscall already in progress cannot be cancelled safely. The
/// executor therefore bounds how many calls can be inside the filesystem at
/// once instead of starting replacement threads when one stalls. This is a
/// separate pool from ``RepositoryObserver``'s Git reads, so a blocked plain
/// directory listing cannot consume Git's execution lane.
public final class FilesystemExecutor: @unchecked Sendable {
    /// Shared by app-side anchoring, project discovery, and plain directory
    /// listings. Two workers let one stalled volume leave one filesystem lane
    /// available while retaining a fixed process-wide ceiling.
    public static let shared = FilesystemExecutor(
        label: "pasqualotto.baia.filesystem",
        maxConcurrentOperations: 2
    )

    private let operations: OperationQueue

    public init(label: String, maxConcurrentOperations: Int) {
        let operations = OperationQueue()
        operations.name = label
        operations.qualityOfService = .utility
        operations.maxConcurrentOperationCount = max(1, maxConcurrentOperations)
        self.operations = operations
    }

    fileprivate func execute(_ operation: Operation) {
        operations.addOperation(operation)
    }
}

/// One consumer's serial filesystem lane: one queued or running request and
/// only the newest request that arrived behind an entered call.
///
/// Repeated changes update the queued operation's payload before it enters the
/// filesystem, or overwrite `pending` after it enters. The running syscall is
/// allowed to finish, and neither case builds an unbounded queue.
/// Result obsolescence is a domain decision: consumers carry their own
/// generation because another poll of the same process may leave the current
/// result valid, while changing a displayed root invalidates it immediately.
public final class LatestFilesystemTask<Input: Sendable, Output: Sendable>: @unchecked Sendable {
    private struct Submission: Sendable {
        let input: Input
        let completion: @Sendable (Output) -> Void
    }

    private let executor: FilesystemExecutor
    private let operation: @Sendable (Input) -> Output
    private let lock = NSLock()
    private var nextID: UInt64 = 0
    private var currentID: UInt64?
    private var currentHasEnteredFilesystem = false
    private var queuedSubmission: Submission?
    private var queuedOperation: Operation?
    private var pending: Submission?

    public init(
        executor: FilesystemExecutor = .shared,
        operation: @escaping @Sendable (Input) -> Output
    ) {
        self.executor = executor
        self.operation = operation
    }

    /// Starts now when idle. Before entry, replaces the queued payload in its
    /// existing operation. After entry, retains only the newest pending request.
    public func submit(
        _ input: Input,
        completion: @escaping @Sendable (Output) -> Void
    ) {
        let submission = Submission(input: input, completion: completion)
        let queuedOperation = lock.withLock { () -> Operation? in
            if currentID != nil {
                if !currentHasEnteredFilesystem {
                    queuedSubmission = submission
                    return nil
                }
                pending = submission
                return nil
            }
            return prepareLocked(submission)
        }
        if let queuedOperation { executor.execute(queuedOperation) }
    }

    /// Forgets work that has not entered the filesystem. An operation already
    /// running still completes and its consumer's generation fence discards it.
    public func cancelPending() {
        let operationToCancel = lock.withLock { () -> Operation? in
            pending = nil
            guard currentID != nil, !currentHasEnteredFilesystem else { return nil }

            let operation = self.queuedOperation
            currentID = nil
            queuedSubmission = nil
            self.queuedOperation = nil
            return operation
        }
        operationToCancel?.cancel()
    }

    /// Called with `lock` held. The queued operation captures only this lane
    /// weakly; its mutable submission remains here so replacement and
    /// cancellation release obsolete input and completion captures promptly.
    private func prepareLocked(_ submission: Submission) -> Operation {
        nextID &+= 1
        let id = nextID
        let operation = BlockOperation { [weak self] in
            self?.perform(id)
        }
        currentID = id
        currentHasEnteredFilesystem = false
        queuedSubmission = submission
        queuedOperation = operation
        return operation
    }

    private func perform(_ id: UInt64) {
        let submission = lock.withLock { () -> Submission? in
            guard currentID == id, !currentHasEnteredFilesystem,
                  let queuedSubmission
            else { return nil }
            currentHasEnteredFilesystem = true
            self.queuedSubmission = nil
            queuedOperation = nil
            return queuedSubmission
        }
        guard let submission else { return }

        let output = operation(submission.input)
        submission.completion(output)
        finish(id)
    }

    private func finish(_ id: UInt64) {
        let queuedOperation = lock.withLock { () -> Operation? in
            guard currentID == id, currentHasEnteredFilesystem else { return nil }
            currentID = nil
            currentHasEnteredFilesystem = false

            guard let pending else {
                return nil
            }
            self.pending = nil
            return prepareLocked(pending)
        }
        if let queuedOperation { executor.execute(queuedOperation) }
    }
}
