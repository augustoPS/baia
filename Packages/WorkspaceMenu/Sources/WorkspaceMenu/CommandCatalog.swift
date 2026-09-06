import Foundation

public enum CommandTarget: Sendable, Equatable {
    case application
    case workspace
    case responder
}

public struct CommandCatalogEntry: Sendable, Equatable {
    public let command: MenuCommand
    public let state: MenuItemState
    public let target: CommandTarget
    public let isOfferedInPalette: Bool
}

public enum CommandDispatchRefusal: Sendable, Equatable {
    case unavailable(String)
    case unsupported
    case missingTarget
    case targetRefused
}

public enum CommandDispatchResult: Sendable, Equatable {
    case performed
    case refused(CommandDispatchRefusal)
}

/// The shared catalog used to derive menu validation, palette rows, and the
/// target contract checked immediately before palette execution.
public enum CommandCatalog {
    public static func entry(
        for command: MenuCommand,
        given availability: MenuAvailability
    ) -> CommandCatalogEntry {
        CommandCatalogEntry(
            command: command,
            state: MenuValidation.state(for: command, given: availability),
            target: target(for: command),
            // AppKit has no X11-style selection clipboard. Keep its ghostty
            // key policy untouched and do not advertise an invented app action.
            isOfferedInPalette: command != .pasteSelection
        )
    }

    public static func entries(given availability: MenuAvailability) -> [CommandCatalogEntry] {
        MenuCommand.allCases.map { entry(for: $0, given: availability) }
    }

    /// Runs only a command the catalog says is available, implemented, and has
    /// a live target. A false action result is an explicit refusal, never an
    /// execution claim.
    public static func dispatch(
        _ entry: CommandCatalogEntry,
        actionIsSupported: Bool,
        targetIsValid: Bool,
        perform: (MenuCommand) -> Bool
    ) -> CommandDispatchResult {
        if let refusal = refusal(
            for: entry,
            actionIsSupported: actionIsSupported,
            targetIsValid: targetIsValid
        ) {
            return .refused(refusal)
        }
        return perform(entry.command) ? .performed : .refused(.targetRefused)
    }

    /// The same checks as ``dispatch(_:actionIsSupported:targetIsValid:perform:)``
    /// without calling the target. A palette uses this before dismissing, then
    /// dispatches after its captured workspace regains key status.
    public static func refusal(
        for entry: CommandCatalogEntry,
        actionIsSupported: Bool,
        targetIsValid: Bool
    ) -> CommandDispatchRefusal? {
        guard entry.state.isEnabled else {
            return .unavailable(entry.state.unavailableReason ?? "unavailable")
        }
        guard actionIsSupported else { return .unsupported }
        guard targetIsValid else { return .missingTarget }
        return nil
    }

    /// Exhaustive by design: adding a command requires deciding who executes it.
    private static func target(for command: MenuCommand) -> CommandTarget {
        switch command {
        case .about, .hide, .hideOthers, .showAll, .quit,
             .newWindow, .openConfiguration,
             .commandPalette, .reloadProjectList, .resetSidebarSize,
             .bringAllToFront, .copyDiagnostics:
            .application

        case .closePane, .closeTab, .closeWindow, .findInPane,
             .toggleSurfacePanels, .zoomPane, .enterFullScreen,
             .splitRight, .splitDown, .selectNextPane, .selectPreviousPane,
             .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
             .newTab, .growPaneLeft, .growPaneRight, .growPaneUp, .growPaneDown,
             .equalizePanes, .setProjectDirectory, .clearProjectDirectoryPin,
             .revealAnchor, .copyAnchorPath, .refreshGitStatus,
             .minimize, .zoomWindow, .showPreviousTab, .showNextTab,
             .mergeAllWindows:
            .workspace

        case .undo, .redo, .cut, .copy, .paste, .pasteSelection, .selectAll:
            .responder
        }
    }
}
