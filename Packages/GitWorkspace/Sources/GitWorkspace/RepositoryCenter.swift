import Foundation

/// A running filesystem watch on one root, owned by ``RepositoryCenter`` from
/// the moment it is attached until the last binding on that root releases.
public protocol RepositoryEventsHandle: AnyObject, Sendable {
    /// Stops delivery at once and finishes teardown on its own; never blocks the
    /// caller. Safe to call more than once.
    func stop()
}

/// Makes filesystem watches. The app supplies an FSEvents-backed one; tests
/// supply one that records what was attached and drives the callback by hand.
public protocol RepositoryEventsAttaching: Sendable {
    /// Called off the main actor, because attachment resolves Git metadata paths
    /// and starts a stream synchronously. Throws when the watch could not start;
    /// the centre retries while the root is still observed.
    func attach(
        root: URL,
        invalidate: @escaping @Sendable (URL, RepositoryInvalidation) -> Void
    ) throws -> any RepositoryEventsHandle
}

/// One binding's bounded off-main root-resolution lane.
///
/// A filesystem call already running is allowed to finish, then its generation
/// is rejected by the binding. While it runs, repeated root changes overwrite
/// one pending request instead of adding an unbounded queue of obsolete symlink
/// walks.
private nonisolated final class RepositoryRootResolutionQueue: @unchecked Sendable {
    private struct Request: Sendable {
        let url: URL
        let generation: UInt64
    }

    private let queue: DispatchQueue
    private let resolve: @Sendable (URL) -> RepositoryRoot
    private let lock = NSLock()
    private var pending: Request?
    private var isScheduled = false
    private var delivery: (@Sendable (RepositoryRoot, UInt64) -> Void)?

    init(
        queue: DispatchQueue,
        resolve: @escaping @Sendable (URL) -> RepositoryRoot
    ) {
        self.queue = queue
        self.resolve = resolve
    }

    func setDelivery(_ delivery: @escaping @Sendable (RepositoryRoot, UInt64) -> Void) {
        lock.withLock { self.delivery = delivery }
    }

    func submit(_ url: URL, generation: UInt64) {
        let shouldSchedule = lock.withLock {
            pending = Request(url: url, generation: generation)
            guard !isScheduled else { return false }
            isScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        queue.async { [self] in drain() }
    }

    func cancelPending() {
        lock.withLock { pending = nil }
    }

    private func drain() {
        while true {
            let work: (Request, (@Sendable (RepositoryRoot, UInt64) -> Void)?)? = lock.withLock {
                guard let request = pending else {
                    isScheduled = false
                    return nil
                }
                pending = nil
                return (request, delivery)
            }
            guard let (request, delivery) = work else { return }
            delivery?(resolve(request.url), request.generation)
        }
    }
}

/// The app's one owner of repository observation: one ``RepositoryObserver``,
/// and one filesystem watch per physical root for as long as something is bound
/// to it.
///
/// Panes do not hold subscriptions directly. They hold a ``RepositoryBinding``,
/// which resolves the anchor's URL to a ``RepositoryRoot`` off the main actor,
/// fences that resolution and every later callback with a generation so a
/// pane that moved on never hears from where it was, and retains the root here
/// so the watch is attached once for the first binding and stopped for the last.
///
/// A watch callback carries a typed reason. Working-tree writes invalidate
/// status and the tree without discarding a known default branch; gitdir
/// metadata and dropped-event rescans relearn it. The observer's status
/// cadence and tree spacing bound what that costs. An explicit ``refresh(_:)``
/// is still immediate.
@MainActor
public final class RepositoryCenter {
    public let observer: RepositoryObserver

    private let attacher: (any RepositoryEventsAttaching)?
    private let retryDelay: TimeInterval
    let queue: DispatchQueue
    let rootResolver: @Sendable (URL) -> RepositoryRoot
    private var attachments: [String: Attachment] = [:]

    public init(
        observer: RepositoryObserver,
        events: (any RepositoryEventsAttaching)?,
        attachmentRetryDelay: TimeInterval = 0.25,
        queue: DispatchQueue = DispatchQueue(label: "pasqualotto.baia.repository-center", qos: .utility),
        rootResolver: @escaping @Sendable (URL) -> RepositoryRoot = { RepositoryRoot($0) }
    ) {
        self.observer = observer
        attacher = events
        retryDelay = max(0, attachmentRetryDelay)
        self.queue = queue
        self.rootResolver = rootResolver
    }

    /// The status cadence every root shares, from the Settings value.
    public var statusInterval: TimeInterval {
        get { observer.statusInterval }
        set { observer.statusInterval = newValue }
    }

    /// A pane's handle. Point it with ``RepositoryBinding/setRepositoryURL(_:)``.
    public func makeBinding() -> RepositoryBinding {
        RepositoryBinding(center: self)
    }

    /// Everything re-read now, default branch included, for an explicit command.
    public func refresh(_ root: RepositoryRoot) {
        observer.refresh(root)
    }

    // MARK: - Roots held by bindings

    /// The first binding on a root attaches its watch; every later one shares it.
    func retain(_ root: RepositoryRoot) {
        if let existing = attachments[root.identity] {
            existing.holders += 1
            return
        }
        let attachment = Attachment(root: root)
        attachments[root.identity] = attachment
        startAttachment(attachment)
    }

    /// The last binding to leave a root stops its watch. A watch still being
    /// attached is stopped as soon as it lands, by the generation it carries.
    func release(_ root: RepositoryRoot) {
        guard let attachment = attachments[root.identity] else { return }
        attachment.holders -= 1
        guard attachment.holders <= 0 else { return }
        attachments[root.identity] = nil
        attachment.invalidation?.cancel()
        attachment.invalidation = nil
        attachment.pendingReason = nil
        attachment.retry?.cancel()
        attachment.retry = nil
        attachment.handle?.stop()
        attachment.handle = nil
    }

    private func startAttachment(_ attachment: Attachment) {
        guard let attacher else { return }
        let generation = attachment.generation
        let identity = attachment.root.identity
        let url = attachment.root.url
        queue.async { [weak self] in
            let outcome: Result<any RepositoryEventsHandle, Error> = Result {
                try attacher.attach(root: url) { [weak self] _, reason in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.invalidated(
                                identity: identity,
                                generation: generation,
                                reason: reason
                            )
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishAttachment(identity: identity, generation: generation, outcome: outcome)
                }
            }
        }
    }

    private func finishAttachment(
        identity: String,
        generation: UInt64,
        outcome: Result<any RepositoryEventsHandle, Error>
    ) {
        guard let attachment = attachments[identity], attachment.generation == generation else {
            // Released while attaching: the watch nobody holds is stopped here,
            // and a failure for it is not retried.
            if case let .success(handle) = outcome { handle.stop() }
            return
        }
        switch outcome {
        case let .success(handle):
            attachment.handle = handle
        case .failure:
            // A watch that could not start leaves the root on its polling
            // backstop, which is still correct, and tries again while the root
            // is held. The failure is not surfaced: nothing about it changes
            // what the observer publishes.
            let item = DispatchWorkItem { [weak self, weak attachment] in
                MainActor.assumeIsolated {
                    guard let self, let attachment else { return }
                    attachment.retry = nil
                    guard self.attachments[identity] === attachment else { return }
                    self.startAttachment(attachment)
                }
            }
            attachment.retry = item
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: item)
        }
    }

    /// A watch reported a change under its root. Fenced by generation: a watch
    /// that was released and re-attached delivers only through its current
    /// generation, and a late callback from a stopped one reaches nothing.
    /// Repeated callbacks in the same turn merge into one pending reason
    /// (metadata wins) and do not push the already-due delivery later.
    private func invalidated(
        identity: String,
        generation: UInt64,
        reason: RepositoryInvalidation
    ) {
        guard let attachment = attachments[identity], attachment.generation == generation else { return }
        if attachment.pendingReason != nil {
            attachment.pendingReason = attachment.pendingReason?.merging(reason)
            return
        }
        attachment.pendingReason = reason
        let item = DispatchWorkItem { [weak self, weak attachment] in
            MainActor.assumeIsolated {
                guard let self, let attachment else { return }
                let reason = attachment.pendingReason ?? .workingTree
                attachment.pendingReason = nil
                attachment.invalidation = nil
                guard self.attachments[identity] === attachment,
                      attachment.generation == generation
                else { return }
                self.observer.invalidate(attachment.root, reason)
            }
        }
        attachment.invalidation = item
        DispatchQueue.main.async(execute: item)
    }

    @MainActor
    private final class Attachment {
        let root: RepositoryRoot
        let generation: UInt64
        var holders = 1
        var handle: (any RepositoryEventsHandle)?
        var invalidation: DispatchWorkItem?
        var pendingReason: RepositoryInvalidation?
        var retry: DispatchWorkItem?

        private static var nextGeneration: UInt64 = 0

        init(root: RepositoryRoot) {
            self.root = root
            Self.nextGeneration &+= 1
            generation = Self.nextGeneration
        }
    }
}

