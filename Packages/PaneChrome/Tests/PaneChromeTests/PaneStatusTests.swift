import BaiaSettings
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

    @Test func theLevelReadsTheSameFromABareAgentAsFromAWholeStatus() {
        // The app's pane controller holds the agent without a status around it,
        // and it used to answer this question with its own copy of the two lines.
        // Both readings have to stay one derivation, or a pane could wear the
        // attention frame the controller draws while its footer disagreed.
        let cases: [PaneStatus.Agent?] = [
            nil,
            .init(label: "claude", wantsAttention: false),
            .init(label: "claude", wantsAttention: true),
            .init(label: "claude", wantsAttention: true, isAcknowledged: true),
            .init(label: "claude", wantsAttention: false, isAcknowledged: true),
        ]
        for agent in cases {
            #expect(PaneStatus.Attention(agent) == Sample.status(agent: agent).attention)
        }
    }

    @Test func noneNamesNoLineAtAll() {
        // A pane that is not asking prints no `attention` line at all rather than
        // a line saying nothing happened.
        #expect(PaneStatus.Attention.name(of: .none) == nil)
    }

    @Test func askingAndAcknowledgedNameTheirOwnWord() {
        #expect(PaneStatus.Attention.name(of: .asking) == "asking")
        #expect(PaneStatus.Attention.name(of: .acknowledged) == "acknowledged")
    }

    @Test func aFinishedUnseenAgentResolvesToDone() {
        let agent = PaneStatus.Agent(
            label: "claude", wantsAttention: false, hasFinishedUnseen: true
        )
        #expect(PaneStatus.Attention(agent) == .done)
    }

    @Test func aRequestOutranksAFinish() {
        // The tracker never produces both, but the init decides the precedence
        // rather than trusting that: a pane that is asking is asking.
        let agent = PaneStatus.Agent(
            label: "claude", wantsAttention: true, hasFinishedUnseen: true
        )
        #expect(PaneStatus.Attention(agent) == .asking)
    }

    @Test func aFinishedAgentDefaultIsUnfinished() {
        // Every existing call site compiles unchanged and renders identically.
        let agent = PaneStatus.Agent(label: "claude", wantsAttention: false)
        #expect(PaneStatus.Attention(agent) == .none)
    }

    @Test func doneHasAWireName() {
        #expect(PaneStatus.Attention.name(of: .done) == "done")
    }

    // MARK: - the attention frame

    @Test func onlyAnUnacknowledgedAskWearsTheFrameAndOnlyWhenLoud() {
        // Both halves of the conjunction, every level against every style, so
        // neither term can be dropped without a failure here. `asking` + `loud`
        // is the one true cell; the other seven are what the two views must
        // agree to leave bare.
        for level in PaneStatus.Attention.allCases {
            for style in AttentionStyle.allCases {
                let expected = level == .asking && style == .loud
                #expect(
                    level.wearsFrame(under: style) == expected,
                    "\(level) under \(style)"
                )
            }
        }
    }

    @Test func acknowledgingAnAskTakesTheFrameOffWithoutTouchingTheStyle() {
        // The level moves, the style does not, and the frame comes off. This is
        // what `acknowledged` means — the owner has been in the pane, so the
        // cross-window carrier has done its job — and it is the case a predicate
        // written as `attention != .none` would get wrong while still passing a
        // test that only ever checked `.asking` and `.none`.
        let asking = PaneStatus.Attention(
            PaneStatus.Agent(label: "claude", wantsAttention: true, isAcknowledged: false)
        )
        let acknowledged = PaneStatus.Attention(
            PaneStatus.Agent(label: "claude", wantsAttention: true, isAcknowledged: true)
        )
        #expect(asking.wearsFrame(under: .loud))
        #expect(!acknowledged.wearsFrame(under: .loud))
    }

    @Test func quietTakesTheFrameOffTheOnePaneThatWouldHaveWornIt() {
        // The settings preview's whole reason for installing a `PaneEdgeFrameView`:
        // `attentionStyle` reaches nothing on the capsule, so this predicate is
        // the entire visible difference between the two values, and it has to
        // move on exactly the asking pane and no other.
        let asking = PaneStatus.Attention.asking
        #expect(asking.wearsFrame(under: .loud) != asking.wearsFrame(under: .quiet))
        for calm in [PaneStatus.Attention.none, .acknowledged, .done] {
            #expect(calm.wearsFrame(under: .loud) == calm.wearsFrame(under: .quiet))
        }
    }
}
