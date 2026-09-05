import Foundation

@testable import WorkspaceLayout

/// A snapshot of one window group, spelled the way the session file was spelled
/// before groups existed.
///
/// Every test written against the flat `workspace`-plus-one-`windowFrame` shape is
/// asking a question that has nothing to do with grouping: whether a deep tree
/// round trips, whether a vanished directory drops its pane, whether a rejected
/// file blocks the next save. Those questions are unchanged by the schema, and
/// rewriting each of them by hand into `groups:` would have meant re-deriving the
/// selection id at twenty call sites and getting one of them wrong quietly.
///
/// So the old vocabulary is kept here, in the tests, as one function that produces
/// exactly what the migration produces: one group, holding those tabs, selecting
/// the one `focusedTabIndex` named, at that frame. The group tests below it use the
/// real initialiser directly, because grouping *is* their question.
func singleGroupSnapshot(
    schemaVersion: Int = SessionSnapshot.currentSchemaVersion,
    workspace: Workspace,
    panes: [PaneState],
    windowFrame: WindowFrame?,
    sidebar: SidebarGeometry?,
    fileTreeExpansions: [String: [String]]?
) -> SessionSnapshot {
    var groups: [WindowGroup] = []
    var active: UUID?
    if !workspace.tabs.isEmpty {
        let index = min(max(workspace.focusedTabIndex, 0), workspace.tabs.count - 1)
        let group = WindowGroup(
            id: UUID(),
            tabs: workspace.tabs,
            selectedTab: workspace.tabs[index].id,
            frame: windowFrame,
            sidebar: sidebar
        )
        groups = [group]
        active = group.id
    }
    return SessionSnapshot(
        schemaVersion: schemaVersion,
        groups: groups,
        activeGroup: active,
        panes: panes,
        fileTreeExpansions: fileTreeExpansions
    )
}

extension SessionSnapshot {
    /// The one group this snapshot holds, for a test that built it with
    /// ``singleGroupSnapshot(schemaVersion:workspace:panes:windowFrame:sidebar:fileTreeExpansions:)``.
    var onlyGroup: WindowGroup? { groups.first }

    /// The frame of the only group, which is what `windowFrame` used to mean.
    var onlyFrame: WindowFrame? { groups.first?.frame }

    /// The tabs of the only group, in order.
    var onlyTabs: [Tab] { groups.first?.tabs ?? [] }

    /// The sidebar of the only group, which is what the session-level `sidebar`
    /// field used to mean.
    var onlySidebar: SidebarGeometry? { groups.first?.sidebar }
}
