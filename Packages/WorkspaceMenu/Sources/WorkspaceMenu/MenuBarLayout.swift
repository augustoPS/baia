import Foundation

/// baia's whole menu bar, as data.
///
/// The app target reads this to build `NSMenu` objects, and
/// ``GhosttyDefaultKeybinds/unbindLines(for:)`` reads the same value to build the
/// surface config's `keybind` lines. One source is the point: the two lists were
/// written separately once, and a key the menu claimed while the config left it
/// bound was dead, with no error and no way to notice except clicking the item
/// and watching it work.
///
/// Titles carry an ellipsis only where the command asks for more input, so "Set
/// Project Directory…" opens a panel while "Open Configuration" does not.
public enum MenuBarLayout {
    public static var menus: [MenuDescriptor] {
        [
            appMenu(), fileMenu(), editMenu(), viewMenu(),
            paneMenu(), projectMenu(), windowMenu(), helpMenu(),
        ]
    }

    /// AppKit takes the first menu's title from the bundle and ignores whatever is
    /// set here, so "baia" is documentation rather than something rendered.
    ///
    /// ⌘H is the control in the recorded diagnostic: it worked while ⌘Q did
    /// nothing at all, which is what pointed at ghostty swallowing the key rather
    /// than at the menu being built wrong. Ghostty binds neither `super+h` nor
    /// `super+alt+h`, and it does bind `super+q`.
    private static func appMenu() -> MenuDescriptor {
        MenuDescriptor(
            title: "baia",
            role: .app,
            items: [
                item(.about, "About baia", .noConflict),
                item(
                    .hide, "Hide baia", .character("h"), .command, .noConflict,
                    separatorBefore: true
                ),
                item(.hideOthers, "Hide Others", .character("h"), [.command, .option], .noConflict),
                item(.showAll, "Show All", .noConflict),
                item(
                    .quit, "Quit baia", .character("q"), .command, .unbind,
                    separatorBefore: true
                ),
            ]
        )
    }

    /// ⌘W closes the pane rather than the tab, which is the assignment the owner
    /// relies on and deliberately does not redeclare in his own ghostty config.
    /// ⌥⌘W and ⇧⌘W take the tab and the window, matching ghostty's own
    /// `close_tab:this` and `close_window` so the muscle memory carries over.
    private static func fileMenu() -> MenuDescriptor {
        MenuDescriptor(
            title: "File",
            role: .standard,
            items: [
                item(.newWindow, "New Window", .character("n"), .command, .unbind),
                item(.newTab, "New Tab", .character("t"), .command, .unbind),
                item(
                    .closePane, "Close Pane", .character("w"), .command, .unbind,
                    separatorBefore: true
                ),
                item(.closeTab, "Close Tab", .character("w"), [.command, .option], .unbind),
                item(.closeWindow, "Close Window", .character("w"), [.command, .shift], .unbind),
                item(
                    .openConfiguration, "Settings…", .character(","), .command, .unbind,
                    separatorBefore: true
                ),
            ]
        )
    }

    /// Every item here defers to ghostty, and each one names why, because a reader
    /// auditing this table for missing unbind lines finds this menu first and the
    /// correct action is to leave it alone.
    private static func editMenu() -> MenuDescriptor {
        MenuDescriptor(
            title: "Edit",
            role: .standard,
            items: [
                item(
                    .copy, "Copy", .character("c"), .command,
                    .deferToGhostty(
                        reason: """
                        Ghostty's copy_to_clipboard:mixed copies the surface's own \
                        selection, which the Swift layer cannot read at all: \
                        readViewportText() exists only on InMemoryTerminalSession, \
                        never for an .exec pane. The menu item still reaches the \
                        terminal because AppTerminalView implements copy: as an \
                        IBAction on the responder chain.
                        """
                    )
                ),
                item(
                    .paste, "Paste", .character("v"), .command,
                    .deferToGhostty(
                        reason: """
                        paste_from_clipboard writes into the PTY, and nothing in the \
                        Swift layer can inject text into an .exec surface. \
                        AppTerminalView's paste: IBAction is what the menu item \
                        drives, so the item and the key end in the same place.
                        """
                    )
                ),
                item(
                    .pasteSelection, "Paste from Selection", .character("v"), [.command, .shift],
                    .deferToGhostty(
                        reason: """
                        paste_from_selection reads the X11-style selection clipboard, \
                        which has no AppKit equivalent, so unbinding ⇧⌘V would lose \
                        the action outright rather than move it to the menu.
                        """
                    )
                ),
                item(
                    .selectAll, "Select All", .character("a"), .command,
                    .deferToGhostty(
                        reason: """
                        select_all moves the surface's selection state, which lives \
                        inside libghostty. AppTerminalView implements selectAll: as \
                        an IBAction, so the item and the key agree.
                        """
                    ),
                    separatorBefore: true
                ),
                // The one Edit item that does not defer. Ghostty binds `super+f`
                // to `start_search`, whose search bar the host application is
                // expected to draw; the trimmed libghostty-spm has no search
                // anywhere in its Swift layer, so the key opens nothing and
                // deferring to it would be deferring to an action that does not
                // exist. Unbinding is what makes ⌘F reach the menu at all.
                item(.findInPane, "Find…", .character("f"), .command, .unbind,
                     separatorBefore: true),
            ]
        )
    }

