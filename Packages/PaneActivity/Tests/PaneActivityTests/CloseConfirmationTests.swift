import Foundation
import Testing

@testable import PaneActivity

/// Whether a close has to ask first, and what it says when it does.
///
/// The policy (owner decision, 2026-09-06): any close that would end a running
/// job asks; a close of idle shells does not. The wording names what is
/// running, because "are you sure?" gives the owner nothing to decide on.
@Suite struct CloseConfirmationTests {
    @Test func idleShellsCloseWithoutAsking() {
        #expect(CloseConfirmation.needed(for: .pane, activities: [.idleShell]) == nil)
        #expect(CloseConfirmation.needed(for: .window, activities: [.idleShell, .idleShell]) == nil)
        #expect(CloseConfirmation.needed(for: .quit, activities: []) == nil)
    }

    @Test func aBuildInThePaneAsksAndNamesIt() throws {
        let confirmation = try #require(
            CloseConfirmation.needed(for: .pane, activities: [.build(command: "make")])
        )
        #expect(confirmation.title == "Close the pane while make is running?")
        #expect(confirmation.detail.contains("make"))
        #expect(confirmation.confirmTitle == "Close Pane")
    }

    @Test func anAgentIsNamedByItsAgentName() throws {
        let confirmation = try #require(
            CloseConfirmation.needed(for: .pane, activities: [.agent(name: "Claude Code", pid: 42)])
        )
        #expect(confirmation.title == "Close the pane while Claude Code is running?")
    }

    /// The detector could not name the process. Asking is the honest answer;
    /// closing silently would be the one it must not give.
    @Test func anUnnameableProcessStillAsks() throws {
        let confirmation = try #require(
            CloseConfirmation.needed(for: .pane, activities: [.unnameable])
        )
        #expect(confirmation.title == "Close the pane while something is still running?")
    }

    @Test func onlyBusyPanesCountTowardsAWindowClose() throws {
        let confirmation = try #require(CloseConfirmation.needed(
            for: .window,
            activities: [.idleShell, .command(name: "sleep"), .idleShell, .build(command: "swift")]
        ))
        #expect(confirmation.title == "Close the window while 2 panes are still running?")
        #expect(confirmation.detail == "Running: sleep, swift. Closing the window ends them.")
        #expect(confirmation.confirmTitle == "Close Window")
    }

    @Test func aTabWithOneBusyPaneReadsLikeAPane() throws {
        let confirmation = try #require(CloseConfirmation.needed(
            for: .tab,
            activities: [.idleShell, .command(name: "sleep")]
        ))
        #expect(confirmation.title == "Close the tab while sleep is running?")
        #expect(confirmation.confirmTitle == "Close Tab")
    }

    @Test func quitCountsEveryBusyPaneAndRepeatedLabelsOnce() throws {
        let confirmation = try #require(CloseConfirmation.needed(
            for: .quit,
            activities: [.build(command: "make"), .build(command: "make"), .unnameable]
        ))
        #expect(confirmation.title == "Quit while 3 panes are still running?")
        #expect(confirmation.detail == "Running: make, an unnamed process. Quitting ends them.")
        #expect(confirmation.confirmTitle == "Quit")
    }
}
