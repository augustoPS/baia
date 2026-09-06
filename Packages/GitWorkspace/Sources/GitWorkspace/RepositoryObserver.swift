import Foundation

/// How often and how patiently one root is read.
///
/// Every interval is real time. The defaults are the product's; a test compresses
/// them and drives the same scheduler, so what the test proves is the scheduler
/// and not a clock it injected.
public struct RepositoryObservationPolicy: Sendable, Equatable {
    /// Seconds between status reads of an active root. Follows the Settings
    /// value `gitPollSeconds`, whose live default is 2.
    public var statusInterval: TimeInterval

    /// Seconds between tree reads of an active root when nothing has asked for
    /// one. The backstop for a change no event delivered and no status compare
    /// caught: a clean checkout whose head name did not change, a filesystem
    /// FSEvents does not serve.
    public var treeRefreshInterval: TimeInterval

    /// How long after an invalidation the tree read waits, so a burst of events
    /// from a build or a checkout becomes one read rather than thousands.
    public var treeCoalesceWindow: TimeInterval

    /// Least time between two tree reads of one root, however many invalidations
    /// arrive. A read over a whole repository is not free.
    public var minimumTreeReadSpacing: TimeInterval

    /// First retry delay after a failed read; doubles per consecutive failure.
    public var failureBackoffBase: TimeInterval

    /// The backoff never exceeds this, and reads continue at this cadence for as
    /// long as they keep failing. Nothing stops after a count of failures: a
    /// repository mid-clone, a mount that comes back, or a git installed later
    /// all recover without a resubscribe.
    public var failureBackoffCap: TimeInterval

    public init(
        statusInterval: TimeInterval = 2,
        treeRefreshInterval: TimeInterval = 30,
        treeCoalesceWindow: TimeInterval = 1,
        minimumTreeReadSpacing: TimeInterval = 3,
        failureBackoffBase: TimeInterval = 1,
        failureBackoffCap: TimeInterval = 60
    ) {
        self.statusInterval = max(0, statusInterval)
        self.treeRefreshInterval = max(0, treeRefreshInterval)
        self.treeCoalesceWindow = max(0, treeCoalesceWindow)
        self.minimumTreeReadSpacing = max(0, minimumTreeReadSpacing)
        self.failureBackoffBase = max(0, failureBackoffBase)
        self.failureBackoffCap = max(0, failureBackoffCap)
    }

    public static let `default` = RepositoryObservationPolicy()

    /// `min(base × 2^(attempts − 1), cap)`, and zero before the first failure.
    public func backoff(afterAttempts attempts: Int) -> TimeInterval {
        guard attempts > 0 else { return 0 }
        let doubled = failureBackoffBase * pow(2, Double(min(attempts, 30) - 1))
        return min(doubled, failureBackoffCap)
    }
}

/// One subscriber's hold on one root.
///
/// Panes and sidebars hold one each. A subscription is the identity a surface
/// has with the observer, and it is distinct from the request generations the
/// observer uses to discard stale completions: a pane switching repositories
/// cancels this and takes a new one, and the old root's late completion cannot
/// reach the new handler because the handler is not subscribed to it.
///
/// Dropping the last reference releases the subscription as `cancel()` would,
/// but only after a hop to the main actor. Cancel explicitly where the timing
/// matters.
@MainActor
public final class RepositorySubscription {
    public let id: UUID
    public let root: RepositoryRoot

    /// Whether this subscriber wants reads right now. A root is read while any
    /// of its subscribers is active; a window resigning key sets its panes'
    /// subscriptions inactive without touching another window's.
    public var isActive: Bool {
        didSet {
            guard isActive != oldValue, !isCancelled else { return }
            observer?.activityChanged(for: root)
        }
    }

    public private(set) var isCancelled = false

    let onChange: @MainActor (RepositorySnapshot?) -> Void
    private weak var observer: RepositoryObserver?
    private let release: @Sendable () -> Void

    init(
        root: RepositoryRoot,
        active: Bool,
        observer: RepositoryObserver,
        onChange: @escaping @MainActor (RepositorySnapshot?) -> Void
    ) {
        let id = UUID()
        self.id = id
        self.root = root
        isActive = active
        self.observer = observer
        self.onChange = onChange
        release = { [weak observer] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { observer?.release(subscription: id, of: root) }
            }
        }
    }

    deinit {
        release()
    }

    /// Stops delivery and releases the root. The last subscriber to leave a root
    /// cancels its in-flight reads and stops its polling.
    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        observer?.release(subscription: id, of: root)
    }
}

