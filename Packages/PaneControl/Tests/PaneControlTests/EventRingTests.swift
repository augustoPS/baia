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
}
