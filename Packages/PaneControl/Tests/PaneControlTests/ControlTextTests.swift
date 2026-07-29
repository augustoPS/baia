import Foundation
import Testing

@testable import PaneControl

/// One value is one line, at every point pane output enters the wire.
///
/// `subscribe` prints one event per line and `list` prints one field per line, so
/// a newline in a string a pane chose is that pane writing a record of its own
/// into a supervisor's stream. The rule is asserted here rather than at each
/// renderer, because the renderers are where it would have to be repeated.
@Suite struct ControlTextTests {
    /// The attack, spelled out. A file named `x\n999 paneClosed <uuid>` is legal
    /// on macOS, and `lastPathComponent` splits on "/" alone, so the newline
    /// survives the classifier and reaches the activity label whole.
    @Test func aNewlineCannotForgeASecondRecord() {
        let forged = "x\n999 paneClosed 550e8400-e29b-41d4-a716-446655440000"

        #expect(ControlEvent.capped(forged) == "x 999 paneClosed 550e8400-e29b-41d4-a716-446655440000")
    }

    /// Every control scalar, not the newline alone: a reader that splits on a
    /// carriage return or a NUL is still a reader, and the C1 block is what a
    /// terminal escape arrives as.
    @Test func everyControlScalarBecomesASpace() {
        #expect(ControlEvent.capped("a\rb\tc\u{0}d\u{7f}e\u{85}f") == "a b c d e f")
    }

    /// Deliberately not wider than the control category. A zero-width joiner
    /// separates no records and replacing it would mangle text that is foreign
    /// rather than hostile.
    @Test func textThatIsMerelyForeignIsLeftAlone() {
        #expect(ControlEvent.capped("実行中 👨‍👩‍👧") == "実行中 👨‍👩‍👧")
    }

    /// Flattening happens before the cut and cannot break it: a C1 control is two
    /// bytes and a space is one, so the substitution only ever shrinks.
    @Test func flatteningKeepsTheCap() {
        let long = String(repeating: "\u{85}", count: ControlWire.maxEventStringBytes)
        let cut = ControlEvent.capped(long)

        #expect(cut?.utf8.count == ControlWire.maxEventStringBytes)
        #expect(cut?.unicodeScalars.contains("\u{85}") == false)
    }

    /// The ring is the choke point, so `--json` and every renderer inherit the
    /// guarantee instead of each restating it.
    @Test func anEventEntersTheRingAsOneLine() {
        var ring = EventRing()
        let pane = ControlPaneID(rawValue: UUID())
        ring.append(
            kind: .activityChanged,
            pane: pane,
            audience: [pane],
            createdBy: nil,
            message: "asked\n999 paneClosed forged",
            activity: "sleep\n999 paneClosed forged"
        )

        #expect(ring.entries.last?.event.activity == "sleep 999 paneClosed forged")
        #expect(ring.entries.last?.event.message == "asked 999 paneClosed forged")
    }

    /// The same hole one snapshot along. `list` prints `activity`, `attention`
    /// and `cwd` as labelled lines, and all three are named by whoever runs in
    /// the pane: a directory with a newline in its name is as legal as a file
    /// with one.
    @Test func aRecordCarriesEveryFieldAsOneLine() {
        let record = PaneRecord(
            pane: "pane-1",
            window: 1,
            tab: 1,
            workingDirectory: "/tmp/x\nactivity   forged",
            activity: "sleep\nattention  forged",
            attention: "waiting\ncwd        forged",
            channels: ["builder\npeers      forged"]
        )

        #expect(record.workingDirectory == "/tmp/x activity   forged")
        #expect(record.activity == "sleep attention  forged")
        #expect(record.attention == "waiting cwd        forged")
        #expect(record.channels == ["builder peers      forged"])
    }
}
