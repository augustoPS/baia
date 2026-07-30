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

    /// Turns a `--kinds` list off the wire into the set to deliver.
    ///
    /// **Here rather than in the server, because it is decidable without a
    /// descriptor.** The server's own doc comment calls this check "the rule",
    /// being the one a frame arriving without the CLI still meets, and a rule
    /// that only exists where `make test` cannot reach it is a rule nobody has
    /// checked. Same move the CLI's pure half made into `Packages/PaneCLI`.
    ///
    /// Three answers, and the middle one is the one that was missing:
    ///
    /// - **nil** is "I did not ask", which is every kind. The wire omits nil
    ///   fields, so this is distinguishable from the next case rather than
    ///   collapsed into it.
    /// - **empty** is "I asked for nothing", which is refused. A subscription
    ///   that can never deliver is a connection parked for sixty seconds against
    ///   a question with no answer, and the caller will read the silence as the
    ///   workspace being idle.
    /// - **named** resolves, refusing the whole list by name at the first kind it
    ///   does not know rather than dropping it, since a silently dropped
    ///   misspelling is a filter that looks like it works and delivers nothing.
    public static func resolve(_ names: [String]?) -> ControlOutcome<Set<ControlEventKind>> {
        guard let names else { return .ok(Set(allCases)) }
        guard names.isEmpty == false else { return .denied(.emptyEventKinds) }

        var resolved: Set<ControlEventKind> = []
        for name in names {
            guard let kind = ControlEventKind(rawValue: name) else {
                return .denied(.unknownEventKind(name))
            }
            resolved.insert(kind)
        }
        return .ok(resolved)
    }
}

/// Where an attention request came from, and therefore how much a subscriber
/// should trust it.
///
/// **The two sources differ in trust and nothing else distinguishes them.**
/// `ControlText` flattens and caps both, which makes either safe to *render* and
/// says nothing about whether a supervisor should *act*. An agent that asks for
/// its owner through an authenticated channel and a build script that emitted an
/// escape sequence are the same bytes by the time they reach a subscriber, and
/// only this field tells them apart.
///
/// Two cases. The field shipped on 2026-07-28 with one of them and a note that
/// `report` would produce the other, which is what happened; the enum being
/// `String`-backed is what made that additive rather than a wire change.
///
/// The CLI ships inside the app bundle, so a client and its server are always the
/// same build and an older reader can never meet a case it does not know.
public enum ControlEventSource: String, Sendable, Hashable, Codable, CaseIterable {
    /// The pane said so itself, through a bell or an OSC 9 or OSC 777
    /// notification. Untrusted: anything that can write to the PTY can send one,
    /// including output from a program the owner is merely reading.
    case osc

    /// The pane said so over this channel, authenticated with its own token.
    ///
    /// Trusted where ``osc`` is not, and that is the entire difference the field
    /// exists to record. An escape sequence can be emitted by any output the
    /// owner happens to be reading; this arrived on a socket carrying a per-run
    /// secret that only the pane's own shell was ever given.
    case report
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

    /// `attentionRaised` only: where the request came from.
    ///
    /// Absent on every other kind, and that is a statement rather than an
    /// omission: a clear comes from the owner focusing the pane or typing into
    /// it, which is the only way attention is ever answered, so a discriminator
    /// there would carry one value forever.
    public var source: ControlEventSource?

    public init(
        seq: UInt64,
        kind: ControlEventKind,
        pane: String,
        createdBy: String? = nil,
        message: String? = nil,
        activity: String? = nil,
        source: ControlEventSource? = nil
    ) {
        self.seq = seq
        self.kind = kind
        self.pane = pane
        self.createdBy = createdBy
        self.message = message
        self.activity = activity
        self.source = source
    }

    /// Flattens a string to one line and cuts it to the cap, on a scalar
    /// boundary, at the moment it enters the ring.
    ///
    /// **At emit and not at read.** The ring must not be able to hold a byte the
    /// wire cannot carry: a payload accepted here that no response could frame
    /// would sit in the ring forever, and every read that reached it would answer
    /// the same truncated batch and never advance, which is the mailbox's
    /// undrainable-message defect in a buffer nobody can drain by hand. The same
    /// argument decides where the flattening goes: both strings an event carries
    /// are pane output, one event is one line, and a newline reaching the ring
    /// would be a pane forging events into its supervisor's stream. See
    /// ``ControlText/oneLine(_:)-(String)``.
    ///
    /// **The boundary rule is load-bearing, not tidiness.** `String` is UTF-8
    /// underneath and a cut through a multi-byte scalar yields bytes no JSON
    /// encoder will emit, so a naive truncation would be the very thing that made
    /// a response unframeable. Dropping whole characters until the budget holds
    /// can only come in under the cap, never over.
    static func capped(_ text: String?) -> String? {
        guard let text else { return nil }
        // Flattened before it is measured. The substitution can only shrink the
        // byte count, so the cap below still holds, and cutting first would
        // spend the budget on bytes that were about to be replaced anyway.
        let flat = ControlText.oneLine(text)
        guard flat.utf8.count > ControlWire.maxEventStringBytes else { return flat }

        var cut = ""
        var used = 0
        for character in flat {
            let width = String(character).utf8.count
            guard used + width <= ControlWire.maxEventStringBytes else { break }
            cut.append(character)
            used += width
        }
        return cut
    }
}
