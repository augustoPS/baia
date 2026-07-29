import Foundation

/// The workspace's observable transitions, bounded, with the audience for each
/// one recorded when it happened.
///
/// **One buffer, not a queue per subscriber.** The mailbox is addressed
/// communication between two panes and keeps its own shape. This is observation:
/// many readers, each holding a cursor, none of them consuming.
///
/// **No drop counter.** A subscriber whose cursor falls off the back detects it
/// by sequence arithmetic, which is the honest version of what ``Mailbox`` does
/// with a count: a mailbox has to be told what it lost, and a ring reader can
/// see it.
public struct EventRing: Sendable, Equatable {
    /// One entry, and the set of panes that were entitled to see it.
    ///
    /// The audience is stored rather than recomputed because the most important
    /// event is `paneClosed`, and by the time anybody reads one of those the graph
    /// has forgotten the parentage that would have authorised it. See
    /// ``PaneGraph/emit(_:pane:createdBy:message:activity:)``.
    struct Entry: Sendable, Equatable {
        var event: ControlEvent
        var audience: Set<ControlPaneID>

        /// Every pane entitled to learn the id in ``ControlEvent/createdBy``, or
        /// empty when there is no creator to name.
        ///
        /// A second audience because the two are different questions. The
        /// audience above is who may hear that something happened to the subject;
        /// this is who may be told the identity of a pane one step up the tree,
        /// which is a fact about the creator and not about the subject. The
        /// subject itself is in the first set and, unless the two peer, in
        /// neither the second: a pane learns who it created, never who created
        /// it, and ``PaneRecord/redacted(toVisible:)`` already drops the field on
        /// `list` and `whoami` for the same reader.
        var creatorAudience: Set<ControlPaneID>

        /// This entry as one reader is allowed to read it.
        ///
        /// Redaction is omission, matching ``PaneRecord/redacted(toVisible:)``: a
        /// withheld creator prints no line rather than a line saying a creator
        /// was withheld, which would itself confirm one exists.
        func visible(to reader: ControlPaneID) -> ControlEvent {
            guard event.createdBy != nil, creatorAudience.contains(reader) == false else {
                return event
            }
            var redacted = event
            redacted.createdBy = nil
            return redacted
        }
    }

    /// Oldest first.
    private(set) var entries: [Entry] = []

    /// The highest sequence appended, or 0 when nothing has been. Never rewinds,
    /// including across eviction.
    public private(set) var lastSequence: UInt64 = 0

    public init() {}

    var count: Int { entries.count }

    /// The oldest sequence still held, or nil when the ring is empty.
    var oldestSequence: UInt64? { entries.first?.event.seq }

    /// Appends, dropping from the front at the cap, and answers the sequence it
    /// minted.
    ///
    /// Strings are capped here rather than at the reader, so the ring cannot hold
    /// a byte the wire cannot carry.
    ///
    /// `createdBy` arrives as the pane **and** the panes entitled to be told
    /// about it, in one argument, so there is no way to record a creator without
    /// recording who may read it. Two parameters would let a caller supply the id
    /// and leave the audience empty or, worse, default it to the subject's, which
    /// is the disclosure this pair exists to close.
    @discardableResult
    mutating func append(
        kind: ControlEventKind,
        pane: ControlPaneID,
        audience: Set<ControlPaneID>,
        createdBy: (pane: ControlPaneID, audience: Set<ControlPaneID>)?,
        message: String?,
        activity: String?,
        source: ControlEventSource?
    ) -> UInt64 {
        lastSequence += 1

        let event = ControlEvent(
            seq: lastSequence,
            kind: kind,
            pane: pane.description,
            createdBy: createdBy?.pane.description,
            message: ControlEvent.capped(message),
            activity: ControlEvent.capped(activity),
            source: source
        )

        entries.append(
            Entry(
                event: event,
                audience: audience,
                creatorAudience: createdBy?.audience ?? []
            )
        )
        while entries.count > ControlWire.maxRingEvents {
            entries.removeFirst()
        }
        return lastSequence
    }
}

