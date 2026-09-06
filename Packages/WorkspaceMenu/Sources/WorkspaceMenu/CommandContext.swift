import Foundation

/// The owner of a command at the moment AppKit asks for it.
///
/// A foreign key window is deliberately ``system`` even when a workspace stays
/// main underneath it. That negative identification keeps a sheet, colour
/// panel, or future auxiliary window from mutating a hidden workspace.
public enum CommandContext<Workspace: Equatable>: Equatable {
    case workspace(Workspace)
    case settings
    case panel
    case system
    case none

    public var workspace: Workspace? {
        guard case let .workspace(workspace) = self else { return nil }
        return workspace
    }
}

/// Associates an identity-bearing window with the workspace it owns.
public struct CommandWorkspace<Window: AnyObject, Workspace> {
    public let window: Window
    public let workspace: Workspace

    public init(window: Window, workspace: Workspace) {
        self.window = window
        self.workspace = workspace
    }
}

/// Resolves command ownership from key/main window identity without a fallback
/// to the first workspace in an unordered collection.
public enum CommandContextResolver {
    public static func resolve<Window: AnyObject, Workspace: Equatable>(
        keyWindow: Window?,
        mainWindow: Window?,
        settingsWindow: Window?,
        workspaces: [CommandWorkspace<Window, Workspace>],
        isPanel: (Window) -> Bool
    ) -> CommandContext<Workspace> {
        if let keyWindow, keyWindow === settingsWindow { return .settings }
        if let keyWindow, isPanel(keyWindow) { return .panel }
        if let keyWindow {
            guard let workspace = workspace(owning: keyWindow, in: workspaces) else {
                return .system
            }
            return .workspace(workspace)
        }
        if let mainWindow, let workspace = workspace(owning: mainWindow, in: workspaces) {
            return .workspace(workspace)
        }
        return .none
    }

    /// Resolves a previously captured invocation window. The palette uses this
    /// after it becomes key, when the current context correctly says ``panel``.
    public static func workspace<Window: AnyObject, Workspace>(
        owning window: Window?,
        in workspaces: [CommandWorkspace<Window, Workspace>]
    ) -> Workspace? {
        guard let window else { return nil }
        return workspaces.first { $0.window === window }?.workspace
    }
}
