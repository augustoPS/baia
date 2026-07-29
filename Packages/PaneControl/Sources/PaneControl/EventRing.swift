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
    @discardableResult
    mutating func append(
        kind: ControlEventKind,
        pane: ControlPaneID,
        audience: Set<ControlPaneID>,
        createdBy: ControlPaneID?,
        message: String?,
        activity: String?
    ) -> UInt64 {
        lastSequence += 1

        let event = ControlEvent(
            seq: lastSequence,
            kind: kind,
            pane: pane.description,
            createdBy: createdBy?.description,
            message: ControlEvent.capped(message),
            activity: ControlEvent.capped(activity)
        )

        entries.append(Entry(event: event, audience: audience))
        while entries.count > ControlWire.maxRingEvents {
            entries.removeFirst()
        }
        return lastSequence
    }
}
