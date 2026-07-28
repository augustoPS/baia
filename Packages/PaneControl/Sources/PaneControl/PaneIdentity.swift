import Foundation

/// A pane's public display identity, the value `$BAIA_PANE` carries.
///
/// Public by construction and not by concession: `session.json` holds every
/// pane's id, the file is mode 0600 in a 0700 directory, and that excludes other
/// *users* rather than other *processes of the same user*, which is precisely
/// the adversary. Any pane running `cat` on that file learns every id in the
/// workspace, so an id proves nothing about who is asking.
///
/// A mirror of `WorkspaceLayout.PaneID` rather than that type, because this
/// package imports Foundation and nothing else and a wire type that was also a
/// layout type would drag the layout package into the CLI. The app maps one onto
/// the other in one place, the way it already does for ``ControlAxis``.
///
/// Deliberately not `Codable`. The wire spells a pane id as a bare string and
/// `PaneID` spells it `{"rawValue": "..."}`, so a synthesized conformance here
/// would put a third spelling in play for a value that has exactly two.
public struct ControlPaneID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    /// Rebuilds an id the app already holds.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// Rebuilds an id from the string a frame carried, or nil when the string is
    /// not one.
    ///
    /// Also the predicate behind ``PaneSecret/parsesAsPaneID``. "Is this a pane
    /// id" gets asked in two places, the registry and the authorization
    /// resolver, and both ask it here, so the rule has one implementation and
    /// two enforcement points rather than two implementations that can drift
    /// apart while both look correct.
    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        rawValue = uuid
    }

    /// The wire spelling. Safe to print, safe to log, safe to return from a read
    /// verb, which is the entire difference between this type and ``PaneSecret``.
    public var description: String { rawValue.uuidString }
}

extension String {
    /// Whether this string is a pane's public display id wearing another name.
    ///
    /// One implementation and three enforcement points: the pane registry, the
    /// authorization resolver, and the rendezvous ticket. Written once so the
    /// rule cannot drift apart into three that all look correct, and asked in
    /// three places so no single table has to be clean for the answer to hold.
    var parsesAsPaneID: Bool { ControlPaneID(uuidString: self) != nil }
}

/// A pane's per-run capability, the value `$BAIA_TOKEN` carries.
///
/// 32 bytes from `SecRandomCopyBytes`, base64url-encoded, minted when the pane
/// is created and never written to disk. Minting lives in the app target so this
/// package stays free of `Security`; what lives here is the one rule that makes
/// the capability worth anything, which is that a secret is not an id.
///
/// **Not `Codable`, and not by oversight.** A response field of this type would
/// not compile, which is a stronger guarantee than any test, and a test asserts
/// the conformance is still absent so that adding it has to be somebody's
/// deliberate, defensible act rather than an autocompleted `Codable` on a
/// declaration line.
///
/// ``description`` redacts for the same reason. A secret that reached a log line
/// would be as leaked as one that reached a response body, and the only
/// difference is that nobody would be looking for it there.
public struct PaneSecret: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Whether this "secret" is a pane id wearing a secret's name.
    ///
    /// The negative invariant the whole design exists to hold. A channel that
    /// accepted a pane id here would let any leaf pane read `session.json` and
    /// act as any pane in any window with v1 verbs alone, which is why
    /// ``PaneGraph`` refuses to register such a value *and*
    /// ``PaneGraph/authorize(token:verb:target:)`` refuses one before it looks
    /// anything up. Two enforcement points rather than one, so the answer does
    /// not depend on the registry being clean.
    var parsesAsPaneID: Bool { rawValue.parsesAsPaneID }

    public var description: String { "PaneSecret(redacted)" }
    public var debugDescription: String { description }
}
