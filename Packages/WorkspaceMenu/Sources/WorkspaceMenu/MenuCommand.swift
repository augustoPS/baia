import Foundation

/// Every command baia's menu bar can issue.
///
/// One list drives three things that used to be written by hand and drifted:
/// the menu bar itself, the `keybind ... =unbind` lines handed to the surface
/// config, and menu validation. Drift is not visible at runtime.
/// `AppTerminalView.performKeyEquivalent` returns true for any key ghostty has
/// a binding for, so AppKit never consults the main menu and an item whose key
/// ghostty still owns works when clicked and does nothing from the keyboard.
/// ⌘Q and ⇧⌘P shipped that way once.
///
/// The `String` raw value is a command's stable written name, for the
/// diagnostics dump `copyDiagnostics` will render and for a later config file
/// that binds commands by name. Renaming a case changes that name, which is why
/// the `NSMenuItem.tag` round trip uses ``tag`` instead.
public enum MenuCommand: String, Sendable, Equatable, CaseIterable {
    case about
    case hide
    case hideOthers
    case showAll
    case quit

    case newWindow
    case newTab
    case closePane
    case closeTab
    case closeWindow
    case openConfiguration

    case copy
    case paste
    case pasteSelection
    case selectAll
    case findInPane

    case toggleSurfacePanels
    case resetSidebarSize
    case zoomPane
    case enterFullScreen

    case splitRight
    case splitDown
    case selectNextPane
    case selectPreviousPane
    case focusPaneLeft
    case focusPaneRight
    case focusPaneUp
    case focusPaneDown
    case growPaneLeft
    case growPaneRight
    case growPaneUp
    case growPaneDown
    case equalizePanes
    case setProjectDirectory
    case clearProjectDirectoryPin
    case revealAnchor
    case copyAnchorPath

    case commandPalette
    case reloadProjectList
    case refreshGitStatus

    case minimize
    case zoomWindow
    case showPreviousTab
    case showNextTab
    case mergeAllWindows
    case bringAllToFront

    case copyDiagnostics

    /// A stable integer that survives being stored in `NSMenuItem.tag`, so
    /// validation recovers the command without matching on a selector or a
    /// title. Selector matching is what `AppDelegate.validateMenuItem` does
    /// today, and it forces one `@objc` method per command.
    ///
    /// Written out per case rather than derived from `allCases.firstIndex`. An
    /// index-derived tag silently renumbers every command below an inserted
    /// case, so a tag quoted in a bug report or persisted anywhere would then
    /// name a different command.
    ///
    /// Numbering starts at 100 and steps by menu because `NSMenuItem.tag` is 0
    /// for every item and separator nobody tagged. 0 has to stay unclaimed for
    /// ``init(tag:)`` to reject an untagged item rather than resolve it to
    /// whichever command happened to sort first.
    public var tag: Int {
        switch self {
        case .about: 100
        case .hide: 101
        case .hideOthers: 102
        case .showAll: 103
        case .quit: 104

        case .newWindow: 200
        case .newTab: 201
        case .closePane: 202
        case .closeTab: 203
        case .closeWindow: 204
        case .openConfiguration: 205

        case .copy: 300
        case .paste: 301
        case .pasteSelection: 302
        case .selectAll: 303
        case .findInPane: 304

        // 400 is retired rather than reused. It was Status Bars, which went with
        // the footer it toggled, and handing the free integer to the next View
        // command would make a tag quoted in an older bug report name a different
        // item. The View group was never dense anyway: 403 and 404 sit above 401
        // because they were appended after the first three were written.
        case .toggleSurfacePanels: 403
        case .resetSidebarSize: 404
        case .zoomPane: 401
        case .enterFullScreen: 402

        case .splitRight: 500
        case .splitDown: 501
        case .selectNextPane: 502
        case .selectPreviousPane: 503
        case .focusPaneLeft: 504
        case .focusPaneRight: 505
        case .focusPaneUp: 506
        case .focusPaneDown: 507
        case .growPaneLeft: 508
        case .growPaneRight: 509
        case .growPaneUp: 510
        case .growPaneDown: 511
        case .equalizePanes: 512
        case .setProjectDirectory: 513
        case .clearProjectDirectoryPin: 514
        case .revealAnchor: 515
        case .copyAnchorPath: 516

        case .commandPalette: 600
        case .reloadProjectList: 601
        case .refreshGitStatus: 602

        case .minimize: 700
        case .zoomWindow: 701
        case .showPreviousTab: 702
        case .showNextTab: 703
        case .mergeAllWindows: 704
        case .bringAllToFront: 705

        case .copyDiagnostics: 800
        }
    }

    /// Nil for any integer no command claims, which covers the 0 AppKit leaves
    /// on an untagged item and on every separator.
    ///
    /// Searches ``tag`` over `allCases` rather than being written as a second
    /// switch. A hand-written inverse drifts, and two commands claiming one
    /// integer is invisible to the compiler either way. Searching turns that
    /// duplicate into a failed round trip, which a test can see.
    public init?(tag: Int) {
        guard let match = Self.allCases.first(where: { $0.tag == tag }) else { return nil }
        self = match
    }
}
