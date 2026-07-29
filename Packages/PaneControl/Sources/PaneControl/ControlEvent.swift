import Foundation

/// A transition somewhere in the workspace, as a subscriber reads it.
///
/// Five kinds and no sixth without a decision: the enum is `CaseIterable` and
/// `--kinds` validates against it, so a kind added here is subscribable the
/// moment it exists and a kind spelled wrong is refused rather than ignored.
public enum ControlEventKind: String, Sendable, Hashable, Codable, CaseIterable {
    case paneOpened
    case paneClosed
    case attentionRaised
    case attentionCleared
    case activityChanged
}

/// One entry as it crosses the wire.
///
/// Display ids and human-readable strings, exactly like ``PaneRecord``. Nothing
/// here can carry a capability: the ring is filled by the app with panes it
/// already knows, and no field is ever populated from a token.
public struct ControlEvent: Sendable, Equatable, Codable {
    /// Monotonic within a run, never reused. A subscriber detects loss by
    /// arithmetic on this rather than by being told a drop count.
    public var seq: UInt64

    public var kind: ControlEventKind

    /// The display id of the pane the event is about.
    public var pane: String

    /// `paneOpened` only: the display id of the pane that created it, when one
    /// did. Absent for a pane the owner opened by hand.
    public var createdBy: String?

    /// `attentionRaised` only: what the pane asked for, when it said so through
    /// OSC 9 or OSC 777. Capped at ``ControlWire/maxEventStringBytes``.
    public var message: String?

    /// `activityChanged` only: what the pane is doing, in the words the pane
    /// header shows. Nil is a pane running nothing, which is the same thing
    /// ``PaneRecord/activity`` means by nil.
    public var activity: String?

    public init(
        seq: UInt64,
        kind: ControlEventKind,
        pane: String,
        createdBy: String? = nil,
        message: String? = nil,
        activity: String? = nil
    ) {
        self.seq = seq
        self.kind = kind
        self.pane = pane
        self.createdBy = createdBy
        self.message = message
        self.activity = activity
    }

    /// Cuts a string to the cap, on a scalar boundary, at the moment it enters
    /// the ring.
    ///
    /// **At emit and not at read.** The ring must not be able to hold a byte the
    /// wire cannot carry: a payload accepted here that no response could frame
    /// would sit in the ring forever, and every read that reached it would answer
    /// the same truncated batch and never advance, which is the mailbox's
    /// undrainable-message defect in a buffer nobody can drain by hand.
    ///
    /// **The boundary rule is load-bearing, not tidiness.** `String` is UTF-8
    /// underneath and a cut through a multi-byte scalar yields bytes no JSON
    /// encoder will emit, so a naive truncation would be the very thing that made
    /// a response unframeable. Dropping whole characters until the budget holds
    /// can only come in under the cap, never over.
    static func capped(_ text: String?) -> String? {
        guard let text else { return nil }
        guard text.utf8.count > ControlWire.maxEventStringBytes else { return text }

        var cut = ""
        var used = 0
        for character in text {
            let width = String(character).utf8.count
            guard used + width <= ControlWire.maxEventStringBytes else { break }
            cut.append(character)
            used += width
        }
        return cut
    }
}
