import AppKit
import WorkspaceMenu

/// The menu bar, built in code because baia has no nib: main.swift owns the
/// entry point.
///
/// Every title, shortcut and ordering decision lives in `MenuBarLayout`, and the
/// same value produces the ghostty unbind lines in `TerminalPaneController`.
/// Keeping one source is the point: the menu and the unbind list were two
/// hand-maintained lists once, and a key the menu claimed while the surface
/// config left it bound was dead, with no error and no way to notice except
/// clicking the item and watching it work.
@MainActor
enum MainMenu {
    static func install(into app: NSApplication) {
        let bar = NSMenu()
        for descriptor in MenuBarLayout.menus {
            let item = NSMenuItem()
            item.title = descriptor.title
            let menu = NSMenu(title: descriptor.title)
            for entry in descriptor.items {
                if entry.isSeparatorBefore { menu.addItem(.separator()) }
                menu.addItem(makeItem(entry))
            }
            item.submenu = menu
            bar.addItem(item)

            // AppKit populates these itself once it knows which menu is which.
            // The Window menu in particular grows the tab commands only after
            // being named, so window tabbing looks broken without this.
            switch descriptor.role {
            case .windows: app.windowsMenu = menu
            case .services: app.servicesMenu = menu
            case .help: app.helpMenu = menu
            case .app, .standard: break
            }
        }
        app.mainMenu = bar
    }

    private static func makeItem(_ entry: MenuItemDescriptor) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = entry.title
        // The tag is how validation recovers the command. A selector cannot
        // serve, because several commands share one selector shape, and matching
        // on the title would break the moment a title changed.
        item.tag = entry.command.tag
        item.action = MenuCommandSelectors.selector(for: entry.command)
        // A nil target sends the action down the responder chain to whoever
        // implements it, which is what lets the terminal answer copy and paste
        // while the app delegate answers the pane commands.
        item.target = nil
        if let shortcut = entry.shortcut {
            item.keyEquivalent = shortcut.key.appKitCharacter
            item.keyEquivalentModifierMask = modifierFlags(shortcut.modifiers)
        }
        return item
    }

    private static func modifierFlags(_ modifiers: MenuModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }
}
