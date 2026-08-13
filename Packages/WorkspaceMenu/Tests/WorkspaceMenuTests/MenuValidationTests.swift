import Foundation
import Testing

@testable import WorkspaceMenu

@Suite struct MenuValidationTests {
    /// Shorthand for the function under test, so a rule's two halves sit on
    /// adjacent lines and the only difference between them is the state. Spelled
    /// out, each half wraps and the pair stops reading as a pair.
    private func state(_ command: MenuCommand, _ availability: MenuAvailability) -> MenuItemState {
        MenuValidation.state(for: command, given: availability)
    }

    @Test func everyCommandHasAnExplicitValidationRule() {
        // The compile-time half of this is the switch having no default clause.
        // The runtime half is the list below: folding a command into the wrong case
        // group compiles fine, and naming exactly what survives with nothing open
        // is what catches it. A new command lands in one of the two sets and this
        // fails until somebody decides which.
        let enabled = MenuCommand.allCases.filter { state($0, .empty).isEnabled }

        #expect(Set(enabled) == [
            .about, .hide, .hideOthers, .showAll, .quit,
            .newWindow, .newTab, .openConfiguration,
            .reloadProjectList, .mergeAllWindows, .bringAllToFront,
            .copyDiagnostics, .toggleSurfacePanels, .resetSidebarSize,
        ])
    }

    @Test func quitStaysEnabledWithNothingOpen() {
        // baia shipped with no ⌘Q at all once, and closing the window was the only
        // way out. A window-count rule applied across the board would put that back.
        #expect(state(.quit, .empty).isEnabled)
    }

    @Test func closePaneIsDisabledWithASinglePaneAndEnabledWithTwo() {
        // The pair is what pins the threshold. Either half alone passes whichever
        // way the comparison goes, and the alternative rule (enabled whenever a
        // pane exists) would make ⌘W and ⌥⌘W both close the tab.
        #expect(!state(.closePane, MenuAvailability(paneCount: 1)).isEnabled)
        #expect(state(.closePane, MenuAvailability(paneCount: 2)).isEnabled)
    }

    @Test func splittingIsAvailableWithTheOnlyPane() {
        // The mirror of closePane's threshold, and the reason the two commands sit
        // in different case groups: one pane can be split but not closed.
        #expect(state(.splitRight, MenuAvailability(paneCount: 1)).isEnabled)
        #expect(!state(.splitRight, .empty).isEnabled)
    }

    @Test func growingAndEqualizingNeedADividerToMove() {
        // This rule was unreachable until the grow commands had selectors. AppKit
        // disables an item whose action is nil before `validateMenuItem` runs, so
        // every one of these read as disabled for a reason that had nothing to do
        // with the pane count, and the pair below would have passed on its first
        // half while the second was a lie.
        for command in [
            MenuCommand.growPaneLeft, .growPaneRight, .growPaneUp, .growPaneDown, .equalizePanes,
        ] {
            #expect(!state(command, MenuAvailability(paneCount: 1)).isEnabled)
            #expect(state(command, MenuAvailability(paneCount: 2)).isEnabled)
        }
    }

    @Test func clearPinIsDisabledWhenNothingIsPinned() {
        // The rule that already exists in AppDelegate.validateMenuItem, moved here
        // so it is a pure function rather than a branch needing a window on screen.
        #expect(!state(.clearProjectDirectoryPin, .empty).isEnabled)
        #expect(state(.clearProjectDirectoryPin, MenuAvailability(isPinned: true)).isEnabled)
    }

    @Test func gitCommandsAreDisabledForAPlainAnchor() {
        // A plain anchor is what a pane gets outside any repository, so it has no
        // branch and nothing to refresh. Keying the rule on hasAnchor alone would
        // enable it here, which is the mistake this guards.
        let plain = MenuAvailability(hasAnchor: true, anchorIsRepository: false)
        let repository = MenuAvailability(hasAnchor: true, anchorIsRepository: true)

        #expect(!state(.refreshGitStatus, plain).isEnabled)
        #expect(state(.refreshGitStatus, repository).isEnabled)
    }

    @Test func anchorCommandsWaitForTheFirstWorkingDirectory() {
        // A pane has no anchor until its first poll returns, so a pane count alone
        // is not enough to enable revealing or copying the anchor.
        let paneWithoutAnchor = MenuAvailability(paneCount: 1)

        #expect(!state(.revealAnchor, paneWithoutAnchor).isEnabled)
        #expect(!state(.copyAnchorPath, paneWithoutAnchor).isEnabled)
        #expect(state(.revealAnchor, MenuAvailability(hasAnchor: true)).isEnabled)
    }

    @Test func tabCyclingNeedsASecondTab() {
        // Cycling to the next tab of one is a no-op that still consumes ⇧⌘], and a
        // consumed key with no visible effect is the symptom this whole package
        // exists to keep out.
        #expect(!state(.showNextTab, MenuAvailability(tabCount: 1)).isEnabled)
        #expect(state(.showNextTab, MenuAvailability(tabCount: 2)).isEnabled)
    }

    @Test func windowCommandsNeedAWindow() {
        // Keyed on the tab count rather than a separate hasWindow flag, since a
        // window always holds at least one tab and two fields for one fact are free
        // to disagree.
        #expect(!state(.minimize, .empty).isEnabled)
        #expect(state(.minimize, MenuAvailability(tabCount: 1)).isEnabled)
    }

    @Test func findNeedsOnePaneAndNotTwo() {
        // The pair is the point. Find sits next to Close Pane in the same menu
        // bar and takes the opposite threshold: one pane is searchable while one
        // pane is not closable, and folding Find into the two-pane group would
        // grey out ⌘F in exactly the window shape baia opens with.
        #expect(!state(.findInPane, .empty).isEnabled)
        #expect(state(.findInPane, MenuAvailability(paneCount: 1)).isEnabled)
    }

    @Test func thePaletteIsDisabledUntilTheProjectListIsLoaded() {
        // An empty palette reads as a workspace holding no projects, which is a
        // worse answer than a disabled item.
        #expect(!state(.commandPalette, .empty).isEnabled)
        #expect(state(.commandPalette, MenuAvailability(paletteAvailable: true)).isEnabled)
    }

    @Test func zoomIsTheOnlyItemReportingACheckedState() {
        // Nil and false are different answers, and collapsing them would have the
        // app target write .off onto every plain item. NSMenuItem.state is already
        // .off, so that bug stays invisible until a checkable item is added and
        // then forgotten.
        //
        // This read `[.toggleStatusBars, .zoomPane]` until Status Bars was
        // deleted. A one-element set is a weaker fixture than a two-element one
        // and it is worth naming why it still holds: the assertion fails both
        // ways, on a new command that reports a check nobody decided to draw and
        // on zoom quietly returning nil, which is the pair that matters.
        let checkable = MenuCommand.allCases.filter { state($0, .empty).isChecked != nil }
        #expect(Set(checkable) == [.zoomPane])
    }

    @Test func theCheckedStateTracksTheThingItReports() {
        // Every flag in MenuAvailability defaults to false, so a rule wired to the
        // wrong field would still read false here. Setting isZoomed on its own,
        // against a state matching it in every other respect, is what separates
        // the check from the default. The pair is the test: an implementation
        // returning a constant passes either half alone.
        let zoomed = MenuAvailability(paneCount: 2, isZoomed: true)
        let twoPanes = MenuAvailability(paneCount: 2)

        #expect(state(.zoomPane, zoomed).isChecked == true)
        #expect(state(.zoomPane, twoPanes).isChecked == false)
    }

    @Test func zoomIsCheckableAndStillDisabledWithOnePane() {
        // A checkable item can be disabled, and the two answers come from different
        // fields. An implementation returning nil for a disabled item would pass
        // every other assertion in this suite.
        let single = state(.zoomPane, MenuAvailability(paneCount: 1, isZoomed: false))

        #expect(!single.isEnabled)
        #expect(single.isChecked == false)
    }
}

