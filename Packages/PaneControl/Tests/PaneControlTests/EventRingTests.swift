import Foundation
import Testing

@testable import PaneControl

/// The ring's mechanics: one sequence, one buffer, and a read that filters by
/// audience without consulting the live graph.
@Suite struct EventRingTests {
    /// The wire spelling is the protocol. A rename is a break, so it is asserted
    /// against a literal table rather than against the case names.
    @Test func kindsSpellThemselvesOnTheWire() {
        #expect(ControlEventKind.paneOpened.rawValue == "paneOpened")
        #expect(ControlEventKind.paneClosed.rawValue == "paneClosed")
        #expect(ControlEventKind.attentionRaised.rawValue == "attentionRaised")
        #expect(ControlEventKind.attentionCleared.rawValue == "attentionCleared")
        #expect(ControlEventKind.activityChanged.rawValue == "activityChanged")
        #expect(ControlEventKind.allCases.count == 5)
    }

    /// Truncation happens where the string enters the ring, so the ring cannot
    /// hold a byte the wire cannot carry.
    @Test func aLongStringIsCutToTheCap() {
        let long = String(repeating: "a", count: ControlWire.maxEventStringBytes + 100)
        let cut = ControlEvent.capped(long)
        #expect(cut?.utf8.count == ControlWire.maxEventStringBytes)
    }

    /// A cut through a multi-byte scalar would produce a string no JSON encoder
    /// can emit, so the truncation stops short of the boundary instead.
    @Test func aCutLandsOnAScalarBoundary() {
        // 512 is the cap. 170 three-byte scalars is 510 bytes, and one more would
        // cross it, so the answer is 510 rather than 512.
        let long = String(repeating: "\u{4E00}", count: 200)
        let cut = ControlEvent.capped(long)
        #expect(cut?.utf8.count == 510)
        #expect(cut?.count == 170)
    }

    @Test func nilStaysNil() {
        #expect(ControlEvent.capped(nil) == nil)
    }

    /// Two panes with no relationship, so an audience is whatever the test passes
    /// rather than whatever a graph computed.
    struct Ring {
        var ring = EventRing()
        let one = ControlPaneID(rawValue: UUID())
        let two = ControlPaneID(rawValue: UUID())

        @discardableResult
        mutating func append(_ kind: ControlEventKind, for pane: ControlPaneID) -> UInt64 {
            ring.append(
                kind: kind,
                pane: pane,
                audience: [pane],
                createdBy: nil,
                message: nil,
                activity: nil
            )
        }
    }

    @Test func theSequenceStartsAtOneAndNeverRepeats() {
        var fixture = Ring()
        #expect(fixture.append(.paneOpened, for: fixture.one) == 1)
        #expect(fixture.append(.paneClosed, for: fixture.one) == 2)
        #expect(fixture.append(.paneOpened, for: fixture.two) == 3)
        #expect(fixture.ring.lastSequence == 3)
    }

    /// The oldest goes and the sequence does not rewind, which is what lets a
    /// subscriber see the loss without being told about it.
    @Test func theOldestIsEvictedAtTheCap() {
        var fixture = Ring()
        for _ in 0..<(ControlWire.maxRingEvents + 10) {
            fixture.append(.attentionRaised, for: fixture.one)
        }
        #expect(fixture.ring.count == ControlWire.maxRingEvents)
        #expect(fixture.ring.lastSequence == UInt64(ControlWire.maxRingEvents + 10))
        #expect(fixture.ring.oldestSequence == 11)
    }

    @Test func anEmptyRingHasNoSequence() {
        let ring = EventRing()
        #expect(ring.lastSequence == 0)
        #expect(ring.oldestSequence == nil)
        #expect(ring.count == 0)
    }