/// The one owner of every repository the workspace is looking at.
///
/// One read per root per cadence, not per pane: two panes on one repository are
/// two subscribers to one observation, and two spellings of one repository are
/// one root by ``RepositoryRoot``'s identity.
///
/// **Publication rule.** A read completes on the read queue and hops to the main
/// actor, where, in this order and with no field written before the guards: the
/// observation is looked up by its identity (a released root discards the
/// completion), the completion's request generation is compared with the root's
/// current one (an invalidation during the read discards the completion and owes
/// one fresh read), then the fields are assigned, one snapshot is built, and it
/// is published only when it differs from the last by ``RepositorySnapshot``'s
/// rendered-field equality. The status and the tree are read on their own
/// cadences, so a snapshot carries the latest known answer of each with its own
/// health, published as one value; it does not claim the two were read at the
/// same moment.
///
/// **Bounds.** At most one status read and one tree read are in flight per root.
/// A request during a read is owed, not stacked. Tree requests are coalesced
/// over ``RepositoryObservationPolicy/treeCoalesceWindow`` and spaced by
/// ``RepositoryObservationPolicy/minimumTreeReadSpacing``. A completed read
/// never requests another read of its own kind; the next one comes from the
/// cadence, an invalidation, a status change or a failure retry.
///
/// **What this does not do.** It does not watch the filesystem. Events reach it
/// through ``invalidateTree(of:)`` and ``invalidateStatus(of:)`` from whatever
/// the app adapter attaches, and the polling here is the backstop for events
/// that never arrive. It draws nothing and says nothing about staleness; the
/// snapshot carries ``RepositorySnapshot/health`` and a surface decides.
@MainActor
public final class RepositoryObserver {
    private let reader: any RepositoryReading
    private let queue: DispatchQueue
    private var observations: [String: Observation] = [:]

    public private(set) var policy: RepositoryObservationPolicy

    public init(
        reader: any RepositoryReading = GitCommand(),
        policy: RepositoryObservationPolicy = .default,
        queue: DispatchQueue = DispatchQueue(
            label: "pasqualotto.baia.repository-reads",
            qos: .utility,
            attributes: .concurrent
        )
    ) {
        self.reader = reader
        self.policy = policy
        self.queue = queue
    }

    /// The status cadence, live. Restarted in place for every root with a poll
    /// pending, measured from that root's last completion, so a Settings edit
    /// takes effect at the next tick rather than after a focus change.
    public var statusInterval: TimeInterval {
        get { policy.statusInterval }
        set {
            let interval = max(0, newValue)
            guard interval != policy.statusInterval else { return }
            policy.statusInterval = interval
            for observation in observations.values {
                if observation.statusTimer != nil {
                    if observation.pendingEvent != nil {
                        scheduleEventStatus(observation)
                    } else {
                        scheduleStatusPoll(observation)
                    }
                } else if observation.pendingEvent != nil,
                          observation.statusInFlight == nil,
                          observation.isActive
                {
                    scheduleEventStatus(observation)
                }
            }
        }
    }

    /// Every root with at least one subscriber.
    public var observedRoots: [RepositoryRoot] {
        observations.values.map(\.root)
    }

    /// Begins or joins observation of `root`.
    ///
    /// `onChange` fires on the main actor once immediately with what is already
    /// published for the root, which is nil for a root nothing has read, and then
    /// on every publication. A subscriber therefore never draws another root's
    /// answer and never keeps a previous root's answer past the switch.
    public func observe(
        _ root: RepositoryRoot,
        active: Bool = true,
        onChange: @escaping @MainActor (RepositorySnapshot?) -> Void
    ) -> RepositorySubscription {
        let observation: Observation
        if let existing = observations[root.identity] {
            observation = existing
        } else {
            observation = Observation(root: root)
            observations[root.identity] = observation
        }
        let subscription = RepositorySubscription(
            root: observation.root,
            active: active,
            observer: self,
            onChange: onChange
        )
        observation.subscriptions.append(Weak(subscription))
        onChange(observation.published)
        activityChanged(for: root)
        return subscription
    }