/// One pane's view of the repository its anchor names.
///
/// Where ``RepositorySubscription`` is the observer's identity for a subscriber,
/// this is the pane's: it outlives every root the pane visits. Pointing it at a
/// new URL clears the snapshot at once and publishes nil, so no surface keeps
/// the previous repository's answer past the switch; resolves the root off the
/// main actor; and subscribes only if no newer request has arrived meanwhile.
/// Every delivery is fenced the same way, so a completion for an earlier root
/// is dropped before any field is written.
///
/// `GitWorkspace` takes a URL here, never an anchor type: the caller decides
/// what counts as a repository and hands over the root or nil.
@MainActor
public final class RepositoryBinding {
    /// Fires on the main actor with every publication for the current root, and
    /// with nil at the moment the root changes or is cleared.
    public var onChange: ((RepositorySnapshot?) -> Void)?

    /// The latest publication for the current root, or nil.
    public private(set) var snapshot: RepositorySnapshot?

    /// The resolved current root, or nil before resolution and outside a
    /// repository.
    public private(set) var root: RepositoryRoot?

    /// Whether the pane's window wants reads now. Follows the window's key state
    /// and applies to whichever root the binding is on, including one still
    /// being resolved.
    public var isActive = true {
        didSet {
            guard isActive != oldValue else { return }
            subscription?.isActive = isActive
        }
    }

