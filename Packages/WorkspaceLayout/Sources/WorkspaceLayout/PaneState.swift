import Foundation

/// What a pane needs to come back after a relaunch, beside its position.
///
/// Directories are stored as strings, not `URL`s. Two `URL`s for one directory
/// compare unequal when one was built with a directory hint and the other was
/// not, so a `URL` round-tripped through the session file would silently stop
/// matching the one the pane reports, and this package would need the
/// canonicalization `ProjectAnchor` already does. A string is also what
/// `FileManager.fileExists(atPath:)` wants, which is the check
/// ``SessionStore/reconciled(_:directoryExists:)`` runs over these.
public struct PaneState: Sendable, Equatable, Codable {
    public var id: PaneID

    /// Where the pane's shell was last seen. Nil for a pane that never reported
    /// one, which is a pane whose surface had not come up yet when the session was
    /// written, and that pane still restores: it just opens wherever a new pane
    /// opens.
    public var workingDirectory: String?

    /// The pane's pinned project directory, if the user set one. Per pane rather
    /// than per app, which is the point of moving the pin out of the app-wide
    /// UserDefaults key.
    public var pinnedDirectory: String?

    public init(id: PaneID, workingDirectory: String? = nil, pinnedDirectory: String? = nil) {
        self.id = id
        self.workingDirectory = workingDirectory
        self.pinnedDirectory = pinnedDirectory
    }
}
