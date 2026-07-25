import Foundation
import Testing

@testable import WorkspaceMenu

@Suite struct GhosttyDefaultKeybindsTests {
    @Test func theTableHoldsEveryTriggerGhosttyListed() {
        // `ghostty +list-keybinds --default` printed 93 lines at 1.3.1 and no two
        // named the same trigger. A line dropped while editing the set turns a
        // real conflict into a noConflict that every other test here accepts, so
        // the count is the only guard against a partial transcription.
        #expect(GhosttyDefaultKeybinds.triggers.count == 93)
        #expect(GhosttyDefaultKeybinds.ghosttyVersion == "1.3.1")
    }

    @Test func everyItemDeclaringUnbindHasAtLeastOneTriggerInTheGhosttyDefaultTable() {
        // An item claiming a key ghostty never bound means the table is stale or
        // the trigger name is misspelled, and a misspelled trigger is a keybind
        // line ghostty accepts and acts on in no way at all. "at least one"
        // because a digit contributes two names and both are bound.
        for item in MenuBarLayout.menus.flatMap(\.items) where item.policy == .unbind {
            guard let shortcut = item.shortcut else { continue }
            let bound = shortcut.ghosttyTriggers.filter { GhosttyDefaultKeybinds.triggers.contains($0) }
            #expect(!bound.isEmpty)
        }
    }

    @Test func everyItemDeclaringNoConflictHasNoTriggerInTheGhosttyDefaultTable() {
        // The ⌘Q case exactly: a menu key ghostty binds and baia does not unbind
        // does nothing, with no error, because performKeyEquivalent turns it into
        // a surface keyDown and returns true before AppKit consults the menu. ⌘M,
        // ⌘R, ⇧⌘R, ⌘H and ⌥⌘H are claimed with no unbind line, and this is what
        // holds that claim to the real table.
        for item in MenuBarLayout.menus.flatMap(\.items) where item.policy == .noConflict {
            guard let shortcut = item.shortcut else { continue }
            for trigger in shortcut.ghosttyTriggers {
                #expect(!GhosttyDefaultKeybinds.triggers.contains(trigger))
            }
        }
    }

    @Test func everyItemDeferringToGhosttyIsBoundByGhostty() {
        // The third direction, and the one with no menu-visible symptom: deferring
        // to ghostty for a key ghostty does not bind means neither side handles
        // it. Every Edit item is here, and all four keys are in the default table.
        for item in MenuBarLayout.menus.flatMap(\.items) {
            guard case .deferToGhostty = item.policy, let shortcut = item.shortcut else { continue }
            for trigger in shortcut.ghosttyTriggers {
                #expect(GhosttyDefaultKeybinds.triggers.contains(trigger))
            }
        }
    }

    @Test func theStandingControlTabUnbindsAreEmitted() {
        // These have no menu item, so nothing else in the suite would notice them
        // missing. Ghostty binds them to next_tab and previous_tab, whose
        // callbacks TerminalCallbackBridge drops in its default branch, so the
        // keys do nothing and the surface still swallows them from a TUI that
        // wants ⌃Tab. Both names are checked against the real table, because a
        // typo here is a line that unbinds nothing.
        let lines = GhosttyDefaultKeybinds.unbindLines(for: MenuBarLayout.menus)

        #expect(lines.contains("ctrl+tab=unbind"))
        #expect(lines.contains("ctrl+shift+tab=unbind"))
        #expect(GhosttyDefaultKeybinds.triggers.contains("ctrl+tab"))
        #expect(GhosttyDefaultKeybinds.triggers.contains("ctrl+shift+tab"))
    }

    @Test func unbindLinesAreSortedAndUnique() {
        // Sorted so the surface config is stable run to run and a diff of it names
        // only real changes; the guard is against someone replacing the set with
        // an append-as-you-go array. Unique because ghostty accepts a duplicate
        // keybind line silently, which would hide the key collision that
        // noTwoItemsShareAKeyEquivalent exists to find.
        let lines = GhosttyDefaultKeybinds.unbindLines(for: MenuBarLayout.menus)

        #expect(lines == lines.sorted())
        #expect(Set(lines).count == lines.count)
    }

    @Test func everyEmittedLineNamesATriggerGhosttyActuallyBinds() {
        // The end-to-end form of the per-item checks, over the strings the surface
        // config really receives. A line whose trigger is not in the default table
        // takes nothing away, and the key it was written for stays dead.
        for line in GhosttyDefaultKeybinds.unbindLines(for: MenuBarLayout.menus) {
            let trigger = String(line.dropLast("=unbind".count))
            #expect(line.hasSuffix("=unbind"))
            #expect(GhosttyDefaultKeybinds.triggers.contains(trigger))
        }
    }

    @Test func noLineIsEmittedForAKeyGhosttyShouldKeep() {
        // The Edit menu's four keys are bound by ghostty and deliberately left
        // alone, so they are the case that would break if unbindLines stopped
        // reading the policy and emitted a line for every shortcut it saw.
        let lines = GhosttyDefaultKeybinds.unbindLines(for: MenuBarLayout.menus)

        for trigger in ["super+c", "super+v", "super+shift+v", "super+a"] {
            #expect(!lines.contains("\(trigger)=unbind"))
        }
    }

    @Test func unbindLinesForNoMenusAreJustTheStandingOnes() {
        // The standing pair does not come from the menus, so an empty layout still
        // has to produce them. Passing the real menus would hide a bug where they
        // were derived from an item that happens to exist.
        let standing = ["ctrl+shift+tab=unbind", "ctrl+tab=unbind"]
        #expect(GhosttyDefaultKeybinds.unbindLines(for: []) == standing)
    }
}
