import AppKit
import WorkspaceMenu

/// Maps a command to the selector that performs it.
///
/// Returning nil is the intended degradation for a command whose feature has not
/// landed. AppKit disables a menu item whose selector nothing in the responder
/// chain implements, so an unimplemented command shows greyed out rather than
/// looking live and silently doing nothing when chosen. That greying happens
/// before `validateMenuItem` runs, so `MenuValidation` never sees these.
@MainActor
extension CommandCatalog {
    static func selector(for command: MenuCommand) -> Selector? {
        switch command {
        case .about: #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        case .hide: #selector(NSApplication.hide(_:))
        case .hideOthers: #selector(NSApplication.hideOtherApplications(_:))
        case .showAll: #selector(NSApplication.unhideAllApplications(_:))
        case .quit: #selector(NSApplication.terminate(_:))

        case .newWindow: #selector(AppDelegate.newWorkspaceWindow(_:))
        case .newTab: #selector(AppDelegate.newTab(_:))
        case .closePane: #selector(AppDelegate.closePane(_:))
        case .closeTab: #selector(AppDelegate.closeTab(_:))
        case .closeWindow: #selector(NSWindow.performClose(_:))
        case .openConfiguration: #selector(AppDelegate.showSettings(_:))

        // The standard responder-chain selectors. `undo:` and `redo:` are not
        // declared on any AppKit class Swift can name, so they are spelled as
        // strings; NSWindow forwards both to its `undoManager`, which is how
        // the Settings window's transaction undo is reached, and a text view
        // answers them itself while it is editing.
        case .undo: Selector(("undo:"))
        case .redo: Selector(("redo:"))
        case .cut: #selector(NSText.cut(_:))
        // Ghostty implements these inside the surface and they reach it through
        // the responder chain via its own IBActions, which is why the menu keeps
        // their keys bound rather than unbinding them.
        case .copy: #selector(NSText.copy(_:))
        case .paste: #selector(NSText.paste(_:))
        case .pasteSelection: nil as Selector?
        case .selectAll: #selector(NSText.selectAll(_:))
        // On the delegate rather than on the responder chain, because the panel
        // is a window of the app's rather than a view of the pane's: nothing
        // inside a pane may take first responder, so nothing inside a pane can
        // be the thing that opens it.
        case .findInPane: #selector(AppDelegate.findInPane(_:))

        case .toggleSurfacePanels: #selector(AppDelegate.toggleSurfacePanels(_:))
        case .resetSidebarSize: #selector(AppDelegate.resetSidebarSize(_:))
        case .zoomPane: #selector(AppDelegate.zoomPane(_:))
        case .enterFullScreen: #selector(NSWindow.toggleFullScreen(_:))

        case .splitRight: #selector(AppDelegate.splitPaneRight(_:))
        case .splitDown: #selector(AppDelegate.splitPaneDown(_:))
        case .selectNextPane: #selector(AppDelegate.selectNextPane(_:))
        case .selectPreviousPane: #selector(AppDelegate.selectPreviousPane(_:))
        case .focusPaneLeft: #selector(AppDelegate.focusPaneLeft(_:))
        case .focusPaneRight: #selector(AppDelegate.focusPaneRight(_:))
        case .focusPaneUp: #selector(AppDelegate.focusPaneUp(_:))
        case .focusPaneDown: #selector(AppDelegate.focusPaneDown(_:))
        // Non-nil is what makes `MenuValidation` reachable for these at all: an
        // item whose action is nil is disabled by AppKit before validation runs,
        // and a disabled item still answers `performKeyEquivalent` with true, so
        // ⌃⌘arrows and ⌃⌘= were swallowed rather than reaching the terminal while
        // `MenuBarLayout` unbound them from ghostty. They were dead keys.
        case .growPaneLeft: #selector(AppDelegate.growPaneLeft(_:))
        case .growPaneRight: #selector(AppDelegate.growPaneRight(_:))
        case .growPaneUp: #selector(AppDelegate.growPaneUp(_:))
        case .growPaneDown: #selector(AppDelegate.growPaneDown(_:))
        case .equalizePanes: #selector(AppDelegate.equalizePanes(_:))

        case .setProjectDirectory: #selector(AppDelegate.setProjectDirectory(_:))
        case .clearProjectDirectoryPin: #selector(AppDelegate.clearProjectDirectoryPin(_:))
        case .revealAnchor: #selector(AppDelegate.revealAnchor(_:))
        case .copyAnchorPath: #selector(AppDelegate.copyAnchorPath(_:))

        case .commandPalette: #selector(AppDelegate.showCommandPalette(_:))
        case .reloadProjectList: #selector(AppDelegate.reloadProjectList(_:))
        case .refreshGitStatus: #selector(AppDelegate.refreshGitStatus(_:))

        case .minimize: #selector(NSWindow.performMiniaturize(_:))
        case .zoomWindow: #selector(NSWindow.performZoom(_:))
        // AppKit implements tab selection and merging on NSWindow itself, so
        // these reach the key window through the responder chain and behave
        // exactly as they do in every other tabbed Mac app.
        case .showPreviousTab: #selector(NSWindow.selectPreviousTab(_:))
        case .showNextTab: #selector(NSWindow.selectNextTab(_:))
        case .mergeAllWindows: #selector(NSWindow.mergeAllWindows(_:))
        case .bringAllToFront: #selector(NSApplication.arrangeInFront(_:))

        case .copyDiagnostics: #selector(AppDelegate.copyDiagnostics(_:))
        }
    }
}
