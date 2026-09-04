import Foundation

/// One line off the socket, once it has been understood.
///
/// The server never sees a partially built one of these: ``ControlWire`` answers
/// a whole request or an error, so there is no half-decoded state a handler could
/// act on.
public struct ControlRequest: Sendable, Equatable, Codable {
    /// The protocol version the sender speaks. Always
    /// ``ControlWire/version`` from this build; anything else is refused at
    /// decode with `badVersion`.
    public var v: Int

    /// The calling pane's per-run secret, straight from `$BAIA_TOKEN`.
    ///
    /// A secret and never a pane id. `$BAIA_PANE` is a public display id that
    /// sits in `session.json`, which any same-uid process can read, so a design
    /// that authenticated on it would let any leaf act as any pane in any
    /// window. The registry rejects a token that parses as a pane id rather than
    /// merely failing to find it.
    public var token: String

    public var verb: ControlVerb

    /// Everything the verb needs beyond the verb itself. Empty for the verbs
    /// that need nothing, and encoded as `{}` rather than omitted, so a frame
    /// read by hand has the same shape whatever the verb.
    public var args: ControlArgs

    public init(
        v: Int = ControlWire.version,
        token: String,
        verb: ControlVerb,
        args: ControlArgs = ControlArgs()
    ) {
        self.v = v
        self.token = token
        self.verb = verb
        self.args = args
    }
}

/// The union of every verb's arguments, one flat optional per argument.
///
/// One struct rather than an enum with a case per verb. An enum would encode as
/// a nested discriminated object, which is worse to read with `nc` and worse to
/// write by hand in the diagnostic, and the type safety it would buy is bought
/// anyway by ``ControlVerb`` being closed: an argument that makes no sense for a
/// verb is ignored by that verb's handler, in a package where the handler cannot
/// be reached without passing authorization first.
///
/// Every field is optional and nil fields are omitted from the encoded frame,
/// which is what the synthesized encoder does for optionals.
public struct ControlArgs: Sendable, Equatable, Codable {
    /// `split`: which way the divider cuts.
    public var axis: ControlAxis?

    /// `split`: where the new pane's shell starts. Nil means wherever a new pane
    /// would have started anyway.
    public var cwd: String?

    /// `split`: what the new pane runs instead of a login shell. Nil is a login
    /// shell, which is what every pane opened by hand gets.
    ///
    /// **Passed to ghostty verbatim**, as its `command` config key, so the
    /// caller's string keeps ghostty's own meaning: a bare value with arguments
    /// goes through `/bin/sh -c`, `direct:` execs without a shell, and `shell:`
    /// forces the wrap. Nothing here wraps it, because a pane that runs something
    /// other than what the caller wrote is a pane whose behaviour lives in two
    /// places. The lifetime decision, whether a shell survives the command, is
    /// the caller's and is spelled in the caller's string.
    ///
    /// **A newline is refused, and that refusal is load-bearing.** The value is
    /// rendered into a ghostty config file as `command = <value>` and the file is
    /// parsed line by line, so a value carrying a newline writes a second config
    /// key of the caller's choosing. `clipboard-read = allow` is one line, and it
    /// undoes the OSC 52 denial every pane is built with. Refused at
    /// ``ControlWire/refusalForCommand(_:)``, which both the CLI and the server
    /// call, because a hand-written frame never passes through the CLI.
    ///
    /// This grants no execution a caller did not already have: a pane asking for
    /// this is a pane with a shell it can run the same command in. What it grants
    /// is *where*, and the parentage graph already records who asked.
    public var command: String?

    /// `resize`: which way the caller wants to grow.
    public var direction: ControlDirection?

    /// `resize`: how far, as a fraction of the split it moves.
    public var by: Double?

    /// `zoom`: the state asked for. Nil is a toggle, true is `--on`, false is
    /// `--off`, which is what makes `baia zoom --on` idempotent in a script.
    public var on: Bool?

    /// `publish`, `connect`: the channel name a pane publishes under.
    public var name: String?

    /// `publish --rotate`: mint a fresh rendezvous token, keeping established
    /// edges and admitting nobody new on the old one.
    public var rotate: Bool?

    /// `connect`: the rendezvous token, read from stdin by the CLI and never
    /// from argv, because `ps -ww` shows any same-uid process's full argv.
    public var rendezvous: String?

    /// `send`, `revoke`: the peer's display pane id. `read`: the pane to read.
    /// `move`: the pane to move. `explain`: the pane to explain, optional where
    /// the other four are required.
    ///
    /// One field for five verbs, the way ``text`` serves `send` and `report`: it
    /// is the pane this request is about, and what the caller has to stand in to
    /// name it is the verb's scope rather than the field's spelling.
    public var peer: String?

