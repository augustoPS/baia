import Foundation
import Testing

@testable import GitWorkspace

/// A reader whose answers and timing the test scripts, so the observer's real
/// scheduler, generations and publication run against reads the test controls.
///
/// The observer is the thing under test here. Nothing about its timers, its
/// coalescing, its backoff or its publication order is replaced; only the git
/// process is, and every interval the observer waits is real time.
final class ScriptedReader: RepositoryReading, @unchecked Sendable {
    typealias StatusScript = @Sendable (URL, SubprocessCancellation, Int) -> RepositoryStatusRead
    typealias TreeScript = @Sendable (URL, SubprocessCancellation, Int) -> RepositoryTreeRead

    typealias DefaultBranchScript = @Sendable (URL, SubprocessCancellation, Int) -> RepositoryDefaultBranchRead

    private let lock = NSLock()
    private var statusScript: StatusScript
    private var treeScript: TreeScript
    private var defaultBranchScript: DefaultBranchScript = { _, _, _ in .success(nil) }
    private var statusLog: [(root: URL, at: TimeInterval)] = []
    private var treeLog: [(root: URL, at: TimeInterval)] = []
    private var defaultBranchLog: [(root: URL, at: TimeInterval)] = []
    private var cancellationsObserved = 0

    init(
        status: @escaping StatusScript = { _, _, _ in .success(ScriptedReader.reading(modified: [])) },
        tree: @escaping TreeScript = { _, _, _ in .success([]) }
    ) {
        statusScript = status
        treeScript = tree
    }

    static func reading(head: String = "main", modified: [String]) -> RepositoryStatusReading {
        RepositoryStatusReading(
            status: RepositoryStatus(head: .branch(head), unstaged: modified.count),
            changes: modified.map { RepositoryFileChange(path: RepositoryPath($0), worktree: .modified, kind: .ordinary) }
        )
    }

    static func node(_ name: String) -> FileTreeNode {
        FileTreeNode(name: RepositoryPath(name), path: RepositoryPath(name), isDirectory: false, children: [])
    }

    func setStatus(_ script: @escaping StatusScript) {
        lock.lock()
        statusScript = script
        lock.unlock()
    }

    func setTree(_ script: @escaping TreeScript) {
        lock.lock()
        treeScript = script
        lock.unlock()
    }

    var statusCalls: [(root: URL, at: TimeInterval)] {
        lock.lock()
        defer { lock.unlock() }
        return statusLog
    }

    var treeCalls: [(root: URL, at: TimeInterval)] {
        lock.lock()
        defer { lock.unlock() }
        return treeLog
    }

    var cancellations: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellationsObserved
    }

    func noteCancellation() {
        lock.lock()
        cancellationsObserved += 1
        lock.unlock()
    }

    func readStatus(ofRepositoryRoot root: URL, cancellation: SubprocessCancellation) -> RepositoryStatusRead {
        lock.lock()
        statusLog.append((root, ProcessInfo.processInfo.systemUptime))
        let index = statusLog.count
        let script = statusScript
        lock.unlock()
        return script(root, cancellation, index)
    }

    func readTree(ofRepositoryRoot root: URL, cancellation: SubprocessCancellation) -> RepositoryTreeRead {
        lock.lock()
        treeLog.append((root, ProcessInfo.processInfo.systemUptime))
        let index = treeLog.count
        let script = treeScript
        lock.unlock()
        return script(root, cancellation, index)
    }

    func setDefaultBranch(_ script: @escaping DefaultBranchScript) {
        lock.lock()
        defaultBranchScript = script
        lock.unlock()
    }

    var defaultBranchCalls: [(root: URL, at: TimeInterval)] {
        lock.lock()
        defer { lock.unlock() }
        return defaultBranchLog
    }

    func readDefaultBranch(ofRepositoryRoot root: URL, cancellation: SubprocessCancellation) -> RepositoryDefaultBranchRead {
        lock.lock()
        defaultBranchLog.append((root, ProcessInfo.processInfo.systemUptime))
        let index = defaultBranchLog.count
        let script = defaultBranchScript
        lock.unlock()
        return script(root, cancellation, index)
    }
}

/// A read held open until the test opens it, or until the observer cancels it.
final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func open() { semaphore.signal() }

    /// True when opened, false when the read was cancelled or the wait expired.
    func wait(_ cancellation: SubprocessCancellation, timeout: TimeInterval = 5) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if semaphore.wait(timeout: .now() + .milliseconds(5)) == .success { return true }
            if cancellation.isCancelled { return false }
        }
        return false
    }
}

/// A count a read script can bump from the read queue.
final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }
    func bump() { lock.withLock { value += 1 } }
}

/// What one subscriber was handed, in order.
@MainActor
final class Deliveries {
    private(set) var received: [RepositorySnapshot?] = []
    func record(_ snapshot: RepositorySnapshot?) { received.append(snapshot) }
    var snapshots: [RepositorySnapshot] { received.compactMap { $0 } }
    var last: RepositorySnapshot? { received.last ?? nil }
}

/// The observer's scheduling, generations and publication, driven for real.
///
/// Every interval here is real time compressed by the policy; nothing injects a
/// clock. The cases are the contract's: a delayed read for one root completing
/// after a switch to another, equal counts with different paths, an empty tree
/// that must not loop, repeated failures with recovery, deduplicated aliases and
/// subscribers, cancellation on release, and invalidation during a read.
@Suite(.serialized) @MainActor final class RepositoryObserverSchedulingTests {
    let fixture: DirectoryFixture

    init() throws {
        fixture = try DirectoryFixture()
    }

