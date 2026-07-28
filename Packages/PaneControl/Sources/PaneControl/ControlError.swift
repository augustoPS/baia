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
