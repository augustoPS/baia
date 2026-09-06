import Foundation
import Testing

@testable import GitWorkspace

/// A watch factory that records what was attached, on which thread, and lets
/// the test fire the callback or refuse attachment a few times.
final class FakeEvents: RepositoryEventsAttaching, @unchecked Sendable {
    final class Handle: RepositoryEventsHandle, @unchecked Sendable {
        let root: URL
        let invalidate: @Sendable (URL, RepositoryInvalidation) -> Void
        private let lock = NSLock()
        private var stopCalls = 0

        init(root: URL, invalidate: @escaping @Sendable (URL, RepositoryInvalidation) -> Void) {
            self.root = root
            self.invalidate = invalidate
        }

        var isStopped: Bool { lock.withLock { stopCalls > 0 } }
        var stopCount: Int { lock.withLock { stopCalls } }

        func stop() {
            lock.withLock { stopCalls += 1 }
        }
    }

    struct Refused: Error {}

    private let lock = NSLock()
    private var made: [Handle] = []
    private var attachedOnMainThread: [Bool] = []
    private var refusals: Int

    init(refuseFirst refusals: Int = 0) {
        self.refusals = refusals
    }

    var handles: [Handle] { lock.withLock { made } }
    var attachments: Int { lock.withLock { made.count + attachedOnMainThread.count - made.count } }
    var anyAttachedOnMain: Bool { lock.withLock { attachedOnMainThread.contains(true) } }
    var attempts: Int { lock.withLock { attachedOnMainThread.count } }

    func attach(root: URL, invalidate: @escaping @Sendable (URL, RepositoryInvalidation) -> Void) throws -> any RepositoryEventsHandle {
        lock.lock()
        attachedOnMainThread.append(Thread.isMainThread)
        if refusals > 0 {
            refusals -= 1
            lock.unlock()
            throw Refused()
        }
        let handle = Handle(root: root, invalidate: invalidate)
        made.append(handle)
        lock.unlock()
        return handle
    }

    /// Fires the newest live handle for `root`, as FSEvents would.
    func fire(_ root: URL, _ reason: RepositoryInvalidation = .workingTree) {
        let identity = RepositoryRoot(root).identity
        let handle = lock.withLock {
            made.last { RepositoryRoot($0.root).identity == identity && !$0.isStopped }
        }
        handle?.invalidate(root, reason)
    }
}

/// A tree read held open until the observer cancels it, so status-only cases
/// never publish a tree.
let neverAnswersTree: ScriptedReader.TreeScript = { _, cancellation, _ in
    _ = Gate().wait(cancellation, timeout: 60)
    return .failure(.cancelled)
}

/// The production binding and centre over the production observer: what a pane
/// does when it is pointed somewhere, pointed elsewhere, shares a root with
/// another pane, and goes away.
@Suite(.serialized) @MainActor final class RepositoryCenterTests {
    let fixture: DirectoryFixture

    init() throws {
        fixture = try DirectoryFixture()
    }

    private func policy(statusInterval: TimeInterval = 0.05) -> RepositoryObservationPolicy {
        RepositoryObservationPolicy(
            statusInterval: statusInterval,
            treeRefreshInterval: 60,
            treeCoalesceWindow: 0.02,
            minimumTreeReadSpacing: 0,
            failureBackoffBase: 0.05,
            failureBackoffCap: 0.2
        )
    }

