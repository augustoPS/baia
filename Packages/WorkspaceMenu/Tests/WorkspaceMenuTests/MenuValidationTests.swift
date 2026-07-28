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
            .toggleStatusBars, .reloadProjectList, .mergeAllWindows, .bringAllToFront,
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

    @Test func onlyTheTwoCheckableItemsReportACheckedState() {
        // Nil and false are different answers, and collapsing them would have the
        // app target write .off onto every plain item. NSMenuItem.state is already
        // .off, so that bug stays invisible until a checkable item is added and
        // then forgotten.
        let checkable = MenuCommand.allCases.filter { state($0, .empty).isChecked != nil }
        #expect(Set(checkable) == [.toggleStatusBars, .zoomPane])
    }

    @Test func theCheckedStateTracksTheThingItReports() {
        // Both flags default to false in MenuAvailability, so a rule wired to the
        // wrong field would still read false here. Setting each one on its own is
        // what separates them.
        let zoomed = MenuAvailability(paneCount: 2, isZoomed: true)
        let twoPanes = MenuAvailability(paneCount: 2)

        #expect(state(.zoomPane, zoomed).isChecked == true)
        #expect(state(.zoomPane, twoPanes).isChecked == false)
        #expect(state(.toggleStatusBars, MenuAvailability(statusBarsVisible: true)).isChecked == true)
        #expect(state(.toggleStatusBars, .empty).isChecked == false)
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