    /// Ghostty's defaults bind `super+ctrl+f` and `super+enter` to the same
    /// `toggle_fullscreen`, and only the one baia's menu claims is unbound. ⌘↩ is
    /// left alone because no item claims it, not because it is known to work: the
    /// bridge drops most window-level actions, so it has to be tried by hand in
    /// the running app before anything is said about it.
    ///
    /// Status Bars carries no key equivalent. Every free single-letter ⌘ key is
    /// spoken for by a command used far more often, and a two-modifier shortcut
    /// for a preference nobody toggles twice a day earns nothing.
    private static func viewMenu() -> MenuDescriptor {
        MenuDescriptor(
            title: "View",
            role: .standard,
            items: [
                item(.toggleStatusBars, "Status Bars", .noConflict),
                // ⌥⌘S, added 2026-07-29 after the sidebar became something to
                // reach for rather than something to compare. Two modifiers
                // rather than a bare ⌘S: the doctrine above still holds, and a
                // four-state cycle is not a several-times-an-hour command. `s`
                // is claimed nowhere else in this menu bar.
                //
                // `.noConflict` rather than `.unbind`, which was the first
                // spelling and which `GhosttyDefaultKeybindsTests` rejected on
                // the spot: ghostty binds no `super+alt+s`, so an unbind line
                // would name a trigger that does not exist there. Unbinding is
                // for keys ghostty would otherwise swallow, not for every key
                // this menu claims.
                item(
                    .toggleSurfacePanels, "Switch Sidebar", .character("s"),
                    [.command, .option], .noConflict
                ),
                item(.resetSidebarSize, "Reset Sidebar Size", .noConflict),
                item(.zoomPane, "Zoom Pane", .returnKey, [.command, .shift], .unbind),
                item(
                    .enterFullScreen, "Enter Full Screen", .character("f"), [.command, .control],
                    .unbind,
                    separatorBefore: true
                ),
            ]
        )
    }

    /// ⌘D, ⇧⌘D and ⌥⌘arrows are fixed: they are the keys the owner's own ghostty
    /// config names as the ones he relies on and deliberately does not redeclare.
    /// Ghostty binds all of them, to `new_split` and `goto_split`, whose actions
    /// the Swift bridge drops in its default branch because
    /// `TerminalSurface.rawValue` is internal. So today they fire nothing.
    private static func paneMenu() -> MenuDescriptor {
        MenuDescriptor(
            title: "Pane",
            role: .standard,
            items: [
                item(.splitRight, "Split Right", .character("d"), .command, .unbind),
                item(.splitDown, "Split Down", .character("d"), [.command, .shift], .unbind),
                item(
                    .selectPreviousPane, "Select Previous Pane", .character("["), .command, .unbind,
                    separatorBefore: true
                ),
                item(.selectNextPane, "Select Next Pane", .character("]"), .command, .unbind),
                item(
                    .focusPaneLeft, "Focus Pane Left", .arrowLeft, [.command, .option], .unbind,
                    separatorBefore: true
                ),
                item(.focusPaneRight, "Focus Pane Right", .arrowRight, [.command, .option], .unbind),
                item(.focusPaneUp, "Focus Pane Up", .arrowUp, [.command, .option], .unbind),
                item(.focusPaneDown, "Focus Pane Down", .arrowDown, [.command, .option], .unbind),
                item(
                    .growPaneLeft, "Grow Pane Left", .arrowLeft, [.command, .control], .unbind,
                    separatorBefore: true
                ),
                item(.growPaneRight, "Grow Pane Right", .arrowRight, [.command, .control], .unbind),
                item(.growPaneUp, "Grow Pane Up", .arrowUp, [.command, .control], .unbind),
                item(.growPaneDown, "Grow Pane Down", .arrowDown, [.command, .control], .unbind),
                item(.equalizePanes, "Equalize Panes", .character("="), [.command, .control], .unbind),
                item(
                    .setProjectDirectory, "Set Project Directory…", .character("p"),
                    [.command, .shift], .unbind,
                    separatorBefore: true
                ),
                item(.clearProjectDirectoryPin, "Clear Pin", .noConflict),
                item(
                    .revealAnchor, "Reveal Anchor in Finder", .character("r"), [.command, .shift],
                    .noConflict
                ),
                item(.copyAnchorPath, "Copy Anchor Path", .noConflict),
            ]
        )
    }

