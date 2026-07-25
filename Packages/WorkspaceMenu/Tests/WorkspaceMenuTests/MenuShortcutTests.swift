import Foundation
import Testing

@testable import WorkspaceMenu

@Suite struct MenuShortcutTests {
    @Test func aCommandDigitKeyEmitsBothTheCharacterAndTheDigitForm() {
        // Ghostty's defaults bind super+1 and super+digit_1 separately, both to
        // goto_tab:1. Returning one name leaves the other live, and a live
        // trigger is a key the surface keeps swallowing. Both forms are asserted
        // against the transcribed table so this cannot pass on invented names.
        let shortcut = MenuShortcut(key: .digit(1), modifiers: .command)

        #expect(shortcut.ghosttyTriggers == ["super+1", "super+digit_1"])
        #expect(GhosttyDefaultKeybinds.triggers.contains("super+1"))
        #expect(GhosttyDefaultKeybinds.triggers.contains("super+digit_1"))
    }

    @Test func arrowKeysEmitThePrivateUseScalarsAppKitExpects() {
        // These are NSUpArrowFunctionKey and its siblings, copied by value
        // because the package must not import AppKit. A wrong scalar gives a menu
        // item a key equivalent nothing on the keyboard produces, and the item
        // then looks bound and never fires.
        #expect(MenuKey.arrowUp.appKitCharacter == "\u{F700}")
        #expect(MenuKey.arrowDown.appKitCharacter == "\u{F701}")
        #expect(MenuKey.arrowLeft.appKitCharacter == "\u{F702}")
        #expect(MenuKey.arrowRight.appKitCharacter == "\u{F703}")
    }

    @Test func arrowKeysUseGhosttysUnderscoredNames() {
        // The trap that made a first pass report ⌥⌘arrows as free: ghostty spells
        // them arrow_left, and "super+alt+left" is a keybind line that parses and
        // unbinds nothing. Checking the composed trigger against the real table
        // is what makes this test more than a spelling echo.
        let left = MenuShortcut(key: .arrowLeft, modifiers: [.command, .option])
        #expect(left.ghosttyTriggers == ["super+alt+arrow_left"])
        #expect(GhosttyDefaultKeybinds.triggers.contains("super+alt+arrow_left"))
    }

    @Test func returnUsesGhosttysEnterNameAndAppKitsCarriageReturn() {
        // The two disagree, which is the reason MenuKey carries both spellings.
        // AppKit matches Return on 0x0D and ghostty calls the trigger "enter".
        let zoom = MenuShortcut(key: .returnKey, modifiers: [.command, .shift])
        #expect(zoom.key.appKitCharacter == "\r")
        #expect(zoom.ghosttyTriggers == ["super+shift+enter"])
        #expect(GhosttyDefaultKeybinds.triggers.contains("super+shift+enter"))
    }

    @Test func modifiersRenderInTheOrderSuperControlOptionShift() {
        // Ghostty compares the whole trigger string literally, so a reordered
        // prefix is a different trigger and unbinds nothing. The all-four case is
        // the only one where every pairwise ordering mistake is visible, and
        // super+alt+shift+w confirms the order against a real default binding.
        let all: MenuModifiers = [.command, .control, .option, .shift]
        #expect(all.ghosttyPrefix == "super+ctrl+alt+shift")

        let closeAll = MenuShortcut(key: .character("w"), modifiers: [.shift, .option, .command])
        #expect(closeAll.ghosttyTriggers == ["super+alt+shift+w"])
        #expect(GhosttyDefaultKeybinds.triggers.contains("super+alt+shift+w"))
    }

    @Test func anUnmodifiedKeyHasNoLeadingSeparator() {
        // A fixed prefix + "+" would produce "+enter" here, which ghostty rejects
        // while the line still reads as a plausible unbind in a diff. No menu item
        // is unmodified today, so nothing else in the suite reaches this branch.
        let bare = MenuShortcut(key: .returnKey, modifiers: [])
        #expect(bare.modifiers.ghosttyPrefix.isEmpty)
        #expect(bare.ghosttyTriggers == ["enter"])
    }

    @Test func aCapitalisedLetterStillProducesGhosttysLowercaseTrigger() {
        // AppKit menus are often written with an uppercase key equivalent for a
        // shift shortcut, the way MainMenu.swift writes "P" for ⇧⌘P. Ghostty
        // binds super+shift+p and matches literally, so the uppercase form would
        // unbind nothing.
        let shifted = MenuShortcut(key: .character("P"), modifiers: [.command, .shift])
        #expect(shifted.ghosttyTriggers == ["super+shift+p"])
        #expect(GhosttyDefaultKeybinds.triggers.contains("super+shift+p"))
    }
}
