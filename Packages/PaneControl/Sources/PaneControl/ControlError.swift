import Foundation

/// Why a request produced nothing.
///
/// A closed enum rather than free prose, because the CLI maps each code to a
/// distinct exit status so a script can branch without parsing a message that
/// exists for a human. The message says what happened; the code is what is
/// programmed against.
///
/// Backed by `String` so a failure frame carries `"code": "unauthorized"`.
public enum ControlErrorCode: String, Sendable, Hashable, Codable, CaseIterable {
    /// The frame named a protocol version this build does not speak.
    case badVersion
    /// The line was not one complete JSON request, or it exceeded the frame cap.
    case badFrame
    /// The verb is not in ``ControlVerb``.
    case unknownVerb
    /// The token is not a registered pane secret. A token that parses as a
    /// well-formed pane id lands here like any other unknown value, because a
    /// pane id is a public display identifier that every same-uid process can
    /// read out of the session file.
    case badToken
    /// The caller is authenticated and the target is outside its scope. Also the
    /// answer for a target that does not exist at all, wherever telling the two
    /// apart would let a caller probe for panes it cannot see.
    case unauthorized
    /// The channel, or this verb's own key, is switched off in settings.
    case disabled
    /// The named thing does not exist, in a case where saying so leaks nothing.
    case notFound
    /// The request was understood and authorised and the workspace refused it:
    /// a zoom from an unfocused caller, a split into a tab another pane has
    /// zoomed, closing the last pane, or a connection arriving at a full pool.
    case refused
    /// A failure on baia's side. Backticked because `internal` is a keyword; the
    /// wire spelling is the plain word.
    case `internal`
}

/// A failure, with the reason a caller needs and nothing more.
///
/// Deliberately not an `Error`. Nothing in this package throws: a decode answers
/// a ``ControlDecodeResult`` and authorization answers a decision, so a failure
/// is a value that gets encoded into a response rather than a control flow that
/// can be swallowed by an over-broad `catch`.
public struct ControlError: Sendable, Hashable, Codable {
    public var code: ControlErrorCode

    /// For a human reading the terminal. Never parsed, never matched on, and
    /// never carrying a value the caller could not already see: no token, no
    /// pane id the caller has no scope for.
    public var message: String

