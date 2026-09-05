import Foundation

/// Everything a relaunch needs to put the windows back the way they were.
///
/// The groups and the per-pane state are separate rather than nested, so the tree
/// stays a tree of ids. Hanging a directory off each leaf would mean ``PaneTree``
/// carrying data no layout operation reads, and every `closing` and `splitting`
/// would have to copy it around correctly.
public struct SessionSnapshot: Sendable, Equatable, Codable {
    /// The version this build writes. ``SessionStore/inspect()`` also reads version
    /// 1 and migrates it; every other version is refused whole.
    ///
    /// Bumped when a field changes meaning, not when one is added: a new optional
    /// field decodes as nil from an old file, and nil is exactly what "the previous
    /// version did not record this" means. Version 2 is the case that reserves a
    /// bump. ``workspace`` did not gain a field, it stopped being the
    /// representation: the flat `[Tab]`, the single `windowFrame` and the single
    /// `sidebar` became ``groups``, each with its own tabs, selection, frame and
    /// sidebar.
    ///
    /// **The cheap alternative was rejected deliberately.** Keeping version 1 and
    /// adding an optional `groups` beside `workspace` would let an older build
    /// decode the file it believes it understands, discard the unknown key in
    /// silence, restore the flattening, and then save that flattening back over the
    /// user's two groups on quit, reporting nothing. A version bump turns that
    /// silent loss into the refusal ``SessionStore`` already implements: an old
    /// build rejects the file, R01's save gate blocks every automatic write, and
    /// the bytes survive.
    public static let currentSchemaVersion = 2

    /// The oldest version ``SessionStore/inspect()`` will migrate rather than
    /// refuse. Files below it record a tree shape this build cannot reconstruct.
    public static let oldestReadableSchemaVersion = 1

    /// The version the file claims. ``SessionStore/inspect()`` is the gate: a
    /// version this build neither writes nor migrates loads as a rejection rather
    /// than as a workspace assembled out of fields this build guessed at. A
    /// failable `init(from:)` would have been the tighter place for that check, but
    /// every hand-written decoder is a `throws` function and this package has none.
    ///
    /// Not a `let`, so a test and a migration can both write it.
    public var schemaVersion: Int

    /// The windows, in the order they were walked. Front-to-back z-order is
    /// deliberately not recorded: AppKit does not restore it faithfully across a
    /// relaunch, and ``activeGroup`` already answers the question that matters,
    /// which is which window comes forward.
    public var groups: [WindowGroup]

    /// Which group held the keyboard, by ``WindowGroup/id``, or nil for a session
    /// with no groups.
    ///
    /// An id rather than an index for the reason ``WindowGroup/selectedTab`` is one:
    /// reconciliation can drop a whole group, and every index after it shifts.
    public var activeGroup: UUID?

    public var panes: [PaneState]

    /// Which directories the file tree was left showing, per anchor.
    ///
    /// ``SessionStore/reconciled(_:directoryExists:resolveAnchor:)`` prunes this to
    /// the anchors still named by a surviving pane, so a quit cannot leave the file
    /// remembering a repository the restored windows no longer hold.
    public var fileTreeExpansions: [String: [String]]?

    /// No defaulted parameters, deliberately, which is the rule ``Settings`` states
    /// and this type learned the hard way. `sidebar` shipped with a default of nil
    /// and `SessionStore.reconciled` kept compiling while silently dropping it, so a
    /// dragged sidebar was written to disk correctly and restored to its default.
    /// Without a default the compiler names every site that has to decide.
    public init(
        schemaVersion: Int = SessionSnapshot.currentSchemaVersion,
        groups: [WindowGroup],
        activeGroup: UUID?,
        panes: [PaneState],
        fileTreeExpansions: [String: [String]]?
    ) {
        self.schemaVersion = schemaVersion
        self.groups = groups
        self.activeGroup = activeGroup
        self.panes = panes
        self.fileTreeExpansions = fileTreeExpansions
    }

    /// The group that held the keyboard, or the first one.
    ///
    /// Resolved rather than trusted, for the reason ``WindowGroup/selected`` is: a
    /// decoded session can name a group that reconciliation dropped, and falling
    /// back to the first group is a window the owner can reach.
    public var active: WindowGroup? {
        groups.first { $0.id == activeGroup } ?? groups.first
    }

    /// Every pane every group shows, in group order.
    public var shownPaneIDs: [PaneID] {
        groups.flatMap { $0.paneIDs }
    }

    /// Where the keyboard lands: the focused pane of the active group's selected
    /// tab, resolved through both fallbacks rather than through two stored indices.
    public var selectedPane: PaneID? {
        active?.selected?.focusedPane
    }
}

/// The session file as version 1 wrote it, read only to migrate it forward.
///
/// A separate type rather than optional fields on ``SessionSnapshot``, so the
/// current shape carries no field that only ever means "this came from an older
/// file". The v1 decoder lives here and nowhere else, which is what keeps the
/// migration a single function with a single test surface.
struct SessionSnapshotV1: Decodable {
    var schemaVersion: Int
    var workspace: Workspace
    var panes: [PaneState]
    var windowFrame: WindowFrame?
    var sidebar: SidebarGeometry?
    var fileTreeExpansions: [String: [String]]?
}

extension SessionSnapshot {
    /// A version 1 file as version 2 records it.
    ///
    /// Total and lossless in the only direction it can be. A v1 file recorded one
    /// flat tab list and one frame, which is exactly the app's own behaviour at the
    /// time: every window was joined into a single tab group, so one group at one
    /// frame is what those bytes actually described. Nothing is invented.
    ///
    /// A `focusedTabIndex` out of range selects the first tab, matching the clamp
    /// ``SessionStore/reconciled(_:directoryExists:resolveAnchor:)`` already applies
    /// to it. A v1 file with no tabs migrates to no groups, which `restoreSession`
    /// already treats as "open a fresh window".
    static func migrating(_ old: SessionSnapshotV1) -> SessionSnapshot {
        var groups: [WindowGroup] = []
        var active: UUID?
        if let first = old.workspace.tabs.first {
            let index = min(max(old.workspace.focusedTabIndex, 0), old.workspace.tabs.count - 1)
            let selected = old.workspace.tabs[index].id
            let group = WindowGroup(
                id: UUID(),
                tabs: old.workspace.tabs,
                // `first.id` is unreachable: `index` is clamped into a non-empty
                // collection above. Spelled out rather than force-unwrapped so the
                // expression stays total on its face.
                selectedTab: old.workspace.tabs.indices.contains(index) ? selected : first.id,
                frame: old.windowFrame,
                // The one session-wide sidebar becomes this one group's sidebar,
                // which loses nothing: v1 wrote the focused window's geometry and
                // restored it to every window, and a v1 file is one group.
                sidebar: old.sidebar
            )
            groups = [group]
            active = group.id
        }
        return SessionSnapshot(
            groups: groups,
            activeGroup: active,
            panes: old.panes,
            fileTreeExpansions: old.fileTreeExpansions
        )
    }
}
