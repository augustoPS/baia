import Testing

@testable import WorkspaceMenu

@Suite struct QuickTerminalTests {
    @Test func quickTerminalIsAvailableWithoutWorkspaceWindows() {
        let entry = CommandCatalog.entry(for: .quickTerminal, given: .empty)
        #expect(entry.state.isEnabled)
        #expect(entry.target == .application)
        #expect(entry.isOfferedInPalette)
    }

    @Test func quickTerminalClaimsCommandGraveWithoutAnEngineBindingConflict() {
        let item = MenuBarLayout.item(for: .quickTerminal)
        #expect(item?.title == "Quick Terminal")
        #expect(item?.shortcut == MenuShortcut(key: .character("`"), modifiers: .command))
        #expect(item?.policy == .noConflict)
    }
}