    /// `move`: the display pane id the moved pane lands beside.
    ///
    /// A field of its own rather than a second use of ``peer``, because `move` is
    /// the only verb naming two panes and a caller reading a frame with `nc` has
    /// to be able to tell which one is which. Both are authorised: landing a pane
    /// beside one the caller may not touch would reshape a grid it does not own.
    public var beside: String?

    /// `send`: the message body, capped at
    /// ``ControlWire/maxMessagePayloadBytes``. `report --message`: what a blocked
    /// pane is asking for, capped instead at ``ControlWire/maxEventStringBytes``
    /// when it enters the ring. One field for both, the way `name` serves both
    /// `publish` and `connect`: the caps differ because the destinations do.
    public var text: String?

    /// `recv --wait`: how long to park, capped at ``ControlWire/maxWaitSeconds``
    /// by the server rather than trusted from the client.
    public var wait: Int?

    /// `subscribe`: the cursor to read after. 0 means everything the ring still
    /// holds, which on a ring that has evicted answers `gap: true`.
    public var from: UInt64?

    /// `subscribe --kinds`: which kinds to deliver, defaulting to all of them.
    ///
    /// **Strings rather than ``ControlEventKind``**, so an unknown kind is
    /// answered `refused` with the offending name rather than `badFrame` from a
    /// decoder. The channel is meant to stay drivable by hand with `nc`, and a
    /// hand-written frame is exactly where a misspelling happens.
    public var kinds: [String]?

    /// `report`: what the pane says it is doing.
    public var state: ReportedState?

    /// `report`: how long the statement holds, capped by
    /// ``ControlWire/cappedReportTTL(_:)`` at the server rather than trusted from
    /// the client, the same treatment ``wait`` gets.
    public var ttl: Int?

    /// `report`: the reporter's ordering claim. Nil is a reporter making none.
    public var seq: UInt64?

    /// `report --release`: hand authority back to the pollers now.
    public var release: Bool?

    /// `read`: how many lines to answer with, capped by ``ScreenRead/maxLines``
    /// at the server rather than trusted from the client, the same treatment
    /// ``wait`` and ``ttl`` get.
    public var lines: Int?

    /// `layout apply`: the document to open a window from, read from stdin by the
    /// CLI the way `connect` reads its ticket.
    ///
    /// A decoded value rather than the file's text. The CLI has to parse it anyway
    /// to refuse a malformed file before opening the socket, and re-encoding a
    /// string inside a string is one more layer for a hand-written frame to get
    /// wrong. ``ControlLayout/refusal()`` runs on both sides, and the server's is
    /// the one that counts.
    public var layout: ControlLayout?

    public init(
        axis: ControlAxis? = nil,
        cwd: String? = nil,
        command: String? = nil,
        direction: ControlDirection? = nil,
        by: Double? = nil,
        on: Bool? = nil,
        name: String? = nil,
        rotate: Bool? = nil,
        rendezvous: String? = nil,
        peer: String? = nil,
        beside: String? = nil,
        text: String? = nil,
        wait: Int? = nil,
        from: UInt64? = nil,
        kinds: [String]? = nil,
        state: ReportedState? = nil,
        ttl: Int? = nil,
        seq: UInt64? = nil,
        release: Bool? = nil,
        lines: Int? = nil,
        layout: ControlLayout? = nil
    ) {
        self.axis = axis
        self.cwd = cwd
        self.command = command
        self.direction = direction
        self.by = by
        self.on = on
        self.name = name
        self.rotate = rotate
        self.rendezvous = rendezvous
        self.peer = peer
        self.beside = beside
        self.text = text
        self.wait = wait
        self.from = from
        self.kinds = kinds
        self.state = state
        self.ttl = ttl
        self.seq = seq
        self.release = release
        self.lines = lines
        self.layout = layout
    }
}

/// Which way a split cuts, spelled the way `WorkspaceLayout.SplitAxis` spells it.
///
/// A separate type because this package imports Foundation and nothing else, and
/// a wire type that is also a layout type would drag the layout package into the
/// CLI. The app maps one onto the other in one place.
///
/// Named after how the children sit, not after how the divider runs, matching
/// `SplitAxis`: `horizontal` is side by side, which is what `baia split --right`
/// asks for.
public enum ControlAxis: String, Sendable, Hashable, Codable, CaseIterable {
    case horizontal
    case vertical
}

/// Which way a resize travels, one per arrow key, mapping onto
/// `WorkspaceLayout.FocusDirection`.
///
/// `FocusDirection` is deliberately not `Codable` over there, because a
/// direction is a keystroke and never session state. This is the wire's own
/// spelling and the app translates it.
public enum ControlDirection: String, Sendable, Hashable, Codable, CaseIterable {
    case left
    case right
    case up
    case down
}
