import Foundation
import Security

/// Where every secret the control channel holds comes from.
///
/// In the app target rather than in `PaneControl`, so that package keeps
/// importing Foundation and nothing else: its types are compiled into the CLI
/// that ships in every pane's PATH, and a package reaching for `Security` would
/// drag the framework into the helper for a function the helper never calls.
///
/// One function for three kinds of secret, because the pane capability, the
/// rendezvous ticket, and the per-edge identity differ in what they authorise and
/// not in what they are made of. Each needs exactly two properties: it cannot be
/// guessed, and it is not a pane id.
enum ControlSecrets {
    /// 32 bytes from the system CSPRNG, base64url, unpadded, or nil when the
    /// kernel would not give them.
    ///
    /// `SecRandomCopyBytes` rather than `UUID()`, and the difference is not
    /// pedantry: a UUID would carry 122 bits from an unspecified source *and*
    /// would parse as a pane id, which is the one value the graph refuses to
    /// register and refuses to authorise. The mistake would surface as a pane
    /// whose every request answers `badToken`, a long way from the line that
    /// caused it.
    ///
    /// base64url because the value travels through a JSON string and, for
    /// `$BAIA_TOKEN`, through a shell's environment. `+` and `/` survive both and
    /// are exactly the characters a script pasting a ticket is most likely to
    /// mangle. Padding goes for the same reason: nothing decodes this string, it
    /// is compared whole.
    ///
    /// Nil rather than a fatal error or a weaker fallback. A failure here means
    /// the system refused entropy, and the honest answer to a `publish` in that
    /// state is `internal`, not a ticket somebody could guess.
    static func mint() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
