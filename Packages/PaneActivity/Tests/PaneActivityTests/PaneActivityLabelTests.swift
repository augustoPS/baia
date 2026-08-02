import Foundation
import Testing

@testable import PaneActivity

/// The one name for what is running, and the rule that it never says anything
/// about whether the pane wants the owner.
///
/// This lives here rather than in the app for the reason the CLI's pure half
/// lives in a package: the app target has no test target, and the rule that was
/// only enforced there was silently wrong for a year of nobody being able to
/// look at it.
@Suite struct PaneActivityLabelTests {
    @Test func eachCaseNamesItself() {
        #expect(PaneActivity.agent(name: "claude", pid: 42).label == "claude")
        #expect(PaneActivity.build(command: "swift").label == "swift")
        #expect(PaneActivity.command(name: "vim").label == "vim")
    }

    /// **The defect this type's own doc comment warned about.** An idle shell has
    /// nothing running, so it has no label. The chrome used to substitute the
    /// attention message here, which is how a pane that rang while idle reported
    /// "needs input" as the thing it was running, in the same breath as it
    /// reported "needs input" as the thing it wanted. The substitution belongs to
    /// the footer, which has one line to say everything in. It does not belong to
    /// anything that answers "what is running".
    @Test func anIdleShellHasNoLabelAndBorrowsNobodyElses() {
        #expect(PaneActivity.idleShell.label == nil)
    }

    /// The label is a function of the case alone, so nothing about attention,
    /// focus, or the pane's history can reach it.
    @Test func theLabelIgnoresThePid() {
        #expect(
            PaneActivity.agent(name: "claude", pid: 1).label
                == PaneActivity.agent(name: "claude", pid: 9999).label
        )
    }

    // MARK: - isIdle

    /// True for a pane sitting at a prompt with nothing under it.
    @Test func idleShellIsIdle() {
        #expect(PaneActivity.isIdle(.idleShell))
    }

    /// Every other case is something running, or an inability to tell what is,
    /// neither of which is idle.
    @Test func nothingElseIsIdle() {
        #expect(!PaneActivity.isIdle(.agent(name: "claude", pid: 1)))
        #expect(!PaneActivity.isIdle(.build(command: "npm")))
        #expect(!PaneActivity.isIdle(.command(name: "vim")))
        #expect(!PaneActivity.isIdle(.unnameable))
    }

    // MARK: - isWorkingAgent

    /// True while an agent is running in this pane.
    @Test func anAgentIsWorking() {
        #expect(PaneActivity.isWorkingAgent(.agent(name: "claude", pid: 1)))
    }

    /// Busy is reserved for the agent itself, not for a build or an unlabelled
    /// command it might be running underneath.
    @Test func nothingElseIsWorking() {
        #expect(!PaneActivity.isWorkingAgent(.idleShell))
        #expect(!PaneActivity.isWorkingAgent(.build(command: "npm")))
        #expect(!PaneActivity.isWorkingAgent(.command(name: "vim")))
        #expect(!PaneActivity.isWorkingAgent(.unnameable))
    }
}