    /// ⌘K takes ghostty's `clear_screen`, which is a real loss and an accepted
    /// one: the palette is the entry point for every project and worktree, while
    /// clearing the screen already has `clear` and ⌃L.
    private static func projectMenu() -> MenuDescriptor {
        MenuDescriptor(
            title: "Project",
            role: .standard,
            items: [
                item(.commandPalette, "Command Palette…", .character("k"), .command, .unbind),
                item(.reloadProjectList, "Reload Project List", .noConflict, separatorBefore: true),
                item(.refreshGitStatus, "Refresh Git Status", .character("r"), .command, .noConflict),
            ]
        )
    }

    /// Assigned to `NSApplication.windowsMenu` by the app target, which is what
    /// makes AppKit list open windows and native tabs underneath these items. ⌘M
    /// is baia's because ghostty does not bind `super+m` at all, while
    /// `super+shift+[` and `super+shift+]` go to tab actions the bridge drops.
    private static func windowMenu() -> MenuDescriptor {
        MenuDescriptor(
            title: "Window",
            role: .windows,
            items: [
                item(.minimize, "Minimize", .character("m"), .command, .noConflict),
                item(.zoomWindow, "Zoom", .noConflict),
                item(
                    .showPreviousTab, "Show Previous Tab", .character("["), [.command, .shift],
                    .unbind,
                    separatorBefore: true
                ),
                item(.showNextTab, "Show Next Tab", .character("]"), [.command, .shift], .unbind),
                item(.mergeAllWindows, "Merge All Windows", .noConflict, separatorBefore: true),
                item(.bringAllToFront, "Bring All to Front", .noConflict),
            ]
        )
    }

    /// Assigned to `NSApplication.helpMenu`, so AppKit puts its search field here
    /// rather than guessing at a menu titled "Help".
    private static func helpMenu() -> MenuDescriptor {
        MenuDescriptor(
            title: "Help",
            role: .help,
            items: [
                item(.copyDiagnostics, "Copy Diagnostics", .noConflict),
            ]
        )
    }

    /// Shorthand for an item with a key equivalent, so the menus above read as a
    /// table.
    ///
    /// The arguments are positional on purpose: command, title, key, modifiers,
    /// policy, in that order every time. Forty-five fully labelled
    /// ``MenuItemDescriptor`` initializers wrap to six lines each, and a
    /// mis-transcribed key is far easier to spot in a column than in a paragraph.
    /// `separatorBefore` keeps its label, because most items do not open a group
    /// and an unlabelled trailing `false` would say nothing.
    private static func item(
        _ command: MenuCommand,
        _ title: String,
        _ key: MenuKey,
        _ modifiers: MenuModifiers,
        _ policy: GhosttyPolicy,
        separatorBefore: Bool = false
    ) -> MenuItemDescriptor {
        MenuItemDescriptor(
            command: command,
            title: title,
            shortcut: MenuShortcut(key: key, modifiers: modifiers),
            policy: policy,
            isSeparatorBefore: separatorBefore
        )
    }

    /// Shorthand for an item with no key equivalent. A separate overload rather
    /// than a `MenuKey?` and an empty modifier set, because `nil, []` on fourteen
    /// rows is noise that a reader has to check every time and skip every time.
    private static func item(
        _ command: MenuCommand,
        _ title: String,
        _ policy: GhosttyPolicy,
        separatorBefore: Bool = false
    ) -> MenuItemDescriptor {
        MenuItemDescriptor(
            command: command,
            title: title,
            shortcut: nil,
            policy: policy,
            isSeparatorBefore: separatorBefore
        )
    }
}