    /// The current publication for `root`, without subscribing.
    public func snapshot(of root: RepositoryRoot) -> RepositorySnapshot? {
        observations[root.identity]?.published
    }

    /// A filesystem change under `root` was observed. The tree is re-read after
    /// the coalescing window, an in-flight tree read is discarded and re-owed,
    /// and a failing tree's backoff restarts.
    public func invalidateTree(of root: RepositoryRoot) {
        guard let observation = observations[root.identity] else { return }
        requestTreeChange(observation)
    }

    /// The repository's state changed outside a working-tree write, or the owner
    /// asked. The status is re-read now, an in-flight status read is discarded
    /// and re-owed, and a failing status's backoff restarts.
    ///
    /// The default branch is re-read too. Ordinary polling caches it, because a
    /// remote's HEAD changes approximately never and re-learning it on every
    /// tick would put a second process behind every poll. An explicit refresh
    /// or a metadata invalidation is exactly the moment it can have changed: a
    /// remote added, `git remote set-head`, a fresh clone's refs fetched. Caching
    /// through those would leave a tab labelled for a default the repository no
    /// longer has, for the life of the observation.
    public func invalidateStatus(of root: RepositoryRoot) {
        guard let observation = observations[root.identity] else { return }
        observation.statusAttempts = 0
        observation.defaultBranch = .unresolved
        observation.pendingEvent = nil
        observation.statusGeneration &+= 1
        if observation.statusInFlight != nil {
            observation.statusOwed = true
            return
        }
        guard observation.isActive else { return }
        startStatusRead(observation)
    }

    /// A watch callback. Working-tree writes invalidate status and the tree
    /// without discarding a known default branch. Metadata and rescans relearn
    /// it. Event-triggered status is not more frequent than ``statusInterval``
    /// since the last status completion; a due read is not pushed later by more
    /// events. Tree spacing is unchanged. Explicit ``refresh(_:)`` stays now.
    public func invalidate(_ root: RepositoryRoot, _ reason: RepositoryInvalidation) {
        guard let observation = observations[root.identity] else { return }
        observation.statusAttempts = 0
        observation.pendingEvent = observation.pendingEvent?.merging(reason) ?? reason
        if reason == .metadata {
            observation.defaultBranch = .unresolved
        }
        requestTreeChange(observation)
        requestEventStatus(observation)
    }

    /// Both invalidations, for an explicit refresh command. Immediate, and the
    /// default branch is re-read.
    public func refresh(_ root: RepositoryRoot) {
        invalidateStatus(of: root)
        invalidateTree(of: root)
    }

    // MARK: - Subscriptions

    func release(subscription id: UUID, of root: RepositoryRoot) {
        guard let observation = observations[root.identity] else { return }
        observation.subscriptions.removeAll { $0.value == nil || $0.value?.id == id }
        if observation.subscriptions.isEmpty {
            retire(observation)
        } else {
            activityChanged(for: root)
        }
    }

    func activityChanged(for root: RepositoryRoot) {
        guard let observation = observations[root.identity] else { return }
        let active = observation.isActive
        guard active != observation.wasActive else { return }
        observation.wasActive = active
        if active {
            activate(observation)
        } else {
            observation.statusTimer?.cancel()
            observation.statusTimer = nil
            observation.statusEventFiresAt = nil
            observation.pendingEvent = nil
            observation.treeTimer?.cancel()
            observation.treeTimer = nil
            observation.treeTimerFiresAt = nil
        }
    }

    /// Re-enabling observation is a refresh: the status is read now and the
    /// tree as soon as its spacing allows.
    private func activate(_ observation: Observation) {
        if observation.statusInFlight == nil {
            observation.statusTimer?.cancel()
            observation.statusTimer = nil
            startStatusRead(observation)
        }
        if observation.treeInFlight == nil {
            scheduleTreeRead(observation, notBefore: now)
        }
    }

    /// The last subscriber left: cancel what is in flight, stop what is
    /// scheduled, and forget the root. A completion still on its way back finds
    /// no observation and is discarded.
    private func retire(_ observation: Observation) {
        observation.statusTimer?.cancel()
        observation.treeTimer?.cancel()
        observation.statusEventFiresAt = nil
        observation.pendingEvent = nil
        observation.statusInFlight?.cancel()
        observation.treeInFlight?.cancel()
        observations[observation.root.identity] = nil
    }