    private weak var center: RepositoryCenter?
    private var subscription: RepositorySubscription?
    private var retained: RepositoryRoot?
    private var requestedPath: String?
    private var generation: UInt64 = 0
    private let resolver: RepositoryRootResolutionQueue
    private let release: @Sendable () -> Void

    init(center: RepositoryCenter) {
        self.center = center
        resolver = RepositoryRootResolutionQueue(queue: center.queue, resolve: center.rootResolver)
        let box = ReleaseBox()
        self.releaseBox = box
        release = {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { box.release?() }
            }
        }
        resolver.setDelivery { [weak self] resolved, generation in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.resolved(resolved, generation: generation)
                }
            }
        }
    }

    private let releaseBox: ReleaseBox

    /// Holds the main-actor release closure so a nonisolated `deinit` can
    /// schedule it without touching isolated state.
    @MainActor
    private final class ReleaseBox {
        var release: (() -> Void)?
    }

    /// Buffers `observe`'s synchronous cached delivery until the binding owns
    /// the returned subscription and both corresponding release operations.
    @MainActor
    private final class SubscriptionInstallation {
        var isInstalling = true
        var bufferedDelivery: RepositorySnapshot??
    }

    deinit {
        resolver.cancelPending()
        release()
    }

    /// Points the binding at the repository rooted at `url`, or at nothing.
    ///
    /// Returns without work when the URL is the one already requested, which
    /// is what the once-a-second anchor poll relies on. Otherwise the previous
    /// root is released and the snapshot cleared before anything else happens.
    public func setRepositoryURL(_ url: URL?) {
        let path = url?.path(percentEncoded: false)
        guard path != requestedPath else { return }
        requestedPath = path
        generation &+= 1
        let requestedGeneration = generation
        resolver.cancelPending()
        detach()
        snapshot = nil
        root = nil
        onChange?(nil)

        guard requestedGeneration == generation, let url, center != nil else { return }
        // Symlink resolution touches the filesystem, so the bounded resolver
        // runs it away from the actor that draws. Rapid changes retain only the
        // newest pending request.
        resolver.submit(url, generation: requestedGeneration)
    }

    /// Releases the root and stops delivering. The binding can be pointed again.
    public func releaseRoot() {
        setRepositoryURL(nil)
    }

    /// Requests fresh status and tree reads for the root this pane currently
    /// owns. False is an explicit refusal while resolution is pending or the
    /// pane is outside a repository.
    @discardableResult
    public func refresh() -> Bool {
        guard let root, let center else { return false }
        center.refresh(root)
        return true
    }

    private func resolved(_ resolved: RepositoryRoot, generation: UInt64) {
        guard generation == self.generation, let center else { return }
        root = resolved
        retained = resolved
        center.retain(resolved)
        let installation = SubscriptionInstallation()
        let subscription = center.observer.observe(resolved, active: isActive) { [weak self] delivered in
            if installation.isInstalling {
                installation.bufferedDelivery = .some(delivered)
            } else {
                self?.deliver(delivered, generation: generation)
            }
        }
        self.subscription = subscription
        // The deinitializer cannot call this main-actor method itself. Keep the
        // two owned releases in a box that survives the binding long enough to
        // run them on the main actor, without weakly reaching back to an object
        // that has already finished deinitializing.
        releaseBox.release = { [weak center, subscription] in
            subscription.cancel()
            center?.release(resolved)
        }
        installation.isInstalling = false
        let initialDelivery = installation.bufferedDelivery
        installation.bufferedDelivery = nil
        if let initialDelivery {
            deliver(initialDelivery, generation: generation)
        }
    }

    private func deliver(_ delivered: RepositorySnapshot?, generation: UInt64) {
        guard generation == self.generation else { return }
        // The immediate nil for a root nothing has read yet was already
        // published by `setRepositoryURL`; a second one would redraw for
        // nothing.
        guard delivered != nil || snapshot != nil else { return }
        snapshot = delivered
        onChange?(delivered)
    }

    private func detach() {
        subscription?.cancel()
        subscription = nil
        if let retained, let center {
            center.release(retained)
        }
        retained = nil
        releaseBox.release = nil
    }
}
