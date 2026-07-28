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