    /// Strings are capped on the way in, so nothing downstream has to remember.
    @Test func aMessageIsCappedWhenItIsAppended() {
        var fixture = Ring()
        let long = String(repeating: "b", count: 5000)
        fixture.ring.append(
            kind: .attentionRaised,
            pane: fixture.one,
            audience: [fixture.one],
            createdBy: nil,
            message: long,
            activity: nil
        )
        let stored = fixture.ring.entries.last?.event.message
        #expect(stored?.utf8.count == ControlWire.maxEventStringBytes)
    }

    /// Everything, for a reader that wants no kind filter.
    static let allKinds = Set(ControlEventKind.allCases)

    /// One entry, two entitlements. Both readers are in the audience, only one is
    /// in the creator's, and the ring answers each of them accordingly rather
    /// than storing the entry twice.
    @Test func theCreatorIsNamedOnlyToItsOwnAudience() {
        var fixture = Ring()
        let creator = ControlPaneID(rawValue: UUID())
        fixture.ring.append(
            kind: .paneOpened,
            pane: fixture.one,
            audience: [fixture.one, fixture.two, creator],
            createdBy: (pane: creator, audience: [creator]),
            message: nil,
            activity: nil
        )

        let entitled = fixture.ring.events(
            after: 0, for: creator, kinds: Self.allKinds,
            limit: ControlWire.maxEventBatch, budget: ControlWire.maxFrameBytes
        )
        #expect(entitled.events.first?.createdBy == creator.description)

        for reader in [fixture.one, fixture.two] {
            let batch = fixture.ring.events(
                after: 0, for: reader, kinds: Self.allKinds,
                limit: ControlWire.maxEventBatch, budget: ControlWire.maxFrameBytes
            )
            #expect(batch.events.count == 1, "the entry itself is still delivered")
            #expect(batch.events.first?.createdBy == nil)
        }
    }

    @Test func aReaderSeesOnlyWhatItsAudienceIncludes() {
        var fixture = Ring()
        fixture.ring.append(
            kind: .paneOpened, pane: fixture.one, audience: [fixture.one],
            createdBy: nil, message: nil, activity: nil
        )
        fixture.ring.append(
            kind: .paneOpened, pane: fixture.two, audience: [fixture.two],
            createdBy: nil, message: nil, activity: nil
        )

        let mine = fixture.ring.events(
            after: 0, for: fixture.one, kinds: Self.allKinds,
            limit: ControlWire.maxEventBatch, budget: ControlWire.maxFrameBytes
        )
        #expect(mine.events.map(\.seq) == [1])
        #expect(mine.more == false)
        #expect(mine.gap == false)
        // The cursor advances past the event it could not see, so the next call
        // does not re-examine it.
        #expect(mine.seq == 2)
    }

    @Test func kindsNarrowDeliveryAndNotTheCursor() {
        var fixture = Ring()
        fixture.append(.paneOpened, for: fixture.one)
        fixture.append(.activityChanged, for: fixture.one)
        fixture.append(.paneClosed, for: fixture.one)

        let batch = fixture.ring.events(
            after: 0, for: fixture.one, kinds: [.paneClosed],
            limit: ControlWire.maxEventBatch, budget: ControlWire.maxFrameBytes
        )
        #expect(batch.events.map(\.kind) == [.paneClosed])
        #expect(batch.seq == 3)
        #expect(batch.more == false)
    }

    /// `from == oldest - 1` is the boundary: nothing was missed. One below it and
    /// something was.
    @Test func theGapBoundaryIsExact() {
        var fixture = Ring()
        for _ in 0..<(ControlWire.maxRingEvents + 5) {
            fixture.append(.attentionRaised, for: fixture.one)
        }
        let oldest = fixture.ring.oldestSequence!
        #expect(oldest == 6)

        let clean = fixture.ring.events(
            after: oldest - 1, for: fixture.one, kinds: Self.allKinds,
            limit: ControlWire.maxEventBatch, budget: ControlWire.maxFrameBytes
        )
        #expect(clean.gap == false)

        let lost = fixture.ring.events(
            after: oldest - 2, for: fixture.one, kinds: Self.allKinds,
            limit: ControlWire.maxEventBatch, budget: ControlWire.maxFrameBytes
        )
        #expect(lost.gap == true)
    }

