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
}