/// Why a command is unavailable, which the menu ignores and the command palette
/// draws.
@Suite struct MenuUnavailableReasonTests {
    /// The invariant the palette leans on: anything disabled can say why. A
    /// disabled command with no reason would be drawn as if it were available,
    /// since the palette reads the reason's absence as "runnable".
    @Test func everyDisabledCommandInEveryStateExplainsItself() {
        let states = [
            MenuAvailability.empty,
            MenuAvailability(paneCount: 1, tabCount: 1),
            MenuAvailability(paneCount: 2, tabCount: 2, isPinned: true, hasAnchor: true,
                             anchorIsRepository: true, paletteAvailable: true),
            MenuAvailability(paneCount: 1, tabCount: 1, hasAnchor: true),
        ]
        for availability in states {
            for command in MenuCommand.allCases {
                let state = MenuValidation.state(for: command, given: availability)
                if !state.isEnabled {
                    #expect(
                        state.unavailableReason != nil,
                        "\(command) is disabled with no reason"
                    )
                }
            }
        }
    }

    /// An enabled item has nothing to explain, and a reason riding along with one
    /// would put a requirement on screen beside a verb that already meets it.
    @Test func anEnabledCommandCarriesNoReason() {
        let plenty = MenuAvailability(
            paneCount: 2, tabCount: 2, isPinned: true, hasAnchor: true,
            anchorIsRepository: true, paletteAvailable: true
        )
        for command in MenuCommand.allCases {
            let state = MenuValidation.state(for: command, given: plenty)
            if state.isEnabled { #expect(state.unavailableReason == nil) }
        }
    }

    /// The initializer drops a reason handed to an enabled state, so a caller
    /// cannot construct the contradiction the arm above checks for.
    @Test func anEnabledStateRefusesAReason() {
        let state = MenuItemState(isEnabled: true, isChecked: nil, unavailableReason: "needs 2 panes")
        #expect(state.unavailableReason == nil)
    }

    @Test func theReasonNamesWhatIsMissing() {
        let one = MenuAvailability(paneCount: 1, tabCount: 1)
        #expect(MenuValidation.state(for: .equalizePanes, given: one).unavailableReason == "needs 2 panes")
        #expect(MenuValidation.state(for: .showNextTab, given: one).unavailableReason == "needs 2 tabs")
    }
}