    @Test func anEmptyRingReportsNoGap() {
        let ring = EventRing()
        let batch = ring.events(
            after: 0, for: ControlPaneID(rawValue: UUID()), kinds: Self.allKinds,
            limit: ControlWire.maxEventBatch, budget: ControlWire.maxFrameBytes
        )
        #expect(batch.gap == false)
        #expect(batch.events.isEmpty)
        #expect(batch.seq == 0)
    }

    /// A cursor past the head is walked back rather than treated as an error, so
    /// a client that lost track re-syncs on its next call instead of wedging.
    @Test func aCursorAboveTheHeadIsWalkedBack() {
        var fixture = Ring()
        fixture.append(.paneOpened, for: fixture.one)

        let batch = fixture.ring.events(
            after: 99, for: fixture.one, kinds: Self.allKinds,
            limit: ControlWire.maxEventBatch, budget: ControlWire.maxFrameBytes
        )
        #expect(batch.events.isEmpty)
        #expect(batch.seq == 1)
    }

    /// The far end of the same walk-back, and the reason the gap boundary is
    /// measured downward from the oldest sequence: `cursor + 1` on the highest
    /// cursor a client can send would trap and take the app with it.
    @Test func theHighestCursorIsWalkedBackRatherThanOverflowing() {
        var fixture = Ring()
        fixture.append(.paneOpened, for: fixture.one)

        let batch = fixture.ring.events(
            after: .max, for: fixture.one, kinds: Self.allKinds,
            limit: ControlWire.maxEventBatch, budget: ControlWire.maxFrameBytes
        )
        #expect(batch.events.isEmpty)
        #expect(batch.gap == false)
        #expect(batch.more == false)
        #expect(batch.seq == fixture.ring.lastSequence)
    }

    @Test func theBatchCapStopsAtThirtyTwoAndSaysMore() {
        var fixture = Ring()
        for _ in 0..<40 {
            fixture.append(.attentionRaised, for: fixture.one)
        }
        let batch = fixture.ring.events(
            after: 0, for: fixture.one, kinds: Self.allKinds,
            limit: ControlWire.maxEventBatch, budget: ControlWire.maxFrameBytes
        )
        #expect(batch.events.count == ControlWire.maxEventBatch)
        #expect(batch.more == true)
        #expect(batch.seq == 32)
    }

    /// The frame rule from the other side: a budget that fits two events answers
    /// with two and leaves the rest, rather than promising a line no reader will
    /// accept.
    @Test func aTightBudgetTruncatesAndSaysMore() {
        var fixture = Ring()
        for _ in 0..<5 {
            fixture.append(.attentionRaised, for: fixture.one)
        }
        let twoFit = ControlWire.eventBatchFrameSize(
            events: Array(fixture.ring.entries.prefix(2).map(\.event))
        )
        let batch = fixture.ring.events(
            after: 0, for: fixture.one, kinds: Self.allKinds,
            limit: ControlWire.maxEventBatch, budget: twoFit
        )
        #expect(batch.events.count == 2)
        #expect(batch.more == true)
        #expect(batch.seq == 2)
    }

    /// The reason a truncating read can never wedge: one maximal event always
    /// fits alone, because every string was capped on the way in.
    @Test func aMaximalEventFramesOnItsOwn() {
        let filler = String(repeating: "z", count: ControlWire.maxEventStringBytes)
        let event = ControlEvent(
            seq: .max,
            kind: .attentionRaised,
            pane: UUID().uuidString,
            createdBy: UUID().uuidString,
            message: filler,
            activity: filler
        )
        #expect(ControlWire.eventBatchFrameSize(events: [event]) <= ControlWire.maxFrameBytes)
    }
}