    private func policy(
        statusInterval: TimeInterval = 0.05,
        treeRefreshInterval: TimeInterval = 60,
        treeCoalesceWindow: TimeInterval = 0.02,
        minimumTreeReadSpacing: TimeInterval = 0,
        failureBackoffBase: TimeInterval = 0.05,
        failureBackoffCap: TimeInterval = 0.2
    ) -> RepositoryObservationPolicy {
        RepositoryObservationPolicy(
            statusInterval: statusInterval,
            treeRefreshInterval: treeRefreshInterval,
            treeCoalesceWindow: treeCoalesceWindow,
            minimumTreeReadSpacing: minimumTreeReadSpacing,
            failureBackoffBase: failureBackoffBase,
            failureBackoffCap: failureBackoffCap
        )
    }

    private func root(_ name: String) throws -> RepositoryRoot {
        RepositoryRoot(try fixture.directory(name))
    }

    private func eventually(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1_000)))
    }

    private func paths(_ snapshot: RepositorySnapshot?) -> [String] {
        snapshot?.changes.map(\.path) ?? []
    }

    // MARK: Publication

    @Test func aNewSubscriberGetsNilAtOnceAndTheFirstSnapshotAfterTheRead() async throws {
        let reader = ScriptedReader(status: { _, _, _ in .success(ScriptedReader.reading(modified: ["a.txt"])) })
        let observer = RepositoryObserver(reader: reader, policy: policy())
        let deliveries = Deliveries()
        let repo = try root("repo")

        let subscription = observer.observe(repo) { deliveries.record($0) }
        defer { subscription.cancel() }

        #expect(deliveries.received.count == 1)
        #expect(deliveries.received[0] == nil)
        #expect(await eventually { deliveries.last?.status != nil })
        #expect(paths(deliveries.last) == ["a.txt"])
        #expect(deliveries.last?.health == .ok)
        #expect(observer.snapshot(of: repo) == deliveries.last)
    }

    /// **Delay A, switch to B, complete A last.** The pane cancels A and subscribes
    /// to B while A's read is still open. A completes after B has published. The
    /// pane never sees A: A's observation was released with its last subscriber,
    /// its read was cancelled, and the late completion finds no root.
    @Test func switchingRootsWhileTheOldReadIsHeldNeverDeliversTheOldRoot() async throws {
        let gate = Gate()
        let a = try root("a")
        let b = try root("b")
        let reader = ScriptedReader(
            status: { url, cancellation, _ in
                if url == a.url {
                    return gate.wait(cancellation)
                        ? .success(ScriptedReader.reading(head: "a-branch", modified: ["from-a.txt"]))
                        : .failure(.cancelled)
                }
                return .success(ScriptedReader.reading(head: "b-branch", modified: ["from-b.txt"]))
            },
            tree: { _, cancellation, _ in
                _ = Gate().wait(cancellation, timeout: 60)
                return .failure(.cancelled)
            }
        )
        let observer = RepositoryObserver(reader: reader, policy: policy())
        let pane = Deliveries()

        let onA = observer.observe(a) { pane.record($0) }
        #expect(await eventually { reader.statusCalls.count == 1 })
        onA.cancel()
        let onB = observer.observe(b) { pane.record($0) }
        defer { onB.cancel() }
        #expect(await eventually { pane.last?.status?.head == .branch("b-branch") })

        gate.open()
        await settle(0.2)

        #expect(observer.snapshot(of: a) == nil)
        #expect(observer.observedRoots == [b])
        #expect(pane.snapshots.allSatisfy { $0.root == b && $0.status?.head == .branch("b-branch") })
        #expect(!pane.snapshots.contains { self.paths($0).contains("from-a.txt") })
    }

    /// The same switch while another pane still holds A. A's late completion
    /// reaches that pane and nobody else; B's subscriber never sees A's paths.
    @Test func aLateCompletionForARootStillObservedReachesOnlyThatRootsSubscribers() async throws {
        let gate = Gate()
        let a = try root("a")
        let b = try root("b")
        let reader = ScriptedReader(
            status: { url, cancellation, _ in
                if url == a.url {
                    return gate.wait(cancellation)
                        ? .success(ScriptedReader.reading(head: "a-branch", modified: ["from-a.txt"]))
                        : .failure(.cancelled)
                }
                return .success(ScriptedReader.reading(head: "b-branch", modified: ["from-b.txt"]))
            },
            tree: { _, cancellation, _ in
                _ = Gate().wait(cancellation, timeout: 60)
                return .failure(.cancelled)
            }
        )
        let observer = RepositoryObserver(reader: reader, policy: policy(statusInterval: 60))
        let other = Deliveries()
        let pane = Deliveries()

        let otherOnA = observer.observe(a) { other.record($0) }
        defer { otherOnA.cancel() }
        let paneOnA = observer.observe(a) { pane.record($0) }
        #expect(await eventually { reader.statusCalls.count == 1 })
        paneOnA.cancel()
        let paneOnB = observer.observe(b) { pane.record($0) }
        defer { paneOnB.cancel() }
        #expect(await eventually { pane.last?.status?.head == .branch("b-branch") })

        gate.open()
        #expect(await eventually { other.last?.status?.head == .branch("a-branch") })

        #expect(paths(other.last) == ["from-a.txt"])
        #expect(pane.snapshots.allSatisfy { $0.root == b })
        #expect(!pane.snapshots.contains { self.paths($0).contains("from-a.txt") })
        // A was polled once for both of its subscribers, never once each.
        #expect(reader.statusCalls.filter { $0.root == a.url }.count == 1)
    }

    /// **Equal counts, different paths.** One modified file, then the same read
    /// again, then a rename. The identical read publishes nothing; the rename
    /// publishes, because the paths are rendered.
    @Test func equalCountsWithDifferentPathsNotifyAndIdenticalReadsDoNot() async throws {
        let reader = ScriptedReader(
            status: { _, _, index in
                .success(ScriptedReader.reading(modified: [index < 3 ? "a.txt" : "b.txt"]))
            },
            tree: { _, cancellation, _ in
                _ = Gate().wait(cancellation, timeout: 60)
                return .failure(.cancelled)
            }
        )
        let observer = RepositoryObserver(reader: reader, policy: policy())
        let deliveries = Deliveries()
        let repo = try root("repo")

        let subscription = observer.observe(repo) { deliveries.record($0) }
        defer { subscription.cancel() }
        #expect(await eventually { reader.statusCalls.count >= 4 })
        #expect(await eventually { self.paths(deliveries.last) == ["b.txt"] })

        let published = deliveries.snapshots.map { paths($0) }
        #expect(published == [["a.txt"], ["b.txt"]])
        #expect(deliveries.snapshots.map(\.status) == [deliveries.snapshots[0].status, deliveries.snapshots[0].status])
    }

    // MARK: Tree lifecycle

    /// **Empty repository, no loop.** The subscriber "redraws" on every
    /// publication by reading the snapshot back, exactly as a sidebar would, and
    /// the tree is read once. The completion-refresh-read edge does not exist.
    @Test func anEmptyTreeIsStoredAndARedrawRequestsNothing() async throws {
        let reader = ScriptedReader()
        let observer = RepositoryObserver(reader: reader, policy: policy())
        let repo = try root("repo")
        var redraws = 0

        let subscription = observer.observe(repo) { _ in
            redraws += 1
            _ = observer.snapshot(of: repo)
            _ = observer.observedRoots
        }
        defer { subscription.cancel() }
        #expect(await eventually { reader.statusCalls.count >= 6 })

        #expect(reader.treeCalls.count == 1)
        #expect(observer.snapshot(of: repo)?.tree == .empty)
        #expect(redraws >= 2)
    }

    @Test func aLoadedTreeIsPublishedWithItsRows() async throws {
        let reader = ScriptedReader(tree: { _, _, _ in .success([ScriptedReader.node("x.swift")]) })
        let observer = RepositoryObserver(reader: reader, policy: policy())
        let repo = try root("repo")

        let subscription = observer.observe(repo) { _ in }
        defer { subscription.cancel() }

        #expect(await eventually { observer.snapshot(of: repo)?.tree.nodes.map(\.name) == ["x.swift"] })
    }

    /// Tree failures retry on the backoff, reach the cap, and keep retrying at
    /// the cap. Nothing gives up after a count.
    @Test func treeFailuresRetryOnTheBackoffAndKeepGoingAtTheCap() async throws {
        let reader = ScriptedReader(tree: { _, _, _ in .failure(.timedOut) })
        let observer = RepositoryObserver(
            reader: reader,
            policy: policy(statusInterval: 60, failureBackoffBase: 0.02, failureBackoffCap: 0.05)
        )
        let repo = try root("repo")

        let subscription = observer.observe(repo) { _ in }
        defer { subscription.cancel() }
        // Cap reached after three doublings (0.02, 0.04, 0.05); ten reads at the
        // cap is well past where a counting policy would have stopped.
        #expect(await eventually(5) { reader.treeCalls.count >= 12 })

        let calls = reader.treeCalls
        let gaps = zip(calls.dropFirst(), calls).map { $0.at - $1.at }
        #expect(gaps.count >= 11)
        #expect(gaps[0] >= 0.015)
        #expect(gaps[1] >= 0.03)
        #expect(gaps.dropFirst(2).allSatisfy { $0 >= 0.04 })
        // Capped: nothing waits for the uncapped doubling.
        #expect(gaps.dropFirst(2).allSatisfy { $0 < 0.5 })
        if case let .failed(failure, attempts)? = observer.snapshot(of: repo)?.tree {
            #expect(failure == .timedOut)
            // The newest read may still be in flight when the snapshot is read,
            // so the published count trails the call log by at most one.
            #expect(attempts >= calls.count - 1 && attempts <= calls.count)
        } else {
            Issue.record("the tree is not in a failed state")
        }
    }

    /// A tree that comes back after failing resets its backoff and its health.
    @Test func aRecoveredTreeReadClearsTheFailure() async throws {
        let reader = ScriptedReader(tree: { _, _, index in
            index < 3 ? .failure(.unavailable(.exit(1))) : .success([ScriptedReader.node("back.txt")])
        })
        let observer = RepositoryObserver(
            reader: reader,
            policy: policy(statusInterval: 60, failureBackoffBase: 0.02, failureBackoffCap: 0.05)
        )
        let repo = try root("repo")

        let subscription = observer.observe(repo) { _ in }
        defer { subscription.cancel() }

        #expect(await eventually { observer.snapshot(of: repo)?.tree.nodes.map(\.name) == ["back.txt"] })
        #expect(reader.treeCalls.count == 3)
    }

    /// An invalidation while a tree read is in flight discards that read's
    /// answer, whatever it says, and reads once more. The stale tree is never
    /// published.
    @Test func anInvalidationDuringAnInFlightTreeReadDiscardsItAndReadsAgain() async throws {
        let gate = Gate()
        let reader = ScriptedReader(tree: { _, cancellation, index in
            if index == 1 {
                return gate.wait(cancellation) ? .success([ScriptedReader.node("stale.txt")]) : .failure(.cancelled)
            }
            return .success([ScriptedReader.node("fresh.txt")])
        })
        let observer = RepositoryObserver(reader: reader, policy: policy(statusInterval: 60))
        let deliveries = Deliveries()
        let repo = try root("repo")

        let subscription = observer.observe(repo) { deliveries.record($0) }
        defer { subscription.cancel() }
        #expect(await eventually { reader.treeCalls.count == 1 })

        observer.invalidateTree(of: repo)
        gate.open()

        #expect(await eventually { observer.snapshot(of: repo)?.tree.nodes.map(\.name) == ["fresh.txt"] })
        #expect(reader.treeCalls.count == 2)
        #expect(!deliveries.snapshots.contains { $0.tree.nodes.map(\.name) == ["stale.txt"] })
    }

    /// Thirty invalidations in one burst are one read after the window, and a
    /// second burst inside the spacing waits for it.
    @Test func invalidationsAreCoalescedAndSpaced() async throws {
        let reader = ScriptedReader()
        let observer = RepositoryObserver(
            reader: reader,
            policy: policy(statusInterval: 60, treeCoalesceWindow: 0.05, minimumTreeReadSpacing: 0.15)
        )
        let repo = try root("repo")

        let subscription = observer.observe(repo) { _ in }
        defer { subscription.cancel() }
        #expect(await eventually { reader.treeCalls.count == 1 })

        for _ in 0 ..< 30 { observer.invalidateTree(of: repo) }
        await settle(0.1)
        #expect(reader.treeCalls.count == 1)
        #expect(await eventually { reader.treeCalls.count == 2 })
        let calls = reader.treeCalls
        #expect(calls[1].at - calls[0].at >= 0.14)

        for _ in 0 ..< 30 { observer.invalidateTree(of: repo) }
        await settle(0.4)
        #expect(reader.treeCalls.count == 3)
    }

    /// A head change in the status asks for a tree read; an unchanged status
    /// asks for nothing, however many polls it takes.
    @Test func aStatusHeadChangeRequestsATreeReadAndAnUnchangedStatusDoesNot() async throws {
        let reader = ScriptedReader(status: { _, _, index in
            .success(ScriptedReader.reading(head: index < 5 ? "main" : "feature", modified: []))
        })
        let observer = RepositoryObserver(reader: reader, policy: policy())
        let repo = try root("repo")

        let subscription = observer.observe(repo) { _ in }
        defer { subscription.cancel() }
        #expect(await eventually { reader.statusCalls.count == 4 })
        #expect(reader.treeCalls.count == 1)

        #expect(await eventually { reader.treeCalls.count == 2 })
        #expect(reader.statusCalls.count >= 5)
    }

    /// A changed path set with the same head asks for a tree read too: an
    /// untracked file appearing is a file the tree does not have.
    @Test func aChangedPathSetRequestsATreeRead() async throws {
        let reader = ScriptedReader(status: { _, _, index in
            .success(ScriptedReader.reading(modified: index < 4 ? [] : ["new.txt"]))
        })
        let observer = RepositoryObserver(reader: reader, policy: policy())
        let repo = try root("repo")

        let subscription = observer.observe(repo) { _ in }
        defer { subscription.cancel() }

        #expect(await eventually { reader.treeCalls.count == 2 })
        #expect(reader.statusCalls.count >= 4)
    }

    /// The periodic backstop reads the tree with the status unchanged, and the
    /// new answer is published without any invalidation.
    @Test func thePeriodicTreeRefreshRunsWithAnUnchangedStatus() async throws {
        let reader = ScriptedReader(tree: { _, _, index in
            .success([ScriptedReader.node("v\(index).txt")])
        })
        let observer = RepositoryObserver(
            reader: reader,
            policy: policy(statusInterval: 60, treeRefreshInterval: 0.05)
        )
        let repo = try root("repo")

        let subscription = observer.observe(repo) { _ in }
        defer { subscription.cancel() }

        #expect(await eventually { reader.treeCalls.count >= 4 })
        #expect(reader.statusCalls.count == 1)
        let shown = observer.snapshot(of: repo)?.tree.nodes.map(\.name) ?? []
        #expect(shown.count == 1)
        #expect(shown[0] != "v1.txt")
    }

    // MARK: Status failures

    /// Status failures back off to the cap, keep polling at the cap, and a
    /// success afterwards restores the ordinary cadence and clears the health.
    @Test func statusFailuresBackOffAndContinueAtTheCapThenRecover() async throws {
        let reader = ScriptedReader(status: { _, _, index in
            index <= 5 ? .failure(.timedOut) : .success(ScriptedReader.reading(modified: []))
        })
        let observer = RepositoryObserver(
            reader: reader,
            policy: policy(statusInterval: 0.02, failureBackoffBase: 0.05, failureBackoffCap: 0.2)
        )
        let deliveries = Deliveries()
        let repo = try root("repo")

        let subscription = observer.observe(repo) { deliveries.record($0) }
        defer { subscription.cancel() }
        #expect(await eventually(5) { deliveries.last?.health == .ok })

        let calls = reader.statusCalls
        #expect(calls.count >= 6)
        let gaps = zip(calls.dropFirst(), calls).map { $0.at - $1.at }
        // After failures 1..5: 0.05, 0.1, 0.2, 0.2 (capped), 0.2 (capped).
        #expect(gaps[0] >= 0.04)
        #expect(gaps[1] >= 0.09)
        #expect(gaps[2] >= 0.19)
        #expect(gaps[3] >= 0.19 && gaps[3] < 0.5)
        #expect(gaps[4] >= 0.19 && gaps[4] < 0.5)
        let healths = deliveries.snapshots.map(\.health)
        #expect(healths.contains(.failed(.timedOut, attempts: 1)))
        #expect(healths.contains(.failed(.timedOut, attempts: 5)))
        #expect(healths.last == .ok)
        // Recovered: the ordinary cadence again.
        #expect(await eventually { reader.statusCalls.count >= 9 })
        let after = reader.statusCalls
        #expect(after[after.count - 1].at - after[after.count - 2].at < 0.15)
    }

    /// A failed read keeps the last good status and says so in the health; a
    /// root that stops being a repository clears it.
    @Test func aFailedReadKeepsTheLastStatusAndAGoneRootClearsIt() async throws {
        let reader = ScriptedReader(status: { _, _, index in
            switch index {
            case 1: .success(ScriptedReader.reading(modified: ["kept.txt"]))
            case 2: .failure(.timedOut)
            default: .failure(.notARepository)
            }
        })
        let observer = RepositoryObserver(reader: reader, policy: policy(statusInterval: 0.02))
        let deliveries = Deliveries()
        let repo = try root("repo")

        let subscription = observer.observe(repo) { deliveries.record($0) }
        defer { subscription.cancel() }
        #expect(await eventually { deliveries.last?.isGone == true })

        let stalled = deliveries.snapshots.first { $0.health == .failed(.timedOut, attempts: 1) }
        #expect(stalled?.status?.head == .branch("main"))
        #expect(stalled.map(paths) == ["kept.txt"])
        #expect(deliveries.last?.status == nil)
        #expect(paths(deliveries.last).isEmpty)
    }

    // MARK: Sharing and activity

    @Test func threeSubscribersOnOneRootShareOnePoll() async throws {
        let reader = ScriptedReader()
        let observer = RepositoryObserver(reader: reader, policy: policy())
        let repo = try root("repo")
        let deliveries = [Deliveries(), Deliveries(), Deliveries()]

        let subscriptions = deliveries.map { record in observer.observe(repo) { record.record($0) } }
        defer { for subscription in subscriptions { subscription.cancel() } }
        #expect(await eventually { reader.statusCalls.count >= 6 })

        #expect(observer.observedRoots.count == 1)
        #expect(reader.treeCalls.count == 1)
        #expect(reader.statusCalls.count < 12)
        #expect(deliveries.allSatisfy { $0.last == observer.snapshot(of: repo) })
    }

    @Test func aliasSpellingsShareOneObservation() async throws {
        let real = try fixture.directory("real")
        let link = fixture.root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let reader = ScriptedReader()
        let observer = RepositoryObserver(reader: reader, policy: policy())
        let spellings = [
            RepositoryRoot(real),
            RepositoryRoot(URL(filePath: real.path(percentEncoded: false) + "/")),
            RepositoryRoot(link),
        ]

        let subscriptions = spellings.map { observer.observe($0) { _ in } }
        defer { for subscription in subscriptions { subscription.cancel() } }
        #expect(await eventually { reader.statusCalls.count >= 3 })

        #expect(observer.observedRoots.count == 1)
        #expect(reader.treeCalls.count == 1)
        #expect(Set(reader.statusCalls.map(\.root)).count == 1)
        // Every spelling reads the same publication.
        #expect(spellings.allSatisfy { observer.snapshot(of: $0) == observer.snapshot(of: spellings[0]) })
    }

    /// Releasing the last subscriber cancels the read in flight, stops polling,
    /// and forgets the root. Nothing arrives afterwards.
    @Test func cancellingTheLastSubscriberCancelsInFlightReadsAndForgetsTheRoot() async throws {
        // Both reads are held until the observer cancels them; neither answers
        // on its own, so the only way either returns is the release.
        let cancelled = Tally()
        let reader = ScriptedReader(
            status: { _, cancellation, _ in
                let opened = Gate().wait(cancellation, timeout: 5)
                if !opened { cancelled.bump() }
                return opened ? .success(ScriptedReader.reading(modified: [])) : .failure(.cancelled)
            },
            tree: { _, cancellation, _ in
                let opened = Gate().wait(cancellation, timeout: 5)
                if !opened { cancelled.bump() }
                return opened ? .success([]) : .failure(.cancelled)
            }
        )
        let observer = RepositoryObserver(reader: reader, policy: policy())
        let deliveries = Deliveries()
        let repo = try root("repo")

        let subscription = observer.observe(repo) { deliveries.record($0) }
        #expect(await eventually { reader.statusCalls.count == 1 && reader.treeCalls.count == 1 })
        subscription.cancel()

        #expect(observer.observedRoots.isEmpty)
        #expect(observer.snapshot(of: repo) == nil)
        #expect(await eventually { cancelled.count == 2 })
        await settle(0.3)
        #expect(reader.statusCalls.count == 1)
        #expect(reader.treeCalls.count == 1)
        #expect(deliveries.received == [nil])
        #expect(subscription.isCancelled)
    }

    @Test func aDroppedSubscriptionReleasesLikeACancelledOne() async throws {
        let reader = ScriptedReader()
        let observer = RepositoryObserver(reader: reader, policy: policy())
        let repo = try root("repo")

        do {
            let subscription = observer.observe(repo) { _ in }
            #expect(await eventually { reader.statusCalls.count >= 1 })
            _ = subscription
        }

        #expect(await eventually { observer.observedRoots.isEmpty })
    }

    /// Inactive subscribers stop the polling; one becoming active again is a
    /// refresh; two windows do not disable each other.
    @Test func inactiveRootsStopReadingAndReactivationRefreshes() async throws {
        let reader = ScriptedReader()
        let observer = RepositoryObserver(reader: reader, policy: policy())
        let repo = try root("repo")

        let windowA = observer.observe(repo) { _ in }
        let windowB = observer.observe(repo) { _ in }
        defer { windowA.cancel(); windowB.cancel() }
        #expect(await eventually { reader.statusCalls.count >= 2 })

        windowA.isActive = false
        await settle(0.2)
        // B still active: reads continue.
        #expect(reader.statusCalls.count >= 4)

        windowB.isActive = false
        await settle(0.1)
        let quiet = reader.statusCalls.count
        await settle(0.3)
        #expect(reader.statusCalls.count == quiet)

        windowA.isActive = true
        #expect(await eventually(0.5) { reader.statusCalls.count > quiet })
    }

    @Test func aSubscriberObservingInactiveReadsNothingUntilActivated() async throws {
        let reader = ScriptedReader()
        let observer = RepositoryObserver(reader: reader, policy: policy())
        let repo = try root("repo")

        let subscription = observer.observe(repo, active: false) { _ in }
        defer { subscription.cancel() }
        await settle(0.2)
        #expect(reader.statusCalls.isEmpty)
        #expect(reader.treeCalls.isEmpty)

        subscription.isActive = true
        #expect(await eventually { reader.statusCalls.count == 1 && reader.treeCalls.count == 1 })
    }

    @Test func theStatusIntervalChangesInPlace() async throws {
        let reader = ScriptedReader()
        let observer = RepositoryObserver(reader: reader, policy: policy(statusInterval: 0.02))
        let repo = try root("repo")

        let subscription = observer.observe(repo) { _ in }
        defer { subscription.cancel() }
        #expect(await eventually { reader.statusCalls.count >= 5 })

        observer.statusInterval = 0.3
        await settle(0.1)
        let before = reader.statusCalls.count
        await settle(0.15)
        #expect(reader.statusCalls.count <= before + 1)
        #expect(await eventually { reader.statusCalls.count > before })
    }

    /// **The default branch is cached by polling and re-read by invalidation.**
    /// A repository with no remote answers nil, and six polls later it has still
    /// been asked once. A remote is added and its HEAD set; the next ordinary
    /// poll still does not ask, and an explicit invalidation does, and the new
    /// answer is published. A later change of the remote's HEAD is picked up the
    /// same way.
    @Test func anExplicitInvalidationReReadsTheDefaultBranchWhilePollingCachesIt() async throws {
        let reader = ScriptedReader(tree: { _, cancellation, _ in
            _ = Gate().wait(cancellation, timeout: 60)
            return .failure(.cancelled)
        })
        let observer = RepositoryObserver(reader: reader, policy: policy())
        let deliveries = Deliveries()
        let repo = try root("repo")

        let subscription = observer.observe(repo) { deliveries.record($0) }
        defer { subscription.cancel() }
        #expect(await eventually { reader.statusCalls.count >= 6 })
        #expect(reader.defaultBranchCalls.count == 1)
        #expect(observer.snapshot(of: repo)?.defaultBranch == .known(nil))

        // A remote appears. Polling alone never notices.
        reader.setDefaultBranch { _, _, _ in .success("develop") }
        let polls = reader.statusCalls.count
        #expect(await eventually { reader.statusCalls.count >= polls + 3 })
        #expect(reader.defaultBranchCalls.count == 1)
        #expect(observer.snapshot(of: repo)?.defaultBranch == .known(nil))

        observer.invalidateStatus(of: repo)
        #expect(await eventually { observer.snapshot(of: repo)?.defaultBranch == .known("develop") })
        #expect(reader.defaultBranchCalls.count == 2)
        #expect(deliveries.last?.defaultBranch == .known("develop"))

        // The remote's HEAD moves. Same rule, through the refresh entry point.
        reader.setDefaultBranch { _, _, _ in .success("trunk") }
        observer.refresh(repo)
        #expect(await eventually { observer.snapshot(of: repo)?.defaultBranch == .known("trunk") })
        #expect(reader.defaultBranchCalls.count == 3)
        // And the polls after that cache again.
        let after = reader.statusCalls.count
        #expect(await eventually { reader.statusCalls.count >= after + 3 })
        #expect(reader.defaultBranchCalls.count == 3)
    }

    /// An invalidation that arrives during a read owes a fresh one. If every
    /// subscriber has gone inactive by the time the read completes, that debt
    /// is dropped rather than paid for a root nobody is looking at; the next
    /// activation is a refresh and reads then.
    @Test func anOwedStatusReadDoesNotStartWhileEverySubscriberIsInactive() async throws {
        let gate = Gate()
        let reader = ScriptedReader(
            status: { _, cancellation, index in
                if index == 1 {
                    return gate.wait(cancellation) ? .success(ScriptedReader.reading(modified: [])) : .failure(.cancelled)
                }
                return .success(ScriptedReader.reading(modified: []))
            },
            tree: { _, cancellation, _ in
                _ = Gate().wait(cancellation, timeout: 60)
                return .failure(.cancelled)
            }
        )
        let observer = RepositoryObserver(reader: reader, policy: policy(statusInterval: 0.02))
        let repo = try root("repo")

        let subscription = observer.observe(repo) { _ in }
        defer { subscription.cancel() }
        #expect(await eventually { reader.statusCalls.count == 1 })
        observer.invalidateStatus(of: repo)
        subscription.isActive = false
        gate.open()
        await settle(0.3)

        #expect(reader.statusCalls.count == 1)

        subscription.isActive = true
        #expect(await eventually { reader.statusCalls.count >= 2 })
    }

    @Test func anOwedTreeReadDoesNotStartWhileEverySubscriberIsInactive() async throws {
        let gate = Gate()
        let reader = ScriptedReader(tree: { _, cancellation, index in
            if index == 1 {
                return gate.wait(cancellation) ? .success([ScriptedReader.node("a.txt")]) : .failure(.cancelled)
            }
            return .success([ScriptedReader.node("b.txt")])
        })
        let observer = RepositoryObserver(reader: reader, policy: policy(statusInterval: 60))
        let repo = try root("repo")

        let subscription = observer.observe(repo) { _ in }
        defer { subscription.cancel() }
        #expect(await eventually { reader.treeCalls.count == 1 })
        observer.invalidateTree(of: repo)
        subscription.isActive = false
        gate.open()
        await settle(0.3)

        #expect(reader.treeCalls.count == 1)
        // The discarded answer was never published either.
        #expect(observer.snapshot(of: repo)?.tree.nodes.isEmpty ?? true)

        subscription.isActive = true
        #expect(await eventually { observer.snapshot(of: repo)?.tree.nodes.map(\.name) == ["b.txt"] })
        #expect(reader.treeCalls.count == 2)
    }

    @Test func anExplicitStatusInvalidationReadsNowAndResetsTheBackoff() async throws {
        let reader = ScriptedReader(status: { _, _, index in
            index <= 3 ? .failure(.timedOut) : .success(ScriptedReader.reading(modified: []))
        })
        let observer = RepositoryObserver(
            reader: reader,
            policy: policy(statusInterval: 0.02, failureBackoffBase: 0.5, failureBackoffCap: 1)
        )
        let repo = try root("repo")

        let subscription = observer.observe(repo) { _ in }
        defer { subscription.cancel() }
        #expect(await eventually { reader.statusCalls.count == 1 })
        // The next poll is half a second away on the backoff.
        observer.invalidateStatus(of: repo)
        #expect(await eventually(0.2) { reader.statusCalls.count == 2 })
    }

    /// Working-tree events reset backoff without discarding a known default
    /// branch. Metadata events relearn it. Status stays on the poll cadence.
    @Test func workingTreeEventsKeepTheDefaultBranchAndMetadataRelearnsIt() async throws {
        let reader = ScriptedReader(tree: neverAnswersTree)
        let observer = RepositoryObserver(reader: reader, policy: policy(statusInterval: 0.08))
        let repo = try root("repo")
        let subscription = observer.observe(repo) { _ in }
        defer { subscription.cancel() }
        #expect(await eventually { reader.statusCalls.count >= 1 && reader.defaultBranchCalls.count == 1 })
        reader.setDefaultBranch { _, _, _ in .success("develop") }

        for _ in 0 ..< 8 { observer.invalidate(repo, .workingTree) }
        await settle(0.2)
        #expect(reader.defaultBranchCalls.count == 1)
        #expect(observer.snapshot(of: repo)?.defaultBranch == .known(nil))

        observer.invalidate(repo, .metadata)
        #expect(await eventually { observer.snapshot(of: repo)?.defaultBranch == .known("develop") })
        #expect(reader.defaultBranchCalls.count == 2)
    }

    /// A burst of events while a status read is in flight discards that answer
    /// and does not start one read per event. After the cadence, one owed read
    /// converges.
    @Test func eventStatusStaysOnTheCadenceAndAStaleCompletionDoesNotPublish() async throws {
        let gate = Gate()
        let reader = ScriptedReader(
            status: { _, cancellation, index in
                if index == 1 {
                    return gate.wait(cancellation)
                        ? .success(ScriptedReader.reading(modified: ["stale.txt"]))
                        : .failure(.cancelled)
                }
                return .success(ScriptedReader.reading(modified: ["fresh.txt"]))
            },
            tree: neverAnswersTree
        )
        let observer = RepositoryObserver(
            reader: reader,
            policy: policy(statusInterval: 0.12)
        )
        let deliveries = Deliveries()
        let repo = try root("repo")
        let subscription = observer.observe(repo) { deliveries.record($0) }
        defer { subscription.cancel() }
        #expect(await eventually { reader.statusCalls.count == 1 })

        for _ in 0 ..< 12 { observer.invalidate(repo, .workingTree) }
        gate.open()
        await settle(0.05)
        #expect(!deliveries.snapshots.contains { $0.changes.map(\.path) == ["stale.txt"] })
        #expect(reader.statusCalls.count == 1)
        #expect(await eventually { deliveries.last.map { self.paths($0) } == ["fresh.txt"] })
        #expect(reader.statusCalls.count == 2)
    }

    /// Later events in a burst do not slide the due time forward, and shrinking
    /// the live interval pulls an already-pending event read earlier.
    @Test func eventsDoNotPushADueStatusReadLaterAndAnIntervalChangeReschedules() async throws {
        let reader = ScriptedReader(tree: neverAnswersTree)
        let observer = RepositoryObserver(reader: reader, policy: policy(statusInterval: 0.25))
        let repo = try root("repo")
        let subscription = observer.observe(repo) { _ in }
        defer { subscription.cancel() }
        #expect(await eventually { reader.statusCalls.count == 1 })

        observer.invalidate(repo, .workingTree)
        await settle(0.08)
        observer.invalidate(repo, .workingTree)
        await settle(0.08)
        #expect(reader.statusCalls.count == 1)
        #expect(await eventually(0.2) { reader.statusCalls.count == 2 })

        let after = reader.statusCalls.count
        observer.invalidate(repo, .workingTree)
        observer.statusInterval = 0.04
        #expect(await eventually(0.2) { reader.statusCalls.count > after })
    }

    /// A working-tree event after failures resets backoff so recovery does not
    /// wait the capped delay.
    @Test func aWorkingTreeEventResetsStatusBackoff() async throws {
        let reader = ScriptedReader(
            status: { _, _, index in
                index <= 1
                    ? .failure(.timedOut)
                    : .success(ScriptedReader.reading(modified: ["recovered.txt"]))
            },
            tree: neverAnswersTree
        )
        let observer = RepositoryObserver(
            reader: reader,
            policy: policy(statusInterval: 0.05, failureBackoffBase: 0.4, failureBackoffCap: 0.8)
        )
        let repo = try root("repo")
        let subscription = observer.observe(repo) { _ in }
        defer { subscription.cancel() }
        #expect(await eventually { reader.statusCalls.count == 1 })
        observer.invalidate(repo, .workingTree)
        #expect(await eventually(0.25) { observer.snapshot(of: repo)?.health == .ok })
    }

    @Test func pendingInvalidationKeepsMetadataWhenReasonsMerge() {
        #expect(RepositoryInvalidation.workingTree.merging(.metadata) == .metadata)
        #expect(RepositoryInvalidation.metadata.merging(.workingTree) == .metadata)
        #expect(RepositoryInvalidation.workingTree.merging(.workingTree) == .workingTree)
        #expect(RepositoryInvalidation.metadata.merging(.metadata) == .metadata)
    }

    /// A status read that lasts longer than `statusInterval` still spaces the
    /// next event-triggered read from that completion, not from when it started.
    /// Start-based spacing would let the follow-up begin immediately.
    @Test func eventStatusIsSpacedFromThePreviousCompletionNotTheStart() async throws {
        let gate = Gate()
        let interval: TimeInterval = 0.12
        let reader = ScriptedReader(
            status: { _, cancellation, index in
                if index == 1 {
                    return gate.wait(cancellation)
                        ? .success(ScriptedReader.reading(modified: []))
                        : .failure(.cancelled)
                }
                return .success(ScriptedReader.reading(modified: ["event.txt"]))
            },
            tree: neverAnswersTree
        )
        let observer = RepositoryObserver(reader: reader, policy: policy(statusInterval: interval))
        let repo = try root("completion-spacing")
        let subscription = observer.observe(repo) { _ in }
        defer { subscription.cancel() }

        #expect(await eventually { reader.statusCalls.count == 1 })
        await settle(interval + 0.05)
        #expect(reader.statusCalls.count == 1)
        gate.open()
        #expect(await eventually { observer.snapshot(of: repo)?.health == .ok })
        let completedAt = ProcessInfo.processInfo.systemUptime

        observer.invalidate(repo, .workingTree)
        await settle(interval * 0.45)
        #expect(reader.statusCalls.count == 1)
        #expect(await eventually { reader.statusCalls.count == 2 })
        #expect(reader.statusCalls[1].at - completedAt >= interval * 0.8)
    }

    /// Events arriving while a blocked read is already past the interval must
    /// not start the owed follow-up the instant that read finishes.
    @Test func eventsDuringABlockedStatusReadWaitTheIntervalAfterThatReadFinishes() async throws {
        let gate = Gate()
        let interval: TimeInterval = 0.12
        let reader = ScriptedReader(
            status: { _, cancellation, index in
                if index == 1 {
                    return gate.wait(cancellation)
                        ? .success(ScriptedReader.reading(modified: ["stale.txt"]))
                        : .failure(.cancelled)
                }
                return .success(ScriptedReader.reading(modified: ["fresh.txt"]))
            },
            tree: neverAnswersTree
        )
        let observer = RepositoryObserver(reader: reader, policy: policy(statusInterval: interval))
        let deliveries = Deliveries()
        let repo = try root("blocked-event-pressure")
        let subscription = observer.observe(repo) { deliveries.record($0) }
        defer { subscription.cancel() }

        #expect(await eventually { reader.statusCalls.count == 1 })
        for _ in 0 ..< 10 { observer.invalidate(repo, .workingTree) }
        await settle(interval + 0.05)
        #expect(reader.statusCalls.count == 1)

        gate.open()
        let finishedAt = ProcessInfo.processInfo.systemUptime
        await settle(0.04)
        #expect(reader.statusCalls.count == 1)
        #expect(!deliveries.snapshots.contains { $0.changes.map(\.path) == ["stale.txt"] })
        await settle(interval * 0.45)
        #expect(reader.statusCalls.count == 1)
        #expect(await eventually { reader.statusCalls.count == 2 })
        #expect(reader.statusCalls[1].at - finishedAt >= interval * 0.7)
        #expect(await eventually { deliveries.last.map { self.paths($0) } == ["fresh.txt"] })
    }

    /// Explicit refresh ignores event cadence even right after a slow completion.
    @Test func explicitRefreshAfterASlowStatusReadStartsImmediately() async throws {
        let gate = Gate()
        let interval: TimeInterval = 0.25
        let reader = ScriptedReader(
            status: { _, cancellation, index in
                if index == 1 {
                    return gate.wait(cancellation)
                        ? .success(ScriptedReader.reading(modified: []))
                        : .failure(.cancelled)
                }
                return .success(ScriptedReader.reading(modified: ["refreshed.txt"]))
            },
            tree: neverAnswersTree
        )
        let observer = RepositoryObserver(reader: reader, policy: policy(statusInterval: interval))
        let repo = try root("explicit-refresh-after-slow")
        let subscription = observer.observe(repo) { _ in }
        defer { subscription.cancel() }

        #expect(await eventually { reader.statusCalls.count == 1 })
        await settle(interval + 0.05)
        gate.open()
        #expect(await eventually { observer.snapshot(of: repo)?.health == .ok })
        observer.refresh(repo)
        #expect(await eventually(0.12) { reader.statusCalls.count == 2 })
    }
}
