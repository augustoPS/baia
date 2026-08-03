import Foundation
import Testing

@testable import WorkspaceMenu

@Suite struct MenuBarLayoutTests {
    @Test func everyMenuCommandAppearsInExactlyOneMenuItem() {
        // Catches both directions at once: a command added to the enum and never
        // surfaced, which is an action with no way to reach it, and a command
        // pasted into two menus, which gives one command two tags' worth of
        // validation and two places to edit when its title changes.
        let commands = MenuBarLayout.menus.flatMap(\.items).map(\.command)

        #expect(Set(commands).count == commands.count)
        #expect(Set(commands) == Set(MenuCommand.allCases))
    }

    @Test func noTwoItemsShareAKeyEquivalent() {
        // AppKit resolves a key equivalent by walking the menu bar and taking the
        // first match, so a duplicate is not an error: one of the two items simply
        // never fires and the menu looks entirely correct. The modifier mask and
        // the AppKit scalar have to be compared together, because ⌘[ and ⇧⌘[ are
        // both in this table and differ in nothing else.
        let equivalents = MenuBarLayout.menus
            .flatMap(\.items)
            .compactMap(\.shortcut)
            .map { "\($0.modifiers.rawValue):\($0.key.appKitCharacter)" }

        #expect(Set(equivalents).count == equivalents.count)
    }

    @Test func everyItemDeclaringUnbindCarriesAShortcut() {
        // An unbind policy with no key equivalent contributes no line, so it
        // claims nothing from ghostty and reads in the table as though it does.
        let unbound = MenuBarLayout.menus.flatMap(\.items).filter { $0.policy == .unbind }

        #expect(!unbound.isEmpty)
        #expect(unbound.allSatisfy { $0.shortcut != nil })
    }

    @Test func everyDeferralCarriesANonEmptyReason() {
        // The reason is what stops a later reader auditing the table for missing
        // unbind lines from "fixing" the Edit menu and losing copy, paste and
        // select-all inside the surface. An empty string satisfies the type and
        // says nothing.
        for item in MenuBarLayout.menus.flatMap(\.items) {
            if case let .deferToGhostty(reason) = item.policy {
                #expect(!reason.isEmpty)
            }
        }
    }

    @Test func onlyTheFirstMenuTakesTheAppRoleAndTheSpecialSlotsAreClaimedOnce() {
        // AppKit assigns windowsMenu and helpMenu on NSApplication, so two menus
        // claiming one role would leave the app target picking whichever it saw
        // last, silently, and native window tabs would list under the wrong menu.
        let roles = MenuBarLayout.menus.map(\.role)

        #expect(roles.first == .app)
        #expect(roles.filter { $0 == .app }.count == 1)
        #expect(roles.filter { $0 == .windows }.count == 1)
        #expect(roles.filter { $0 == .help }.count == 1)
    }

    @Test func theKeysTheOwnerReliesOnKeepTheirAssignments() {
        // These six are named in a standing comment in the owner's own ghostty
        // config as the keys he relies on and deliberately does not redeclare, so
        // they are fixed rather than chosen here. Nothing else in this suite would
        // notice them being swapped: any internally consistent reassignment still
        // has one item per command, no duplicate equivalents, and a correct unbind
        // line for whatever it landed on.
        var shortcuts: [MenuCommand: MenuShortcut] = [:]
        for item in MenuBarLayout.menus.flatMap(\.items) {
            if let shortcut = item.shortcut { shortcuts[item.command] = shortcut }
        }

        #expect(shortcuts[.splitRight] == chord(.character("d"), .command))
        #expect(shortcuts[.splitDown] == chord(.character("d"), [.command, .shift]))
        #expect(shortcuts[.zoomPane] == chord(.returnKey, [.command, .shift]))
        #expect(shortcuts[.focusPaneLeft] == chord(.arrowLeft, [.command, .option]))
        #expect(shortcuts[.focusPaneRight] == chord(.arrowRight, [.command, .option]))
        #expect(shortcuts[.focusPaneUp] == chord(.arrowUp, [.command, .option]))
        #expect(shortcuts[.focusPaneDown] == chord(.arrowDown, [.command, .option]))
        #expect(shortcuts[.newTab] == chord(.character("t"), .command))
        #expect(shortcuts[.closePane] == chord(.character("w"), .command))
    }

    /// The expectations above read as a table of assignments only at this width,
    /// and the table is the point: a swapped pair of keys is visible in a column
    /// and invisible in nine wrapped initializers.
    private func chord(_ key: MenuKey, _ modifiers: MenuModifiers) -> MenuShortcut {
        MenuShortcut(key: key, modifiers: modifiers)
    }

    @Test func noMenuOpensWithASeparator() {
        // A leading separator renders as a blank first row in AppKit rather than
        // being dropped, and isSeparatorBefore on the first item is the easy way
        // to introduce one while moving items between groups.
        for menu in MenuBarLayout.menus {
            #expect(menu.items.first?.isSeparatorBefore == false)
        }
    }
}

/// The lookups the command palette's verb mode reads, which are derived from the
/// same tree the menu bar is built from rather than from a table beside it.
@Suite struct MenuBarLayoutLookupTests {
    @Test func findsTheItemForACommandInTheBar() {
        #expect(MenuBarLayout.title(of: .openConfiguration) == "Settings…")
        #expect(MenuBarLayout.title(of: .equalizePanes) == "Equalize Panes")
    }

    /// Derived from the tree, so a rename reaches the palette with no second
    /// place to update. Asserted by comparing against the tree itself rather
    /// than against a copied literal, which would be the very duplication the
    /// lookup exists to avoid.
    @Test func theTitleIsTheOneTheMenuTreeCarries() {
        for menu in MenuBarLayout.menus {
            for item in menu.items {
                #expect(MenuBarLayout.title(of: item.command) == item.title)
            }
        }
    }

    /// Every command in the bar is reachable by the lookup. A command the walk
    /// cannot find would be a verb the palette silently never offers.
    @Test func everyCommandInTheBarIsFound() {
        for menu in MenuBarLayout.menus {
            for item in menu.items {
                #expect(MenuBarLayout.item(for: item.command) != nil)
            }
        }
    }

    @Test func aCommandWithNoShortcutHasNoShortcutText() {
        #expect(MenuBarLayout.shortcutText(of: .showAll) == nil)
    }

    @Test func aShortcutDrawsInTheOrderAMenuUses() {
        #expect(MenuBarLayout.shortcutText(of: .openConfiguration) == "⌘,")
    }
}
