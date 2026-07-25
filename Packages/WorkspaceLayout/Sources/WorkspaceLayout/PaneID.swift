import Foundation

/// A pane's identity, stable across a layout change and across a relaunch.
///
/// A wrapper rather than a bare `UUID` so a pane id cannot be handed to something
/// expecting a tab id. ``Tab`` carries a plain `UUID` and the two are structurally
/// identical, which the compiler would otherwise let a caller mix up while walking
/// `SessionSnapshot.panes`.
///
/// `Codable` is synthesized, so the session file spells a pane id as
/// `{"rawValue": "..."}`. A bare string would read better there but needs a
/// hand-written `init(from:)`, which is a `throws` function in a package that
/// otherwise has none.
public struct PaneID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    /// A fresh identity for a pane that is being opened now.
    public init() {
        rawValue = UUID()
    }

    /// Rebuilds an identity that was read back from a session file.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}