    private func center(
        reader: ScriptedReader,
        events: FakeEvents? = FakeEvents(),
        statusInterval: TimeInterval = 0.05,
        retryDelay: TimeInterval = 0.05
    ) -> RepositoryCenter {
        RepositoryCenter(
            observer: RepositoryObserver(reader: reader, policy: policy(statusInterval: statusInterval)),
            events: events,
            attachmentRetryDelay: retryDelay
        )
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

    // MARK: A pane moving between roots

    /// A nil publication may synchronously redirect the same binding. The
    /// superseded outer call must not tag and submit A with B's generation,
    /// overwriting B in the resolver's single pending slot.
    @Test func reentrantNilCallbackKeepsTheRedirectedRootRequest() async throws {
        let a = try fixture.directory("reentrant-a")
        let b = try fixture.directory("reentrant-b")
        let queue = DispatchQueue(label: "RepositoryCenterTests.suspended-resolution")
        queue.suspend()
        let reader = ScriptedReader(
            status: { url, _, _ in
                .success(ScriptedReader.reading(head: url.lastPathComponent, modified: []))
            },
            tree: neverAnswersTree
        )
        let events = FakeEvents()
        let center = RepositoryCenter(
            observer: RepositoryObserver(reader: reader, policy: policy(statusInterval: 60)),
            events: events,
            queue: queue
        )
        let binding = center.makeBinding()
        var redirected = false
        binding.onChange = { snapshot in
            guard snapshot == nil, !redirected else { return }
            redirected = true
            binding.setRepositoryURL(b)
        }

        binding.setRepositoryURL(a)
        queue.resume()

        #expect(await eventually { binding.snapshot?.status?.head == .branch("reentrant-b") })
        #expect(binding.root == RepositoryRoot(b))
        #expect(center.observer.observedRoots == [RepositoryRoot(b)])
        #expect(events.handles.map { RepositoryRoot($0.root) } == [RepositoryRoot(b)])
        binding.releaseRoot()
    }

    /// **Delay A, switch to B, complete A last, through the binding.** The pane
    /// is pointed at A while A's read is held, then at B. The switch publishes
    /// nil at once; B's answer lands; A's read is released and completes; the
    /// pane's snapshot is still B's, and nothing from A was ever delivered.
    @Test func switchingRootsClearsAtOnceAndNeverDeliversTheOldRootsLateCompletion() async throws {
        let a = try fixture.directory("a")
        let b = try fixture.directory("b")
        let gate = Gate()
        let reader = ScriptedReader(
            status: { url, cancellation, _ in
                if url.lastPathComponent == "a" {
                    return gate.wait(cancellation)
                        ? .success(ScriptedReader.reading(head: "a-branch", modified: ["from-a.txt"]))
                        : .failure(.cancelled)
                }
                return .success(ScriptedReader.reading(head: "b-branch", modified: ["from-b.txt"]))
            },
            tree: neverAnswersTree
        )
        let center = center(reader: reader)
        let binding = center.makeBinding()
        let deliveries = Deliveries()
        binding.onChange = { deliveries.record($0) }

        binding.setRepositoryURL(a)
        #expect(deliveries.received.count == 1)
        #expect(deliveries.received[0] == nil)
        #expect(binding.snapshot == nil)
        #expect(await eventually { reader.statusCalls.count == 1 })

        binding.setRepositoryURL(b)
        // Cleared synchronously, before any resolution or read.
        #expect(binding.snapshot == nil)
        #expect(binding.root == nil)
        #expect(deliveries.received.count == 2)
        #expect(deliveries.received[1] == nil)
        #expect(await eventually { binding.snapshot?.status?.head == .branch("b-branch") })

        gate.open()
        await settle(0.2)

        #expect(binding.snapshot?.status?.head == .branch("b-branch"))
        #expect(binding.root?.path == RepositoryRoot(b).path)
        #expect(!deliveries.snapshots.contains { $0.changes.map(\.path).contains("from-a.txt") })
        #expect(center.observer.observedRoots == [RepositoryRoot(b)])
        binding.releaseRoot()
    }

    /// Pointing the binding at the same URL again is free: no release, no
    /// resolution, no read, which is what the once-a-second anchor poll relies on.
    @Test func repointingAtTheSameURLDoesNothing() async throws {
        let repo = try fixture.directory("repo")
        let reader = ScriptedReader(tree: neverAnswersTree)
        let events = FakeEvents()
        let center = center(reader: reader, events: events, statusInterval: 60)
        let binding = center.makeBinding()
        let deliveries = Deliveries()
        binding.onChange = { deliveries.record($0) }

        binding.setRepositoryURL(repo)
        #expect(await eventually { binding.snapshot != nil })
        let delivered = deliveries.received.count
        for _ in 0 ..< 20 { binding.setRepositoryURL(repo) }
        await settle(0.1)

        #expect(deliveries.received.count == delivered)
        #expect(reader.statusCalls.count == 1)
        #expect(events.handles.count == 1)
        binding.releaseRoot()
    }

    /// A stalled filesystem resolution leaves room for only the newest root.
    /// Otherwise a pane receiving rapid cwd announcements can queue one
    /// symlink walk per announcement behind the stalled call, long after every
    /// answer but the last has become obsolete.
    @Test func rapidRootChangesKeepOnlyOnePendingResolution() async throws {
        let resolutions = Tally()
        let firstResolution = Gate()
        let reader = ScriptedReader(tree: neverAnswersTree)
        let center = RepositoryCenter(
            observer: RepositoryObserver(reader: reader, policy: policy(statusInterval: 60)),
            events: nil,
            rootResolver: { url in
                resolutions.bump()
                if resolutions.count == 1 {
                    _ = firstResolution.wait(SubprocessCancellation())
                }
                return RepositoryRoot(url)
            }
        )
        let binding = center.makeBinding()

        binding.setRepositoryURL(fixture.root.appending(path: "repo-0"))
        #expect(await eventually { resolutions.count == 1 })
        for index in 1 ..< 100 {
            binding.setRepositoryURL(fixture.root.appending(path: "repo-\(index)"))
        }
        firstResolution.open()

        #expect(await eventually { binding.root?.url.lastPathComponent == "repo-99" })
        #expect(resolutions.count == 2)
        binding.releaseRoot()
    }

    /// Pointed outside a repository, the binding publishes nil and reads nothing.
    @Test func pointingOutsideARepositoryPublishesNilAndReadsNothing() async throws {
        let repo = try fixture.directory("repo")
        let reader = ScriptedReader(tree: neverAnswersTree)
        let center = center(reader: reader, statusInterval: 60)
        let binding = center.makeBinding()
        binding.setRepositoryURL(repo)
        #expect(await eventually { binding.snapshot != nil })

        binding.setRepositoryURL(nil)

        #expect(binding.snapshot == nil)
        #expect(center.observer.observedRoots.isEmpty)
        await settle(0.1)
        #expect(reader.statusCalls.count == 1)
    }

    // MARK: Sharing

    /// Two panes on one repository, one through a symlink and one with a
    /// trailing separator: one observation, one poll, one watch.
    @Test func twoBindingsOnOneRootShareOneObservationAndOneWatch() async throws {
        let real = try fixture.directory("real")
        let link = fixture.root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let reader = ScriptedReader(tree: neverAnswersTree)
        let events = FakeEvents()
        let center = center(reader: reader, events: events)
        let first = center.makeBinding()
        let second = center.makeBinding()

        first.setRepositoryURL(URL(filePath: real.path(percentEncoded: false) + "/"))
        second.setRepositoryURL(link)
        #expect(await eventually { first.snapshot != nil && second.snapshot != nil })
        #expect(await eventually { reader.statusCalls.count >= 4 })

        #expect(center.observer.observedRoots.count == 1)
        #expect(events.handles.count == 1)
        #expect(first.snapshot == second.snapshot)
        #expect(reader.statusCalls.count < 8)
        // Each keeps its own spelling for the shell and the display.
        #expect(second.root?.path == link.path(percentEncoded: false))
        first.releaseRoot()
        second.releaseRoot()
    }

    /// The first pane to leave does not stop the watch; the last one does, and
    /// the root is forgotten with it.
    @Test func theWatchStopsWithTheLastBindingAndTheRootIsForgotten() async throws {
        let repo = try fixture.directory("repo")
        let reader = ScriptedReader(tree: neverAnswersTree)
        let events = FakeEvents()
        let center = center(reader: reader, events: events)
        let first = center.makeBinding()
        let second = center.makeBinding()
        first.setRepositoryURL(repo)
        second.setRepositoryURL(repo)
        #expect(await eventually { events.handles.count == 1 && reader.statusCalls.count >= 1 })
        let handle = try #require(events.handles.first)

        first.releaseRoot()
        await settle(0.1)
        #expect(!handle.isStopped)

        second.releaseRoot()
        #expect(handle.isStopped)
        #expect(center.observer.observedRoots.isEmpty)
        #expect(second.snapshot == nil)
        // A read already admitted before the release can log its start while
        // cancellation is crossing the queue. Let that bounded teardown land,
        // then prove that no later cadence starts another one.
        await settle(0.1)
        let reads = reader.statusCalls.count
        await settle(0.2)
        #expect(reader.statusCalls.count == reads)
    }

    /// A binding that is dropped without an explicit release still lets go of
    /// its root, after a hop to the main actor.
    @Test func aDroppedBindingReleasesItsRoot() async throws {
        let repo = try fixture.directory("repo")
        let reader = ScriptedReader(tree: neverAnswersTree)
        let events = FakeEvents()
        let center = center(reader: reader, events: events)

        do {
            let binding = center.makeBinding()
            binding.setRepositoryURL(repo)
            #expect(await eventually { events.handles.count == 1 })
            _ = binding
        }

        #expect(await eventually { center.observer.observedRoots.isEmpty })
        #expect(events.handles.first?.isStopped == true)
    }

    /// `observe` immediately delivers a cached snapshot. If that callback
    /// releases the binding, the subscription and root retain must already be
    /// installed so the callback removes both exactly once.
    @Test func cachedSnapshotCallbackCanReleaseWithoutLeavingOwnershipBehind() async throws {
        let repo = try fixture.directory("cached-release")
        let reader = ScriptedReader(tree: neverAnswersTree)
        let events = FakeEvents()
        let center = center(reader: reader, events: events, statusInterval: 60)
        let keeper = center.makeBinding()
        keeper.setRepositoryURL(repo)
        #expect(await eventually { keeper.snapshot != nil && events.handles.count == 1 })
        let handle = try #require(events.handles.first)

        var binding: RepositoryBinding? = center.makeBinding()
        var cachedDeliveries = 0
        binding?.onChange = { [weak binding] snapshot in
            guard snapshot != nil else { return }
            cachedDeliveries += 1
            binding?.releaseRoot()
        }
        binding?.setRepositoryURL(repo)

        #expect(await eventually { cachedDeliveries == 1 })
        #expect(binding?.root == nil)
        #expect(binding?.snapshot == nil)
        #expect(center.observer.observedRoots == [RepositoryRoot(repo)])
        #expect(!handle.isStopped)

        keeper.releaseRoot()
        #expect(center.observer.observedRoots.isEmpty)
        #expect(handle.stopCount == 1)
        binding = nil
        await settle(0.05)
        #expect(handle.stopCount == 1)
    }

    /// The cached callback may rebind instead of release. Hold B's resolution
    /// so the test can inspect ownership after A's immediate delivery and
    /// before B is installed.
    @Test func cachedSnapshotCallbackCanRebindWithoutKeepingTheOldSubscription() async throws {
        let a = try fixture.directory("cached-rebind-a")
        let b = try fixture.directory("cached-rebind-b")
        let bResolution = Gate()
        let bResolutionCalls = Tally()
        let reader = ScriptedReader(tree: neverAnswersTree)
        let events = FakeEvents()
        let center = RepositoryCenter(
            observer: RepositoryObserver(reader: reader, policy: policy(statusInterval: 60)),
            events: events,
            rootResolver: { url in
                if url == b {
                    bResolutionCalls.bump()
                    _ = bResolution.wait(SubprocessCancellation())
                }
                return RepositoryRoot(url)
            }
        )
        let keeper = center.makeBinding()
        keeper.setRepositoryURL(a)
        #expect(await eventually { keeper.snapshot != nil && events.handles.count == 1 })
        let aHandle = try #require(events.handles.first)

        let binding = center.makeBinding()
        var redirected = false
        binding.onChange = { snapshot in
            guard snapshot != nil, !redirected else { return }
            redirected = true
            binding.setRepositoryURL(b)
        }
        binding.setRepositoryURL(a)
        #expect(await eventually { bResolutionCalls.count == 1 })

        keeper.releaseRoot()
        #expect(center.observer.observedRoots.isEmpty)
        #expect(aHandle.stopCount == 1)

        bResolution.open()
        #expect(await eventually { binding.snapshot?.root == RepositoryRoot(b) })
        #expect(binding.root == RepositoryRoot(b))
        #expect(center.observer.observedRoots == [RepositoryRoot(b)])
        #expect(await eventually { events.handles.count == 2 })
        let bHandle = try #require(events.handles.last)
        binding.releaseRoot()
        #expect(center.observer.observedRoots.isEmpty)
        #expect(bHandle.stopCount == 1)
    }

    // MARK: The tree

    /// **Empty repository through the binding.** The pane redraws on every
    /// change by reading the binding back, as the sidebar does, and the tree is
    /// read once and stored as empty.
    @Test func anEmptyTreeIsStoredAndRedrawsRequestNothing() async throws {
        let repo = try fixture.directory("repo")
        let reader = ScriptedReader()
        let center = center(reader: reader)
        let binding = center.makeBinding()
        var redraws = 0
        binding.onChange = { _ in
            redraws += 1
            _ = binding.snapshot?.tree.nodes
            _ = binding.snapshot?.changes
        }

        binding.setRepositoryURL(repo)
        #expect(await eventually { reader.statusCalls.count >= 6 })

        #expect(binding.snapshot?.tree == .empty)
        #expect(reader.treeCalls.count == 1)
        #expect(redraws >= 2)
        binding.releaseRoot()
    }

    // MARK: The watch

    /// A working-tree watch callback invalidates status and the tree but keeps
    /// the cached default branch. Ten callbacks in one burst are one tree read.
    @Test func aWorkingTreeWatchCallbackKeepsTheDefaultBranch() async throws {
        let repo = try fixture.directory("repo")
        let reader = ScriptedReader(tree: { _, _, index in .success([ScriptedReader.node("v\(index).txt")]) })
        let events = FakeEvents()
        let center = center(reader: reader, events: events, statusInterval: 60)
        let binding = center.makeBinding()
        binding.setRepositoryURL(repo)
        #expect(await eventually { binding.snapshot?.tree.nodes.map(\.name) == ["v1.txt"] })
        #expect(reader.defaultBranchCalls.count == 1)
        reader.setDefaultBranch { _, _, _ in .success("develop") }

        for _ in 0 ..< 10 { events.fire(repo, .workingTree) }

        #expect(await eventually { binding.snapshot?.tree.nodes.map(\.name) == ["v2.txt"] })
        await settle(0.1)
        #expect(binding.snapshot?.defaultBranch == .known(nil))
        #expect(reader.defaultBranchCalls.count == 1)
        #expect(reader.statusCalls.count == 1)
        #expect(reader.treeCalls.count == 2)
        binding.releaseRoot()
    }

    /// A gitdir/refs callback relearns the default branch on the next cadence
    /// status read. Explicit refresh is still immediate.
    @Test func aMetadataWatchCallbackRelearnsTheDefaultBranch() async throws {
        let repo = try fixture.directory("repo")
        let reader = ScriptedReader(tree: { _, _, index in .success([ScriptedReader.node("v\(index).txt")]) })
        let events = FakeEvents()
        let center = center(reader: reader, events: events, statusInterval: 0.05)
        let binding = center.makeBinding()
        binding.setRepositoryURL(repo)
        #expect(await eventually { binding.snapshot?.defaultBranch == .known(nil) })
        #expect(reader.defaultBranchCalls.count == 1)
        reader.setDefaultBranch { _, _, _ in .success("develop") }

        events.fire(repo, .metadata)
        #expect(await eventually { binding.snapshot?.defaultBranch == .known("develop") })
        #expect(reader.defaultBranchCalls.count == 2)
        binding.releaseRoot()
    }

    /// Same-turn working-tree then metadata keeps the metadata reason: the
    /// default branch is relearned, and the burst is one event-status read.
    @Test func sameTurnWorkingTreeThenMetadataRelearnsTheDefaultBranch() async throws {
        let repo = try fixture.directory("merge-metadata")
        let reader = ScriptedReader(tree: neverAnswersTree)
        let events = FakeEvents()
        let center = center(reader: reader, events: events, statusInterval: 0.05)
        let binding = center.makeBinding()
        binding.setRepositoryURL(repo)
        #expect(await eventually { binding.snapshot?.defaultBranch == .known(nil) })
        #expect(reader.defaultBranchCalls.count == 1)
        reader.setDefaultBranch { _, _, _ in .success("develop") }

        events.fire(repo, .workingTree)
        events.fire(repo, .metadata)
        #expect(await eventually { binding.snapshot?.defaultBranch == .known("develop") })
        #expect(reader.defaultBranchCalls.count == 2)
        #expect(reader.statusCalls.count == 2)
        binding.releaseRoot()
    }

    /// The reverse same-turn order still relearns: metadata is not lost inside
    /// a later working-tree callback.
    @Test func sameTurnMetadataThenWorkingTreeStillRelearnsTheDefaultBranch() async throws {
        let repo = try fixture.directory("merge-metadata-first")
        let reader = ScriptedReader(tree: neverAnswersTree)
        let events = FakeEvents()
        let center = center(reader: reader, events: events, statusInterval: 0.05)
        let binding = center.makeBinding()
        binding.setRepositoryURL(repo)
        #expect(await eventually { binding.snapshot?.defaultBranch == .known(nil) })
        reader.setDefaultBranch { _, _, _ in .success("develop") }

        events.fire(repo, .metadata)
        events.fire(repo, .workingTree)
        #expect(await eventually { binding.snapshot?.defaultBranch == .known("develop") })
        #expect(reader.defaultBranchCalls.count == 2)
        binding.releaseRoot()
    }

    /// A working-tree storm cannot fork one status per callback. After events
    /// settle, a later status change still lands.
    @Test func aWorkingTreeEventStormStaysWithinTheStatusCadenceAndConverges() async throws {
        let repo = try fixture.directory("repo")
        let reader = ScriptedReader(
            status: { _, _, index in
                .success(ScriptedReader.reading(head: "main", modified: index < 4 ? [] : ["late.txt"]))
            },
            tree: neverAnswersTree
        )
        let events = FakeEvents()
        let center = center(reader: reader, events: events, statusInterval: 0.15)
        let binding = center.makeBinding()
        binding.setRepositoryURL(repo)
        #expect(await eventually { reader.statusCalls.count == 1 })

        for _ in 0 ..< 20 {
            events.fire(repo, .workingTree)
            await settle(0.02)
        }
        #expect(reader.statusCalls.count <= 5)
        #expect(reader.defaultBranchCalls.count == 1)
        #expect(await eventually { binding.snapshot?.changes.map(\.path) == ["late.txt"] })
        binding.releaseRoot()
    }

    /// Explicit refresh ignores the event cadence and relearns the default branch.
    @Test func anExplicitRefreshReadsNowAndRelearnsTheDefaultBranch() async throws {
        let repo = try fixture.directory("repo")
        let reader = ScriptedReader(tree: neverAnswersTree)
        let events = FakeEvents()
        let center = center(reader: reader, events: events, statusInterval: 60)
        let binding = center.makeBinding()
        binding.setRepositoryURL(repo)
        #expect(await eventually { reader.statusCalls.count == 1 && reader.defaultBranchCalls.count == 1 })
        reader.setDefaultBranch { _, _, _ in .success("develop") }

        #expect(binding.refresh())
        #expect(await eventually { binding.snapshot?.defaultBranch == .known("develop") })
        #expect(reader.statusCalls.count == 2)
        #expect(reader.defaultBranchCalls.count == 2)
        binding.releaseRoot()
    }

    @Test func aBindingWithoutAResolvedRootRefusesExplicitRefresh() {
        let reader = ScriptedReader(tree: neverAnswersTree)
        let center = center(reader: reader, statusInterval: 60)
        let binding = center.makeBinding()

        #expect(!binding.refresh())
        #expect(reader.statusCalls.isEmpty)
        #expect(reader.treeCalls.isEmpty)
    }

    /// Watches are attached off the main actor, and a refused attachment is
    /// retried while the root is held, not surfaced and not given up on.
    @Test func attachmentHappensOffMainAndRetriesAfterRefusal() async throws {
        let repo = try fixture.directory("repo")
        let reader = ScriptedReader(tree: neverAnswersTree)
        let events = FakeEvents(refuseFirst: 2)
        let center = center(reader: reader, events: events, statusInterval: 60, retryDelay: 0.05)
        let binding = center.makeBinding()

        binding.setRepositoryURL(repo)

        #expect(await eventually { events.handles.count == 1 })
        #expect(events.attempts == 3)
        #expect(!events.anyAttachedOnMain)
        // Polling never waited for the watch.
        #expect(reader.statusCalls.count >= 1)
        binding.releaseRoot()
    }

    /// A callback from a watch that was released, and one that arrives for a
    /// root re-attached since, reach only the current attachment.
    @Test func aStaleWatchCallbackIsFencedByGeneration() async throws {
        let repo = try fixture.directory("repo")
        let reader = ScriptedReader(tree: neverAnswersTree)
        let events = FakeEvents()
        let center = center(reader: reader, events: events, statusInterval: 60)
        let binding = center.makeBinding()
        binding.setRepositoryURL(repo)
        #expect(await eventually { events.handles.count == 1 && reader.statusCalls.count == 1 })
        let old = try #require(events.handles.first)

        binding.setRepositoryURL(nil)
        #expect(old.isStopped)
        old.invalidate(repo, .workingTree)
        await settle(0.1)
        #expect(reader.statusCalls.count == 1)

        binding.setRepositoryURL(repo)
        #expect(await eventually { events.handles.count == 2 && reader.statusCalls.count == 2 })
        old.invalidate(repo, .workingTree)
        await settle(0.1)
        #expect(reader.statusCalls.count == 2)

        events.fire(repo)
        center.statusInterval = 0.04
        #expect(await eventually { reader.statusCalls.count == 3 })
        binding.releaseRoot()
    }

    /// A refusal that keeps being retried stops being retried when the root is
    /// released, and a watch that lands after the release is stopped at once.
    @Test func releaseCancelsAPendingAttachmentRetry() async throws {
        let repo = try fixture.directory("repo")
        let reader = ScriptedReader(tree: neverAnswersTree)
        let events = FakeEvents(refuseFirst: 100)
        let center = center(reader: reader, events: events, statusInterval: 60, retryDelay: 0.02)
        let binding = center.makeBinding()
        binding.setRepositoryURL(repo)
        #expect(await eventually { events.attempts >= 3 })

        binding.releaseRoot()
        let attempts = events.attempts
        await settle(0.15)

        #expect(events.attempts <= attempts + 1)
        #expect(center.observer.observedRoots.isEmpty)
    }

    /// Activity flows through the binding to whichever root it is on, including
    /// one it is pointed at while inactive.
    @Test func activityFollowsTheBindingAcrossRoots() async throws {
        let repo = try fixture.directory("repo")
        let reader = ScriptedReader(tree: neverAnswersTree)
        let center = center(reader: reader)
        let binding = center.makeBinding()
        binding.isActive = false

        binding.setRepositoryURL(repo)
        await settle(0.15)
        #expect(reader.statusCalls.isEmpty)

        binding.isActive = true
        #expect(await eventually { reader.statusCalls.count >= 1 })
        binding.isActive = false
        await settle(0.1)
        let reads = reader.statusCalls.count
        await settle(0.2)
        #expect(reader.statusCalls.count == reads)
        binding.releaseRoot()
    }

    /// The shared cadence: one interval for every root, set once.
    @Test func theStatusIntervalIsSharedByEveryRoot() async throws {
        let a = try fixture.directory("a")
        let b = try fixture.directory("b")
        let reader = ScriptedReader(tree: neverAnswersTree)
        let center = center(reader: reader, statusInterval: 0.02)
        let onA = center.makeBinding()
        let onB = center.makeBinding()
        onA.setRepositoryURL(a)
        onB.setRepositoryURL(b)
        #expect(await eventually { reader.statusCalls.count >= 8 })

        center.statusInterval = 0.5
        await settle(0.1)
        let reads = reader.statusCalls.count
        await settle(0.2)
        #expect(reader.statusCalls.count <= reads + 2)
        onA.releaseRoot()
        onB.releaseRoot()
    }
}
