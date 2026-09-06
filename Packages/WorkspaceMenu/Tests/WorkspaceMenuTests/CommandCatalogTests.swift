import Testing

@testable import WorkspaceMenu

@Suite struct CommandCatalogTests {
    @Test func pasteFromSelectionIsNotAnOfferedPaletteVerb() {
        let offered = CommandCatalog.entries(given: MenuAvailability(paneCount: 2, tabCount: 1))
            .filter(\.isOfferedInPalette)
            .map(\.command)

        #expect(!offered.contains(.pasteSelection))
        #expect(offered.contains(.selectPreviousPane))
        #expect(offered.contains(.refreshGitStatus))
        #expect(offered.contains(.copyDiagnostics))
    }

    @Test func catalogNamesTheTargetEachRepairedCommandNeeds() {
        #expect(CommandCatalog.entry(for: .selectPreviousPane, given: .empty).target == .workspace)
        #expect(CommandCatalog.entry(for: .refreshGitStatus, given: .empty).target == .workspace)
        #expect(CommandCatalog.entry(for: .newTab, given: .empty).target == .workspace)
        #expect(CommandCatalog.entry(for: .copyDiagnostics, given: .empty).target == .application)
        #expect(CommandCatalog.entry(for: .copy, given: .empty).target == .responder)
    }

    @Test func dispatchExecutesTheCatalogCommandOnlyThroughAValidTarget() {
        let entry = CommandCatalog.entry(
            for: .selectPreviousPane,
            given: MenuAvailability(paneCount: 2, tabCount: 1)
        )
        var performed: MenuCommand?

        let result = CommandCatalog.dispatch(
            entry,
            actionIsSupported: true,
            targetIsValid: true
        ) { command in
            performed = command
            return true
        }

        #expect(result == .performed)
        #expect(performed == .selectPreviousPane)
    }

    @Test func dispatchExplicitlyRefusesAMissingTargetWithoutCallingIt() {
        let entry = CommandCatalog.entry(
            for: .selectPreviousPane,
            given: MenuAvailability(paneCount: 2, tabCount: 1)
        )
        var called = false

        let result = CommandCatalog.dispatch(
            entry,
            actionIsSupported: true,
            targetIsValid: false
        ) { _ in
            called = true
            return true
        }

        #expect(result == .refused(.missingTarget))
        #expect(!called)
    }

    @Test func dispatchReportsAResponderRefusalInsteadOfClaimingExecution() {
        let entry = CommandCatalog.entry(
            for: .copyDiagnostics,
            given: .empty
        )

        let result = CommandCatalog.dispatch(
            entry,
            actionIsSupported: true,
            targetIsValid: true,
            perform: { _ in false }
        )

        #expect(result == .refused(.targetRefused))
    }
}
