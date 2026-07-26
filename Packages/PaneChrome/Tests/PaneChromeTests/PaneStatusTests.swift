import Foundation
import Testing

@testable import PaneChrome

@Suite struct PaneStatusTests {
    @Test func theShellDirectoryIsTildeAbbreviatedAgainstTheSuppliedHome() {
        #expect(PaneStatus.workingDirectory(
            ofShellAt: "/Users/gu/Projects/baia/Packages",
            anchoredAt: "/Users/gu/Projects/baia",
            home: "/Users/gu"
        ) == "~/Projects/baia/Packages")
    }

    @Test func aShellSittingAtTheAnchorHasNoDirectoryToShow() {
        // The leading segments already name the project. Restating it in the
        // widest trailing segment costs the working directory's own place on a
        // narrow bar and says nothing.
        #expect(PaneStatus.workingDirectory(
            ofShellAt: "/Users/gu/Projects/baia",
            anchoredAt: "/Users/gu/Projects/baia",
            home: "/Users/gu"
        ) == nil)
    }

    @Test func aTrailingSlashDoesNotMakeTheShellLookLikeItMoved() {
        // The kernel's `proc_pidinfo` answer and a URL built with a directory
        // hint spell the same directory differently, and six locator tests in
        // ProjectAnchor once failed on nothing but this.
        #expect(PaneStatus.workingDirectory(
            ofShellAt: "/Users/gu/Projects/baia/",
            anchoredAt: "/Users/gu/Projects/baia",
            home: "/Users/gu"
        ) == nil)
    }

    @Test func aHomePrefixThatIsNotAPathBoundaryIsNotAbbreviated() {
        // `/Users/gu` is a plain string prefix of `/Users/gutao/...`.
        // Abbreviating on that would produce `~tao/notes`, a path that exists
        // nowhere and cannot be pasted into anything.
        #expect(PaneStatus.workingDirectory(
            ofShellAt: "/Users/gutao/notes",
            anchoredAt: "/Users/gutao/Projects",
            home: "/Users/gu"
        ) == "/Users/gutao/notes")
    }

    @Test func aDirectoryOutsideHomeKeepsItsAbsolutePath() {
        #expect(PaneStatus.workingDirectory(
            ofShellAt: "/opt/homebrew/etc",
            anchoredAt: "/opt/homebrew",
            home: "/Users/gu"
        ) == "/opt/homebrew/etc")
    }

    @Test func homeItselfAbbreviatesToTheTildeAlone() {
        #expect(PaneStatus.workingDirectory(
            ofShellAt: "/Users/gu",
            anchoredAt: "/Users/gu/Projects",
            home: "/Users/gu"
        ) == "~")
    }

    @Test func anUnknownHomeLeavesThePathAlone() {
        // A caller with no home to offer gets the full path rather than a path
        // with a stray tilde welded to the front of it.
        #expect(PaneStatus.workingDirectory(
            ofShellAt: "/Users/gu/Projects/baia/Sources",
            anchoredAt: "/Users/gu/Projects/baia",
            home: ""
        ) == "/Users/gu/Projects/baia/Sources")
    }

    // MARK: - Attention

    @Test func aPaneWithNoAgentIsNotAsking() {
        #expect(Sample.status().attention == .none)
    }

    @Test func aWorkingAgentIsNotAsking() {
        // The state four panes are in most of the time. It must be the calmest
        // thing in the app, which starts with it not being an attention state at
        // all.
        let busy = Sample.status(agent: .init(label: "claude", wantsAttention: false, isBusy: true))
        #expect(busy.attention == .none)
    }

    @Test func theTwoLevelsAreTheSameRequestAtDifferentVolumes() {
        // The requirement reads as a contradiction (urgent across four panes,
        // tolerable to sit beside, settled once seen) and is only contradictory
        // while attention is one state.
        let asking = Sample.status(agent: .init(label: "claude", wantsAttention: true))
        let seen = Sample.status(
            agent: .init(label: "claude", wantsAttention: true, isAcknowledged: true)
        )
        #expect(asking.attention == .asking)
        #expect(seen.attention == .acknowledged)
    }

    @Test func anAcknowledgementCannotOutliveTheRequestThatEarnedIt() {
        // Derived rather than stored, which is what makes "cleared whenever
        // wantsAttention goes false" a thing that cannot be forgotten rather than
        // a line someone has to remember to write. A pane that stops asking goes
        // straight back to none with no transition to run and nothing to reset.
        let stale = Sample.status(
            agent: .init(label: "claude", wantsAttention: false, isAcknowledged: true)
        )
        #expect(stale.attention == .none)
    }
}
