import Foundation

/// One line back down the socket.
///
/// `ok` is redundant with which of `result` and `error` is present, and it is
/// carried anyway: a client reading a frame by hand, or with `jq`, branches on
/// one field rather than on the absence of another, and the two can never
/// disagree because both factories set them together.
public struct ControlResponse: Sendable, Equatable, Codable {
    public var v: Int
    public var ok: Bool
    public var result: ControlResult?
    public var error: ControlError?

    public init(v: Int = ControlWire.version, ok: Bool, result: ControlResult?, error: ControlError?) {
        self.v = v
        self.ok = ok
        self.result = result
        self.error = error
    }

    /// A success, with whatever the verb had to say. Verbs that return nothing
    /// pass an empty result rather than nil, so a client never has to tell "this
    /// verb returns nothing" apart from "this response lost its body".
    public static func success(_ result: ControlResult = ControlResult()) -> ControlResponse {
        ControlResponse(ok: true, result: result, error: nil)
    }

    public static func failure(_ error: ControlError) -> ControlResponse {
        ControlResponse(ok: false, result: nil, error: error)
    }

    public static func failure(_ code: ControlErrorCode, _ message: String) -> ControlResponse {
        .failure(ControlError(code: code, message: message))
    }
}

/// The union of every verb's answer, one flat optional per field, for the same
/// reason ``ControlArgs`` is flat: a frame stays readable by hand.
///
/// **Nothing here may carry a pane's capability.** The pane secret from
/// `$BAIA_TOKEN` and the per-edge secret `connect` mints are held in memory by
/// the server and are never encoded into a response, never written to
/// `session.json`, and never passed in argv. Every identifier below is a display
/// id, which is public by construction: `session.json` already holds all of
/// them and any same-uid process can read it.
///
/// ``rendezvous`` is the one value that crosses this wire and is not a display
/// id, and it is bounded rather than excepted. See its own note.
public struct ControlResult: Sendable, Equatable, Codable {
    /// A display pane id: the pane `split` opened, or the peer `connect`
    /// established an edge with.
    public var pane: String?

    /// The channel name a `connect` joined under.
    public var name: String?

    /// The rendezvous token, returned by `publish` to the pane that published,
    /// and by nothing else.
    ///
    /// This is the one secret-shaped value the wire carries, and it is carried
    /// because there is no other way for a publisher to obtain the ticket it
    /// exists to hand out. What keeps it inside rule 2 rather than outside it:
    /// it is minted for the caller, returned only to the caller in the response
    /// to the caller's own `publish`, and it confers admission to a
    /// communication edge and no control authority whatsoever. It is not a pane
    /// capability, it cannot be replayed into an established edge, and
    /// `revoke` deletes the per-edge secret it led to rather than this ticket.
    /// It is never persisted and never passed in argv: `connect` reads it from
    /// stdin.
    public var rendezvous: String?

    /// `zoom`: the state the tab ended up in.
    public var zoomed: Bool?

    /// `whoami`, `list`, `peers`: the records the caller is allowed to see.
    ///
    /// `whoami` answers a one-element list rather than a record of its own, so
    /// the CLI renders one shape and a scope leak has one place to be caught.
    public var panes: [PaneRecord]?

    /// `recv`: what came out of the mailbox, oldest first.
    public var messages: [ControlMessage]?

    /// `recv`: true when the mailbox still holds messages this response could
    /// not fit, either because the batch cap or the frame cap stopped it. A
    /// message leaves the mailbox only once it has been framed into a response
    /// that fits, so `more` means "poll again" and never "some are gone".
    public var more: Bool?

    /// `recv`: how many messages were dropped from a full mailbox since the last
    /// drain, reported once and then reset. A silent drop is worse than a lost
    /// message, because the reader concludes nothing was sent.
    public var dropped: Int?

    public init(
        pane: String? = nil,
        name: String? = nil,
        rendezvous: String? = nil,
        zoomed: Bool? = nil,
        panes: [PaneRecord]? = nil,
        messages: [ControlMessage]? = nil,
        more: Bool? = nil,
        dropped: Int? = nil
    ) {
        self.pane = pane
        self.name = name
        self.rendezvous = rendezvous
        self.zoomed = zoomed
        self.panes = panes
        self.messages = messages
        self.more = more
        self.dropped = dropped
    }
}

/// What `whoami` and `list` say about one pane.
///
/// Display ids and human-readable strings only. No token, and no field that
/// could carry one.
public struct PaneRecord: Sendable, Equatable, Codable {
    /// The persisted `PaneID`, as its UUID string. The same value the pane's own
    /// `$BAIA_PANE` carries, which is a public display id and not a credential.
    public var pane: String

    /// Where the pane sits, as one-based positions for a human reading the
    /// output. Positions rather than window and tab identities: nothing in v1
    /// addresses a window or a tab, so an identity here would be a handle
    /// nothing can use and one more value to keep truthful.
    public var window: Int
    public var tab: Int

    public var workingDirectory: String?

    /// The pinned project directory, if the pane has one.
    public var anchor: String?

    /// The git branch the pane's directory is on, if it is a repository.
    public var branch: String?

    /// What the pane is doing, in the same words the pane header shows.
    public var activity: String?

    /// Whether the pane is asking for attention, in the same words the chrome
    /// uses.
    public var attention: String?

    /// The display id of the pane that created this one through the channel, or
    /// nil for a pane the owner opened by hand. An identifier and never a
    /// credential, which is what makes it safe to return: it answers "where did
    /// this pane come from" for an owner who did not open it.
    public var createdBy: String?

    /// Names this pane has published, if any. Names, never the tokens behind
    /// them.
    public var channels: [String]

    /// Display ids of panes this one has an established peer edge with.
    public var peers: [String]

    public init(
        pane: String,
        window: Int,
        tab: Int,
        workingDirectory: String? = nil,
        anchor: String? = nil,
        branch: String? = nil,
        activity: String? = nil,
        attention: String? = nil,
        createdBy: String? = nil,
        channels: [String] = [],
        peers: [String] = []
    ) {
        self.pane = pane
        self.window = window
        self.tab = tab
        self.workingDirectory = workingDirectory
        self.anchor = anchor
        self.branch = branch
        self.activity = activity
        self.attention = attention
        self.createdBy = createdBy
        self.channels = channels
        self.peers = peers
    }
}

/// One message out of a mailbox.
///
/// Out of band, into a mailbox, and never into another pane's PTY. Writing to a
/// PTY is `run`, it is v2, and it is off by default.
public struct ControlMessage: Sendable, Equatable, Codable {
    /// The display id of the pane that sent it.
    public var from: String

    /// The body. Capped at ``ControlWire/maxMessagePayloadBytes`` when it is
    /// accepted, which is set well below the frame cap so a maximal message
    /// still fits after JSON string escaping inflates it.
    public var text: String

    public init(from: String, text: String) {
        self.from = from
        self.text = text
    }
}