    public init(code: ControlErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    /// The version mismatch, naming both versions.
    ///
    /// The CLI ships inside the bundle and is always built with the server, so
    /// the only way to see this is a stale binary from a copied bundle. The
    /// message says that rather than describing a negotiation that does not
    /// exist.
    static func badVersion(received: Int) -> ControlError {
        ControlError(
            code: .badVersion,
            message: "baia speaks control protocol v\(ControlWire.version) and this frame says "
                + "v\(received). The baia CLI ships inside the app bundle and is always built "
                + "with it, so this is a helper copied out of a different build."
        )
    }

    static func badFrame(_ detail: String) -> ControlError {
        ControlError(code: .badFrame, message: detail)
    }

    /// The token is not a live pane capability.
    ///
    /// One value rather than a factory taking the token, because the token must
    /// not be echoed: an unknown token is attacker-supplied and a message
    /// carrying it writes an attacker's bytes into somebody's terminal, while a
    /// *valid* token echoed into a log is the leak the whole design is about.
    ///
    /// The message names the two environment variables because the mistake this
    /// answers is nearly always the same one, a script reaching for `$BAIA_PANE`,
    /// and a reader who is told which variable to use fixes it in one step.
    static let badToken = ControlError(
        code: .badToken,
        message: "that token is not a live pane capability. $BAIA_TOKEN carries the capability "
            + "and $BAIA_PANE does not: the pane id is a public display identifier and is never "
            + "accepted as a credential."
    )

    /// The target is outside the caller's scope.
    ///
    /// One value, and the same value, for a pane that is out of scope and for a
    /// pane that does not exist at all. Two messages here would be an oracle: a
    /// caller could walk id space and learn which panes are live without being
    /// able to see any of them.
    static let unauthorized = ControlError(
        code: .unauthorized,
        message: "that pane is outside the calling pane's scope. A pane reaches itself, the panes "
            + "it created, and the panes it has peered with."
    )

    /// The ticket admits nobody.
    ///
    /// One value covering an invented ticket, a ticket rotated away, a ticket
    /// belonging to a pane that has closed, and a bearer the publisher revoked.
    /// Four sentences here would be four oracles: a pane holding a stale ticket
    /// could learn that the channel still exists, and a revoked pane could learn
    /// that it was revoked rather than that the publisher rotated, which is a
    /// distinction the publisher never agreed to share.
    ///
    /// The ticket is not echoed, for the reason ``badToken`` does not echo a
    /// token: it is attacker-supplied on the way in and a live capability on the
    /// way out, and neither belongs in a message written to a terminal.
    static let unknownTicket = ControlError(
        code: .unauthorized,
        message: "that rendezvous ticket admits nobody. Tickets are minted per run and are not "
            + "persisted, so one from an earlier run, one that has been rotated, or one whose "
            + "pane has closed all read the same: ask the publisher for a current one."
    )

    /// A pane redeemed its own ticket.
    ///
    /// `refused` rather than `unauthorized` because nothing was hidden from the
    /// caller: it is holding a ticket it minted, and peering with itself is not a
    /// thing the edge can express.
    static let selfPeering = ControlError(
        code: .refused,
        message: "that is this pane's own rendezvous ticket. A peer edge runs between two panes; "
            + "hand the ticket to the pane you want on the other end."
    )

    /// The message cannot be framed into a response, whatever its payload size
    /// says.
    ///
    /// The number is the framed size and the caller's own message is not quoted
    /// back: the text is attacker-controlled up to the frame cap, and a message
    /// that echoed it would write those bytes into somebody's terminal.
    static func messageTooLarge(framed: Int) -> ControlError {
        ControlError(
            code: .refused,
            message: "that message is \(framed) bytes once framed into a response and the cap is "
                + "\(ControlWire.maxFrameBytes). JSON escaping spends six bytes on a control "
                + "character, so a payload inside the text budget can still exceed the frame. A "
                + "message baia cannot frame is a message no recv could ever drain."
        )
    }

    /// The payload is over the documented text budget.
    static func messagePayloadTooLarge(bytes: Int) -> ControlError {
        ControlError(
            code: .refused,
            message: "that message is \(bytes) bytes of text and the cap is "
                + "\(ControlWire.maxMessagePayloadBytes). Send a path or a handle rather than a "
                + "file: the mailbox is for coordination between panes."
        )
    }

    /// The channel name is one the graph will not record.
    static func channelNameRefused(_ detail: String) -> ControlError {
        ControlError(code: .refused, message: detail)
    }

    /// A `--kinds` list named something that is not an event kind.
    ///
    /// `refused` and not `badFrame`, because the frame parsed. The kinds cross
    /// as strings so that a misspelling can be answered by name, and the channel
    /// stays drivable by hand.
    ///
    /// Echoed back clamped, for ``unknownVerb(_:)``'s reason: the name is
    /// attacker-controlled up to the frame cap, and a 256 KiB message written to
    /// somebody's terminal for a typo is the same defect whichever field the typo
    /// was in.
    /// Public, unlike its neighbours, because the server resolves `--kinds` and
    /// so is the one caller outside this package that has to name this failure.
    /// Spelling the message there instead would put the list of kinds in a second
    /// place to keep in step with ``ControlEventKind``.
    /// An explicit `--kinds` list with nothing in it.
    ///
    /// Refused rather than read as "no filter", because the two arrive as
    /// different values and mean opposite things. Accepting it would park a
    /// connection for a minute on a subscription that cannot deliver, and answer
    /// the caller with a silence it would read as an idle workspace.
    public static let emptyEventKinds = ControlError(
        code: .refused,
        message: "--kinds was given with no kinds in it. Leave it out to receive every kind, "
            + "or name at least one of: "
            + ControlEventKind.allCases.map(\.rawValue).joined(separator: ", ")
    )

    public static func unknownEventKind(_ name: String) -> ControlError {
        let shown = name.count > 40 ? String(name.prefix(40)) + "..." : name
        return ControlError(
            code: .refused,
            message: "\(shown) is not an event kind. --kinds takes any of: "
                + ControlEventKind.allCases.map(\.rawValue).joined(separator: ", ")
        )
    }

    /// The app minted a ticket the graph cannot record.
    ///
    /// Unreachable for 32 bytes out of `SecRandomCopyBytes`, and answered rather
    /// than ignored: the alternative to refusing a colliding ticket is recording
    /// a channel whose ticket admits callers to somebody else's edge.
    static let mintCollision = ControlError(
        code: .internal,
        message: "baia could not mint a rendezvous ticket for that channel. Nothing was published."
    )

    /// The connection is owed more bytes than it has read.
    ///
    /// `refused` rather than `internal`: nothing on baia's side went wrong, the
    /// peer stopped reading, and `refused` is already this wire's word for "baia
    /// will not serve this". Written as the last frame on the connection and on
    /// the understanding that a peer which stopped reading may never see it.
    static let outboundQueueFull = ControlError(
        code: .refused,
        message: "this connection is owed more than \(ControlWire.maxOutboundBytes) bytes it has "
            + "not read. baia does not hold a response for a client that stopped reading, because "
            + "the queue is memory in the app every other pane shares. Read each answer before "
            + "asking for the next."
    )

    /// The connection is pipelining faster than the app answers.
    static let tooManyRequestsInFlight = ControlError(
        code: .refused,
        message: "this connection has \(ControlWire.maxInFlightRequests) requests with baia and "
            + "none of them answered, which is the cap. The channel is pipelinable so a request "
            + "may be written before the last one is answered, not so a client may write without "
            + "reading at all."
    )

    /// Echoes the verb back, clamped.
    ///
    /// Clamped because the verb is attacker-controlled up to the whole frame
    /// cap, and a 256 KiB message would be a 256 KiB response written to a
    /// terminal for a typo.
    static func unknownVerb(_ verb: String) -> ControlError {
        let shown = verb.count > 40 ? String(verb.prefix(40)) + "..." : verb
        return ControlError(
            code: .unknownVerb,
            message: "no verb named \(shown). Run baia --help for the ones there are."
        )
    }
}