/// What one `subscribe` answered.
public struct EventBatch: Sendable, Equatable {
    /// Oldest first, at most ``ControlWire/maxEventBatch`` of them, and only
    /// those whose audience included the reader.
    public var events: [ControlEvent]

    /// Visible events remain past this batch. It means "poll again", never "some
    /// are gone", which is what ``gap`` is for.
    public var more: Bool

    /// The ring evicted events before the requested cursor.
    public var gap: Bool

    /// The cursor for the next call.
    public var seq: UInt64

    /// The answer for a reader with nothing waiting, and the answer a parked
    /// `subscribe` is resolved with when its pane closes, when the channel is
    /// switched off, and at terminate. A client never sees a bare EOF from a
    /// wait, matching ``Drain/empty``.
    public static func empty(at seq: UInt64) -> EventBatch {
        EventBatch(events: [], more: false, gap: false, seq: seq)
    }
}

extension EventRing {
    /// Everything after `cursor` that this pane may see, as much of it as fits.
    ///
    /// **An event is delivered only once it has been framed into a response that
    /// fits**, which is ``PaneGraph/drain(pane:limit:budget:)``'s rule restated
    /// for a buffer nobody consumes. Truncation is answered with `more: true` and
    /// a cursor at the last delivered event, so the next call resumes exactly
    /// where this one stopped.
    ///
    /// **The cursor advances past what was filtered out.** An event the reader
    /// could not see, or did not ask for by kind, still moves the cursor, so a
    /// narrow subscriber does not re-examine the whole ring on every poll. That is
    /// why `--kinds` is delivery and never authority: it changes what is in
    /// `events` and nothing about where the reader is.
    ///
    /// **Fields are redacted here and not at the emit**, because one entry serves
    /// an audience whose members are not entitled to the same things: an event's
    /// `createdBy` names a pane one step above the subject, which the subject's
    /// own ancestors may read and the subject and its peers may not. Deciding it
    /// at the emit would mean one entry per entitlement, which is a queue per
    /// subscriber under another name.
    func events(
        after cursor: UInt64,
        for pane: ControlPaneID,
        kinds: Set<ControlEventKind>,
        limit: Int,
        budget: Int
    ) -> EventBatch {
        // A gap is eviction past the cursor, measured against the whole ring.
        // `oldest - 1` is the boundary: a reader at exactly that point missed
        // nothing.
        //
        // The comparison is written downward from the oldest sequence rather than
        // upward from the cursor. The cursor arrives off the wire and may be any
        // UInt64, so `cursor + 1` would trap on `UInt64.max` and take the app down
        // with every pane in it, while `oldest - 1` cannot underflow: sequences
        // start at 1.
        let gap = oldestSequence.map { $0 - 1 > cursor } ?? false

        var delivered: [ControlEvent] = []
        // Starts at the head, so a read that examines everything ends there even
        // when it delivers nothing, and a cursor above the head is walked back
        // rather than left in the future.
        var next = lastSequence
        var truncated = false

        for entry in entries where entry.event.seq > cursor {
            guard entry.audience.contains(pane), kinds.contains(entry.event.kind) else {
                continue
            }
            guard delivered.count < limit else {
                truncated = true
                break
            }
            // Redacted before it is measured, so the budget is spent on the line
            // this reader is sent. Redaction only ever removes bytes, so
            // measuring the other way would be conservative rather than wrong,
            // but it would also make the two numbers disagree for no reason.
            let candidate = delivered + [entry.visible(to: pane)]
            guard ControlWire.eventBatchFrameSize(events: candidate) <= budget else {
                truncated = true
                break
            }
            delivered = candidate
        }

        if truncated {
            // The last one actually delivered, never the head: everything past it
            // is still owed. `delivered` cannot be empty here, because a single
            // event always frames alone once its strings were capped at emit, and
            // `aMaximalEventFramesOnItsOwn` holds that.
            next = delivered.last?.seq ?? cursor
        }

        return EventBatch(events: delivered, more: truncated, gap: gap, seq: next)
    }
}