    // MARK: - Status reads

    private func startStatusRead(_ observation: Observation) {
        let cancellation = SubprocessCancellation()
        observation.statusInFlight = cancellation
        observation.pendingEvent = nil
        observation.statusEventFiresAt = nil
        observation.statusEventDiscardedInFlight = false
        let generation = observation.statusGeneration
        let identity = observation.id
        // Physical identity, not the first subscriber's alias spelling.
        let root = observation.root.processURL
        let reader = self.reader
        let needsDefaultBranch = observation.defaultBranch == .unresolved
        queue.async { [weak self] in
            let read = reader.readStatus(ofRepositoryRoot: root, cancellation: cancellation)
            // Resolved once per root, beside the first status that answered, and
            // never on a timer: the default branch changes approximately never.
            var defaultBranch: RepositorySnapshot.DefaultBranchState?
            if needsDefaultBranch, case .success = read, !cancellation.isCancelled,
               case let .success(name) = reader.readDefaultBranch(ofRepositoryRoot: root, cancellation: cancellation) {
                defaultBranch = .known(name)
            }
            let isLinkedWorktree = GitDirectory.isLinkedWorktree(repositoryRoot: root)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.completeStatusRead(
                        observation: identity,
                        generation: generation,
                        read: read,
                        defaultBranch: defaultBranch,
                        isLinkedWorktree: isLinkedWorktree
                    )
                }
            }
        }
    }

    private func completeStatusRead(
        observation identity: UUID,
        generation: UInt64,
        read: RepositoryStatusRead,
        defaultBranch: RepositorySnapshot.DefaultBranchState?,
        isLinkedWorktree: Bool
    ) {
        // A released root writes nothing. A superseded generation records that
        // the work finished so event spacing is from this completion, then
        // owes the follow-up without publishing snapshot fields.
        guard let observation = observations.values.first(where: { $0.id == identity }) else { return }
        observation.statusInFlight = nil
        observation.lastStatusCompletedAt = now
        guard generation == observation.statusGeneration else {
            observation.statusEventDiscardedInFlight = false
            continueStatusReads(observation)
            return
        }

        switch read {
        case let .success(reading):
            observation.statusAttempts = 0
            observation.status = reading.status
            observation.changes = reading.changes
            observation.readAt = Date()
            observation.health = .ok
            if let defaultBranch { observation.defaultBranch = defaultBranch }
            observation.isLinkedWorktree = isLinkedWorktree
            // The head or the set of changed paths moving is a fact about the
            // working tree that no filesystem event may have delivered, so it
            // asks for a tree read. A completion whose status is unchanged asks
            // for nothing.
            let head = reading.status.head
            let paths = Set(reading.changes.map(\.rawPath))
            let changed = observation.lastHead != nil
                && (observation.lastHead != head || observation.lastPathSet != paths)
            observation.lastHead = head
            observation.lastPathSet = paths
            if changed { requestTreeChange(observation) }
        case let .failure(failure):
            observation.statusAttempts += 1
            observation.health = .failed(failure, attempts: observation.statusAttempts)
            if failure == .notARepository {
                observation.status = nil
                observation.changes = []
                observation.lastHead = nil
                observation.lastPathSet = nil
            }
        }
        publish(observation)
        continueStatusReads(observation)
    }

    /// After a status completion: the owed read, the next poll, or nothing.
    ///
    /// Nothing when every subscriber is inactive, owed or not. An invalidation
    /// that arrived during the read set the owed flag before the window resigned
    /// key, and honouring it now would fork git for a root nobody is looking at.
    /// The flag is dropped rather than kept, because reactivation is itself a
    /// refresh and would read again anyway.
    private func continueStatusReads(_ observation: Observation) {
        guard observation.isActive else {
            observation.statusOwed = false
            observation.pendingEvent = nil
            return
        }
        if observation.statusOwed {
            observation.statusOwed = false
            observation.pendingEvent = nil
            startStatusRead(observation)
        } else if observation.pendingEvent != nil {
            scheduleEventStatus(observation)
        } else {
            scheduleStatusPoll(observation)
        }
    }

    /// Event-triggered status: due at the existing cadence since the last
    /// completion, started now if that time has already passed. More events
    /// merge the reason and do not push a due read later.
    private func requestEventStatus(_ observation: Observation) {
        if observation.statusInFlight != nil {
            if !observation.statusEventDiscardedInFlight {
                observation.statusGeneration &+= 1
                observation.statusEventDiscardedInFlight = true
            }
            return
        }
        guard observation.isActive else { return }
        scheduleEventStatus(observation)
    }

    private func scheduleEventStatus(_ observation: Observation) {
        let fireAt = max(now, (observation.lastStatusCompletedAt ?? now) + policy.statusInterval)
        if let pending = observation.statusEventFiresAt, pending <= fireAt { return }
        observation.statusTimer?.cancel()
        observation.statusEventFiresAt = fireAt
        observation.statusTimer = schedule(at: fireAt) { [weak self, weak observation] in
            guard let self, let observation else { return }
            observation.statusTimer = nil
            observation.statusEventFiresAt = nil
            guard observations[observation.root.identity] === observation,
                  observation.isActive,
                  observation.statusInFlight == nil
            else { return }
            startStatusRead(observation)
        }
    }

    /// The next status read, `statusInterval` after the last completion, or the
    /// failure backoff when that is longer.
    private func scheduleStatusPoll(_ observation: Observation) {
        observation.statusTimer?.cancel()
        observation.statusEventFiresAt = nil
        let interval = max(policy.statusInterval, policy.backoff(afterAttempts: observation.statusAttempts))
        let fireAt = (observation.lastStatusCompletedAt ?? now) + interval
        observation.statusTimer = schedule(at: fireAt) { [weak self, weak observation] in
            guard let self, let observation else { return }
            observation.statusTimer = nil
            guard observations[observation.root.identity] === observation,
                  observation.isActive,
                  observation.statusInFlight == nil
            else { return }
            startStatusRead(observation)
        }
    }

    // MARK: - Tree reads

    /// A change was observed or reported. Resets the backoff, discards a read in
    /// flight while owing one fresh read, and otherwise coalesces.
    private func requestTreeChange(_ observation: Observation) {
        observation.treeAttempts = 0
        if observation.treeInFlight != nil {
            observation.treeGeneration &+= 1
            observation.treeOwed = true
            return
        }
        guard observation.isActive else { return }
        scheduleTreeRead(observation, notBefore: now + policy.treeCoalesceWindow)
    }

    /// One pending tree read per root. A request earlier than the pending one
    /// moves it earlier; a later one is absorbed. Nothing fires sooner than the
    /// spacing since the last read started.
    private func scheduleTreeRead(_ observation: Observation, notBefore: TimeInterval) {
        var fireAt = notBefore
        if let started = observation.lastTreeStartedAt {
            fireAt = max(fireAt, started + policy.minimumTreeReadSpacing)
        }
        if let pending = observation.treeTimerFiresAt, pending <= fireAt { return }
        observation.treeTimer?.cancel()
        observation.treeTimerFiresAt = fireAt
        observation.treeTimer = schedule(at: fireAt) { [weak self, weak observation] in
            guard let self, let observation else { return }
            observation.treeTimer = nil
            observation.treeTimerFiresAt = nil
            guard observations[observation.root.identity] === observation,
                  observation.isActive
            else { return }
            if observation.treeInFlight != nil {
                observation.treeOwed = true
                return
            }
            startTreeRead(observation)
        }
    }

    private func startTreeRead(_ observation: Observation) {
        let cancellation = SubprocessCancellation()
        observation.treeInFlight = cancellation
        observation.lastTreeStartedAt = now
        let generation = observation.treeGeneration
        let identity = observation.id
        let root = observation.root.processURL
        let reader = self.reader
        queue.async { [weak self] in
            let read = reader.readTree(ofRepositoryRoot: root, cancellation: cancellation)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.completeTreeRead(observation: identity, generation: generation, read: read)
                }
            }
        }
    }

    private func completeTreeRead(observation identity: UUID, generation: UInt64, read: RepositoryTreeRead) {
        guard let observation = observations.values.first(where: { $0.id == identity }) else { return }
        observation.treeInFlight = nil
        guard generation == observation.treeGeneration else {
            // Invalidated while reading: the answer describes a tree that has
            // already changed. One fresh read is owed and nothing is published.
            // Owed to an active root only, for the reason `continueStatusReads`
            // gives: reactivation reads again regardless.
            let owed = observation.treeOwed
            observation.treeOwed = false
            if owed, observation.isActive {
                scheduleTreeRead(observation, notBefore: now)
            }
            return
        }

        let succeeded: Bool
        switch read {
        case let .success(nodes):
            observation.treeAttempts = 0
            observation.tree = nodes.isEmpty ? .empty : .loaded(nodes)
            succeeded = true
        case let .failure(failure):
            observation.treeAttempts += 1
            observation.tree = .failed(failure, attempts: observation.treeAttempts)
            succeeded = false
        }
        publish(observation)

        // The next read comes from an owed invalidation, the periodic backstop,
        // or the failure backoff. Never from this completion having happened,
        // and never for a root every subscriber has left inactive.
        let owed = observation.treeOwed
        observation.treeOwed = false
        guard observation.isActive else { return }
        if owed {
            scheduleTreeRead(observation, notBefore: now)
        } else {
            let delay = succeeded
                ? policy.treeRefreshInterval
                : policy.backoff(afterAttempts: observation.treeAttempts)
            scheduleTreeRead(observation, notBefore: now + delay)
        }
    }

    // MARK: - Publication

    private func publish(_ observation: Observation) {
        let candidate = RepositorySnapshot(
            root: observation.root,
            generation: observation.publishedGeneration &+ 1,
            readAt: observation.readAt,
            status: observation.status,
            changes: observation.changes,
            defaultBranch: observation.defaultBranch,
            isLinkedWorktree: observation.isLinkedWorktree,
            tree: observation.tree,
            health: observation.health
        )
        if let published = observation.published, published == candidate { return }
        observation.publishedGeneration &+= 1
        observation.published = candidate
        // Over a copy: a handler may cancel its own or another subscription.
        for slot in observation.subscriptions {
            guard let subscription = slot.value, !subscription.isCancelled else { continue }
            subscription.onChange(candidate)
        }
    }

    // MARK: - Scheduling

    /// Monotonic seconds. A wall-clock change cannot lengthen or shorten a wait.
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func schedule(at fireAt: TimeInterval, _ body: @escaping @MainActor () -> Void) -> DispatchWorkItem {
        let delay = max(0, fireAt - now)
        let item = DispatchWorkItem { MainActor.assumeIsolated { body() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }

    // MARK: - Per-root state

    private struct Weak {
        weak var value: RepositorySubscription?
        init(_ value: RepositorySubscription) { self.value = value }
    }

    /// Everything the observer holds for one root. Mutated on the main actor only.
    @MainActor
    private final class Observation {
        let id = UUID()
        let root: RepositoryRoot
        var subscriptions: [Weak] = []
        var wasActive = false

        var published: RepositorySnapshot?
        var publishedGeneration: UInt64 = 0

        var status: RepositoryStatus?
        var changes: [RepositoryFileChange] = []
        var readAt: Date?
        var health: RepositorySnapshot.ReadHealth = .unread
        var defaultBranch: RepositorySnapshot.DefaultBranchState = .unresolved
        var isLinkedWorktree = false
        var lastHead: RepositoryStatus.Head?
        var lastPathSet: Set<RepositoryPath>?

        var statusGeneration: UInt64 = 0
        var statusInFlight: SubprocessCancellation?
        var statusOwed = false
        var statusAttempts = 0
        var lastStatusCompletedAt: TimeInterval?
        var statusTimer: DispatchWorkItem?
        var pendingEvent: RepositoryInvalidation?
        var statusEventFiresAt: TimeInterval?
        var statusEventDiscardedInFlight = false

        var tree: RepositorySnapshot.TreeState = .unread
        var treeGeneration: UInt64 = 0
        var treeInFlight: SubprocessCancellation?
        var treeOwed = false
        var treeAttempts = 0
        var lastTreeStartedAt: TimeInterval?
        var treeTimer: DispatchWorkItem?
        var treeTimerFiresAt: TimeInterval?

        init(root: RepositoryRoot) {
            self.root = root
        }

        var isActive: Bool {
            subscriptions.contains { $0.value?.isActive == true && $0.value?.isCancelled == false }
        }
    }
}
