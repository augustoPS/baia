import Foundation

/// Which long poll a parked connection is holding.
///
/// The table stays one table, so "one long poll per connection" covers both sorts
/// without a second quota, a second sweep, or a second eviction rule to keep in
/// step with the first.
public enum ParkedKind: Sendable, Equatable {
    case recv

    /// The cursor and the filter the waiter arrived with, so a wake-up can tell
    /// whether this subscriber has anything to be woken for without going back to
    /// the frame that parked it.
    case subscribe(from: UInt64, kinds: Set<ControlEventKind>)
}

/// The parked long poll per connection, of either sort, and the rule that there
/// is at most one.
///
/// **A connection holds one long poll, and a second one is answered rather than
/// swallowed.** NDJSON is a pipelinable wire, deliberately so: the spec keeps the
/// channel `nc`-drivable, which means two `recv --wait` frames can sit on one
/// connection before either has been answered. A table that let the second
/// overwrite the first would leave the first request with no response at all and
/// its deadline still armed, to fire later against a waiter that is not the one
/// it was made for. Spec rule 5 allows exactly one request with no response, an
/// over-cap line that arrives before its newline, and this is not it.
///
/// Pure, and apart from the server, because the rule is a property of the table
/// and not of the socket. It is decidable without a descriptor, so it is decided
/// where `make test` can see it rather than where only a live app can.
///
/// The deadline is a generic parameter so this package keeps its Foundation-only
/// import: the server parks a `DispatchWorkItem`, a test parks whatever it likes,
/// and neither is this type's business. Cancelling one is the caller's job, which
/// is why every removal hands the waiter back instead of dropping it.
struct ParkedRecvs<Deadline> {
    /// A `recv` that found nothing and asked to wait.
    ///
    /// The token is held for the length of the wait, and holding it is the lesser
    /// of two evils. The alternative is a public drain that takes a pane instead
    /// of a token, which is a door into a mailbox that skips `authorize`, and
    /// ``PaneGraph`` refuses to have one for exactly this reason. The token sits
    /// in the same process as the registry that already holds it, is never
    /// encoded, never logged, and goes when the waiter resolves.
    public struct Waiter {
        public let pane: ControlPaneID
        public let token: String
        public let deadline: Deadline

        /// Which sort of long poll this is, and everything resolving it needs.
        ///
        /// **No default value**, so every call site says which sort it is parking.
        /// A defaulted `.recv` would let each existing caller compile untouched,
        /// which is the defect ``PaneGraph/open(pane:createdBy:secret:)``'s
        /// `createdBy` note records: the one site that should say `.subscribe`
        /// would quietly say `.recv`, and its waiter would then be resolved by
        /// draining a mailbox it never asked about.
        public let kind: ParkedKind

        public init(
            pane: ControlPaneID,
            token: String,
            deadline: Deadline,
            kind: ParkedKind
        ) {
            self.pane = pane
            self.token = token
            self.deadline = deadline
            self.kind = kind
        }
    }

    /// What ``park(_:_:)`` did with the waiter it was handed.
    ///
    /// A returned outcome rather than a silent overwrite, because the caller owes
    /// the incoming request a frame either way and the only way to make that
    /// impossible to forget is to make it impossible to ignore the answer.
    public enum ParkOutcome: Equatable {
        case parked

        /// This connection was already waiting, so nothing was installed and the
        /// incumbent is untouched. The caller answers the newcomer.
        case alreadyParked
    }

    private var waiters: [Int: Waiter] = [:]

    public init() {}

    public var isEmpty: Bool { waiters.isEmpty }

    /// Every parked connection, oldest first.
    ///
    /// An array and not the dictionary's keys, because every caller is about to
    /// resolve waiters while walking them, and a live key view of a dictionary
    /// being mutated is the shape of that bug.
    public var ids: [Int] { waiters.keys.sorted() }

    public func isParked(_ id: Int) -> Bool { waiters[id] != nil }

    public subscript(id: Int) -> Waiter? { waiters[id] }

    /// Installs a waiter, or reports that the connection already had one.
    ///
    /// **Refuses rather than displaces.** Displacing would answer the incumbent
    /// and leave the newcomer parked, which is defensible until you notice that
    /// answering an incumbent closes its connection, and its connection is the
    /// newcomer's connection too.
    public mutating func park(_ id: Int, _ waiter: Waiter) -> ParkOutcome {
        guard waiters[id] == nil else { return .alreadyParked }
        waiters[id] = waiter
        return .parked
    }

    /// Takes a waiter out and hands it back, so its deadline can be cancelled.
    @discardableResult
    public mutating func remove(_ id: Int) -> Waiter? {
        waiters.removeValue(forKey: id)
    }

    /// Every connection parked on one pane, oldest first.
    public func ids(of pane: ControlPaneID) -> [Int] {
        waiters.filter { $0.value.pane == pane }.keys.sorted()
    }

    /// The oldest parked connection, optionally restricted to one pane.
    ///
    /// Oldest by connection id, which is minted in accept order and never reused
    /// within a run, so it orders arrivals without a second timestamp to keep
    /// truthful.
    public func oldest(of pane: ControlPaneID?) -> Int? {
        waiters.filter { pane == nil || $0.value.pane == pane }.keys.min()
    }
}
