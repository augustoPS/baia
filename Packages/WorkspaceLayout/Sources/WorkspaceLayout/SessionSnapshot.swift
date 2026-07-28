import Foundation

/// Everything a relaunch needs to put the window back the way it was.
///
/// The workspace and the per-pane state are separate rather than nested, so the
/// tree stays a tree of ids. Hanging a directory off each leaf would mean
/// ``PaneTree`` carrying data no layout operation reads, and every `closing` and
/// `splitting` would have to copy it around correctly.
public struct SessionSnapshot: Sendable, Equatable, Codable {
    /// The version this build writes and the only version it reads.
    ///
    /// Bumped when a field changes meaning, not when one is added: a new optional
    /// field decodes as nil from an old file, and nil is exactly what "the previous
    /// version did not record this" means.
    public static let currentSchemaVersion = 1

    /// The version the file claims. ``SessionStore/load()`` is the gate: anything
    /// other than ``currentSchemaVersion`` loads as nil rather than as a workspace
    /// assembled out of fields this build guessed at. A failable `init(from:)`
    /// would have been the tighter place for that check, but every hand-written
    /// decoder is a `throws` function and this package has none.
    ///
    /// Not a `let`, so a test and a future migration can both write it.
    public var schemaVersion: Int

    public var workspace: Workspace
    public var panes: [PaneState]

    /// Nil until the window has been placed once, and nil is a launchable answer:
    /// AppKit picks a default frame.
    public var windowFrame: WindowFrame?

    /// How the sidebar was sized, or nil for a session that never opened one.
    ///
    /// Added without bumping ``currentSchemaVersion``, which is what the note there
    /// describes: a file written before this field decodes it as nil, and nil is
    /// exactly "the previous version did not record this". The default width and
    /// split are what a nil restores to.
    public var sidebar: SidebarGeometry?

    public init(
        schemaVersion: Int = SessionSnapshot.currentSchemaVersion,
        workspace: Workspace,
        panes: [PaneState],
        windowFrame: WindowFrame?,
        sidebar: SidebarGeometry? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.workspace = workspace
        self.panes = panes
        self.windowFrame = windowFrame
        self.sidebar = sidebar
    }
}
