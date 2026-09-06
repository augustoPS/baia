import Testing

@testable import WorkspaceMenu

@Suite struct CommandContextTests {
    private final class Window {}

    private func workspace(_ window: Window, _ name: String) -> CommandWorkspace<Window, String> {
        CommandWorkspace(window: window, workspace: name)
    }

    @Test func aForeignKeyWindowDoesNotFallThroughToTheMainWorkspace() {
        let first = Window()
        let second = Window()
        let foreign = Window()

        let context = CommandContextResolver.resolve(
            keyWindow: foreign,
            mainWindow: second,
            settingsWindow: nil,
            workspaces: [workspace(first, "first"), workspace(second, "second")],
            isPanel: { _ in false }
        )

        #expect(context == .system)
    }

    @Test func settingsDoesNotFallThroughToTheWorkspaceThatRemainsMain() {
        let workspaceWindow = Window()
        let settings = Window()

        let context = CommandContextResolver.resolve(
            keyWindow: settings,
            mainWindow: workspaceWindow,
            settingsWindow: settings,
            workspaces: [workspace(workspaceWindow, "workspace")],
            isPanel: { _ in false }
        )

        #expect(context == .settings)
    }

    @Test func aPanelDoesNotBecomeAWorkspaceButItsCapturedInvocationWindowStillResolves() {
        let invokedFrom = Window()
        let panel = Window()
        let workspaces = [workspace(invokedFrom, "invoked")]

        let current = CommandContextResolver.resolve(
            keyWindow: panel,
            mainWindow: invokedFrom,
            settingsWindow: nil,
            workspaces: workspaces,
            isPanel: { $0 === panel }
        )
        let captured = CommandContextResolver.workspace(owning: invokedFrom, in: workspaces)

        #expect(current == .panel)
        #expect(captured == "invoked")
    }

    @Test func aWorkspaceKeyWindowSelectsItsOwnTarget() {
        let first = Window()
        let second = Window()

        let context = CommandContextResolver.resolve(
            keyWindow: second,
            mainWindow: first,
            settingsWindow: nil,
            workspaces: [workspace(first, "first"), workspace(second, "second")],
            isPanel: { _ in false }
        )

        #expect(context == .workspace("second"))
    }
}
