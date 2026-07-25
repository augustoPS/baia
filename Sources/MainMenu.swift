import AppKit

/// The menu bar, built in code because baia has no nib: main.swift owns the
/// entry point. Also the fix for the app having no ⌘Q at all, which made
/// closing the window the only way out.
@MainActor
enum MainMenu {
    static func install(into app: NSApplication) {
        let bar = NSMenu()
        bar.addItem(appMenu())
        bar.addItem(editMenu())
        bar.addItem(paneMenu())
        app.mainMenu = bar
    }

    /// The first menu takes the app name from the bundle, so its title is unused.
    private static func appMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(
            withTitle: "About baia",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Hide baia",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit baia",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.submenu = menu
        return item
    }

    /// AppTerminalView implements copy:, paste: and selectAll: as IBActions, so
    /// responder-chain dispatch reaches the terminal. Unrelated to the OSC 52
    /// denials in TerminalPaneController, which gate terminal-driven clipboard
    /// access rather than the user's own copy and paste.
    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        item.submenu = menu
        return item
    }

    /// Both actions have a nil target, so they travel the responder chain to the
    /// app delegate, which also validates them.
    private static func paneMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Pane", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Pane")
        let set = NSMenuItem(
            title: "Set Project Directory…",
            action: #selector(AppDelegate.setProjectDirectory(_:)),
            keyEquivalent: "P"
        )
        set.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(set)
        menu.addItem(
            NSMenuItem(
                title: "Clear Pin",
                action: #selector(AppDelegate.clearProjectDirectoryPin(_:)),
                keyEquivalent: ""
            )
        )
        item.submenu = menu
        return item
    }
}
