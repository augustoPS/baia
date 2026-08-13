import Foundation
import GitWorkspace
import Testing

@testable import PaneChrome

@Suite struct PaneClusterSegmentsTests {
    private func roles(_ status: PaneStatus) -> [PaneClusterSegmentRole] {
        PaneClusterSegments.build(from: status).map(\.role)
    }

    private func segment(
        _ role: PaneClusterSegmentRole,
        in status: PaneStatus
    ) -> PaneClusterSegment? {
        PaneClusterSegments.build(from: status).first { $0.role == role }
    }

    @Test func bareShellPaneWearsNoCapsule() {
        #expect(roles(Sample.status(git: nil, agent: nil)) == [])

        // The footer's stale-facts rule, kept: the caller can hold git facts
        // from before a `cd` out of the repository, so `git` being non-nil is
        // not evidence of a repository and the capsule must not say `main` over
        // a plain directory.
        #expect(roles(Sample.status(anchorIsRepository: false, git: Sample.git(dirty: true))) == [])
    }

    @Test func repoPaneGetsPlaceThenChanges() {
        let status = Sample.status(git: Sample.git(ahead: 1, dirty: true))
        #expect(roles(status) == [.place, .changes])
        #expect(segment(.place, in: status)?.text == "main")
    }

    @Test func cleanRepoDropsChanges() {
        // Absent, never empty: an empty changes segment would still cost a gap
        // beside the place name, and a clean repository is the common case.
        #expect(roles(Sample.status(git: Sample.git())) == [.place])
    }

    @Test func agentAndAttentionAppendInOrder() {
        let status = Sample.status(
            git: Sample.git(dirty: true),
            agent: .init(label: "claude", wantsAttention: true)
        )
        #expect(roles(status) == [.place, .changes, .agent, .attention])

        // The dot draws, not reads: attention carries no text of its own.
        #expect(segment(.attention, in: status)?.text == "")
    }

    @Test func changesTextReusesFooterMarkers() {
        // Asserted against the footer's own built segment, not a copy of its
        // vocabulary: if the footer's marker assembly changes and the capsule's
        // does not follow, this fails. The literal pins both against drifting
        // together away from the owner's statusline prefix.
        let git = Sample.git(ahead: 1, dirty: true, untracked: 3)
        let status = Sample.status(git: git)
        let footer = PaneStatusSegments.build(from: status).first { $0.role == .indicators }
        let changes = segment(.changes, in: status)
        #expect(changes?.text == footer?.text)
        #expect(changes?.text == PaneStatusSegments.markerText(for: git))
        #expect(changes?.text == "↑1*?3")
    }

    // MARK: - The operation

    /// The operation leads, and it leads *the git group specifically*. Asserted
    /// as the whole role list on a status carrying every fact, so a change that
    /// appended it at the end, or slid it past the branch, fails here rather
    /// than passing a weaker "is it present" check.
    @Test func theOperationLeadsTheRestOfTheCapsule() {
        let status = Sample.status(
            git: Sample.git(ahead: 1, dirty: true, operation: "REBASE"),
            agent: .init(label: "claude", wantsAttention: true)
        )
        #expect(roles(status) == [.operation, .place, .changes, .agent, .attention])
        #expect(segment(.operation, in: status)?.text == "REBASE")
    }

    /// The capsule's order is the footer's order. Asserted by comparing the two
    /// surfaces' *relative* placement of the same two facts rather than by
    /// restating either table, so the two cannot be reordered apart: if a later
    /// task moves the operation behind the branch on one surface only, this
    /// fails even though both surfaces still carry both facts.
    @Test func theCapsulePutsTheOperationBeforeTheBranchJustAsTheFooterDoes() {
        let status = Sample.status(git: Sample.git(dirty: true, operation: "MERGE"))

        let capsule = roles(status)
        let footer = PaneStatusSegments.build(from: status).map(\.role)
        guard let capsuleOperation = capsule.firstIndex(of: .operation),
              let capsulePlace = capsule.firstIndex(of: .place),
              let footerOperation = footer.firstIndex(of: .operation),
              let footerBranch = footer.firstIndex(of: .branch)
        else {
            Issue.record("both surfaces must carry an operation and a branch here")
            return
        }
        #expect(capsuleOperation < capsulePlace)
        #expect(footerOperation < footerBranch)
    }

    /// The label is the footer's, through one derivation. `GitWorkspace`'s
    /// vocabulary reaches both surfaces via
    /// `PaneStatus.Git.operationLabel(for:)`, so a renamed state (`CHERRY-PICK`
    /// becoming `CHERRY PICK`, say) moves both or fails here.
    ///
    /// **This no longer claims to catch a new `InProgress` case, because it never
    /// could.** It walked `InProgress.allCases` and recorded an issue on a nil
    /// label, on the reasoning that an unlabelled new state would show up here.
    /// `operationLabel` switches over that enum with no `default`, so a case
    /// added to `GitWorkspace` is a compile error at
    /// `PaneStatus+Repository.swift:50` and the suite never gets to run — proved
    /// 2026-08-13 by adding a `graft` case, which killed `make test` in
    /// compilation. The nil branch was unreachable and the loop was grading what
    /// the compiler already guarantees. The conformance went with it
    /// (``GitWorkspace/RepositoryStatus/InProgress`` carries the reasoning).
    ///
    /// What is left is the part no compiler checks: that the *string* reaching
    /// the pill is the *string* reaching the footer. The cases are named
    /// explicitly, which is honest about the enumeration being a hand-kept list
    /// rather than a derived one, and costs nothing the loop was buying.
    @Test func everyOperationReachesThePillUnderItsFooterLabel() {
        for operation in [
            RepositoryStatus.InProgress.rebase, .merge, .cherryPick, .revert, .bisect
        ] {
            let label = PaneStatus.Git.operationLabel(for: operation)
            #expect(label != nil)
            guard let label else { continue }

            let status = Sample.status(git: Sample.git(operation: label))
            #expect(segment(.operation, in: status)?.text == label)

            // And the footer says the identical string for the identical input.
            let footer = PaneStatusSegments.build(from: status).first { $0.role == .operation }
            #expect(segment(.operation, in: status)?.text == footer?.text)
        }
    }

    /// **The operation shares the pill; it never takes it.** This is the whole
    /// difference from the notice, and the one a "does the operation appear"
    /// test cannot see. `CHERRY-PICK` is persistent — a halted rebase lasts
    /// until it is resolved and `BISECT_LOG` outlives the session — so a
    /// takeover would hide the branch, the markers, the agent and the dot for
    /// hours rather than for three seconds.
    ///
    /// Asserted against the same status without the operation, so it cannot
    /// pass by the status happening to carry nothing else.
    @Test func theOperationSharesThePillRatherThanTakingItLikeANotice() {
        let git = Sample.git(ahead: 1, dirty: true, operation: "CHERRY-PICK")
        let agent = PaneStatus.Agent(label: "claude", wantsAttention: true)
        let status = Sample.status(git: git, agent: agent)

        // Everything the pane had to say without the operation is still said.
        let without = Sample.status(git: Sample.git(ahead: 1, dirty: true), agent: agent)
        #expect(roles(without) == [.place, .changes, .agent, .attention])
        for role in roles(without) {
            #expect(roles(status).contains(role))
        }

        // A notice on the same status *does* take the pill, which is what makes
        // the comparison meaningful rather than a restatement.
        let noticed = Sample.status(git: git, agent: agent, notice: "nothing to send")
        #expect(roles(noticed) == [.notice])
    }

    /// A blank label is not an operation, the footer's own rule. A poller that
    /// formatted one from an empty git file hands over `" "`, which `isEmpty`
    /// calls content: the pill would pay a segment gap to draw nothing in it.
    @Test func aBlankOperationEarnsNoSegment() {
        #expect(roles(Sample.status(git: Sample.git(operation: " "))) == [.place])
        #expect(roles(Sample.status(git: Sample.git(operation: ""))) == [.place])

        // The footer refuses the same string, which is the shared predicate
        // being shared rather than two rules that happen to agree today.
        let blank = Sample.status(git: Sample.git(operation: " "))
        #expect(!PaneStatusSegments.build(from: blank).contains { $0.role == .operation })
    }

    /// **The place card's row and the pill's segment agree, blanks included.**
    ///
    /// The two surfaces shared the `PaneStatus.Git` they read and each spelled
    /// its own test of it: the pill asked `isBlank`, the card
    /// (`TerminalPaneController.presentPlaceCard`) asked `if let` alone. On
    /// `operation == "   "` the pill drew nothing and the card grew a row
    /// captioned `operation` with a blank value — the empty box `isBlank` exists
    /// to prevent, on the surface that never got the predicate.
    ///
    /// Written against ``PaneStatus/Git/displayableOperation`` rather than
    /// against the card, because the card's row *is* that call
    /// (`operation: git?.displayableOperation`) and the AppKit half — a row view
    /// appended for a non-nil value — needs no window to be wrong. What this
    /// pins is the claim the controller's comment now makes: for one
    /// `PaneStatus.Git`, either both surfaces show the operation and show the
    /// identical string, or neither shows it.
    ///
    /// The blank strings are the cases that actually diverged; the real label
    /// and the nil are here so a predicate that answered nil for *everything*
    /// could not pass by agreeing vacuously.
    ///
    /// **Agreement alone would be a test with no teeth, and that was measured
    /// rather than reasoned about.** Written first as `card == pill` only, it
    /// passed against a `displayableOperation` gutted back to `return operation`
    /// — both surfaces call the one predicate now, so they agree *while both
    /// being wrong*, which is the failure mode a unification test invites. So
    /// each side is also asserted against the contract itself: nothing blank
    /// reaches either surface. The agreement clause stays, because it is what
    /// catches a future caller re-spelling one surface's test.
    @Test func theCardAndThePillAgreeOnWhatCountsAsAnOperation() {
        // `shown` is written out per string rather than computed from
        // `isBlank`, deliberately: `isBlank` is the predicate under test here,
        // and an expectation derived from it moves whenever it does. These are
        // literals a reader can check by eye.
        let cases: [(raw: String, shown: Bool)] = [
            ("REBASE", true),
            ("CHERRY-PICK", true),
            (" ", false),
            ("   ", false),
            ("\t", false),
            ("\n", false),
            ("", false),
        ]

        for (raw, shown) in cases {
            let git = Sample.git(operation: raw)
            let status = Sample.status(git: git)

            // What the card's row is built from, verbatim
            // (`TerminalPaneController.presentPlaceCard`: `git?.displayableOperation`).
            let card = git.displayableOperation
            // What the pill draws.
            let pill = segment(.operation, in: status)?.text

            #expect(
                card == pill,
                "card row \(String(describing: card)) vs pill \(String(describing: pill)) for \(raw.debugDescription)"
            )

            // And neither is a blank, which is the thing agreement cannot say.
            // A card row captioned `operation` with `"   "` in it is the empty
            // box; so is a pill segment paying a gap to draw nothing.
            #expect(
                (card != nil) == shown,
                "card row for \(raw.debugDescription) should be \(shown ? "present" : "absent")"
            )
            #expect(
                (pill != nil) == shown,
                "pill segment for \(raw.debugDescription) should be \(shown ? "present" : "absent")"
            )
        }

        // Nil in, nothing out, on both.
        let none = Sample.git(operation: nil)
        #expect(none.displayableOperation == nil)
        #expect(segment(.operation, in: Sample.status(git: none)) == nil)
    }

    /// The stale-facts rule reaches the operation too. A pane that has `cd`-ed
    /// out of a repository can still be holding the poller's last answer, and
    /// `REBASE` over a plain directory is a lie the owner would act on — worse
    /// than the branch name the rule was written for, because it names work in
    /// progress that is not this directory's.
    @Test func aPlainDirectoryDrawsNoOperationEvenHoldingOne() {
        let stale = Sample.status(
            anchorIsRepository: false,
            git: Sample.git(dirty: true, operation: "REBASE")
        )
        #expect(roles(stale) == [])
    }

    /// The operation opens a card, which every role but the notice does. Pinned
    /// separately from `everyRoleButTheNoticeOpensACard` because that test is
    /// written over `allCases` and would keep passing if this role were somehow
    /// exempted *and* the general rule rewritten to match.
    @Test func theOperationOpensACard() {
        #expect(PaneClusterSegmentRole.operation.opensCard)
    }

    // MARK: - The notice

    /// A notice takes the pill alone, and the segments it displaces are the
    /// ones that would otherwise be on it. Asserted against the same status
    /// without the notice, so this cannot pass by the status happening to carry
    /// nothing.
    @Test func aNoticeTakesThePillAlone() {
        let git = Sample.git(ahead: 1, dirty: true)
        let agent = PaneStatus.Agent(label: "claude", wantsAttention: true)

        let resting = Sample.status(git: git, agent: agent)
        #expect(roles(resting) == [.place, .changes, .agent, .attention])

        let noticed = Sample.status(
            git: git,
            agent: agent,
            notice: "name is not valid UTF-8, so the shell cannot hold it: rename the file"
        )
        #expect(roles(noticed) == [.notice])
        #expect(
            segment(.notice, in: noticed)?.text
                == "name is not valid UTF-8, so the shell cannot hold it: rename the file"
        )
    }

    /// The capsule and the footer take a notice on the same input and say the
    /// same sentence. Asserted against the footer's own built segment rather
    /// than a copy of the string, the `changesTextReusesFooterMarkers` shape:
    /// the two surfaces answer one `PaneStatus`, and a refusal explained
    /// differently on each is a refusal explained on neither.
    @Test func theNoticeMatchesTheFootersOwnSentence() {
        let reason = "name holds a control character the shell would act on: rename the file"
        let status = Sample.status(git: Sample.git(dirty: true), notice: reason)
        let footer = PaneStatusSegments.build(from: status).first { $0.role == .notice }
        #expect(segment(.notice, in: status)?.text == footer?.text)
        #expect(footer?.text == reason)

        // Both surfaces take it *alone*, which is the half a text comparison
        // cannot see: a capsule that appended the notice beside the branch
        // would still match the footer's string here.
        #expect(roles(status) == [.notice])
        #expect(PaneStatusSegments.build(from: status).map(\.role) == [.notice])
    }

    /// An empty string is not a notice, the footer's own rule
    /// (`PaneStatusSegmentsTests.anEmptyNoticeIsNotANotice`). A caller clearing
    /// one by writing `""` rather than nil must get the resting pill back, not
    /// a pill wearing an empty segment that has eaten every fact.
    @Test func anEmptyNoticeLeavesTheRestingPill() {
        let status = Sample.status(git: Sample.git(dirty: true), notice: "")
        #expect(roles(status) == [.place, .changes])
    }

    /// A notice on a pane with nothing else to say still wears a pill. The
    /// resting capsule vanishes when it has no facts (`bareShellPaneWearsNoCapsule`),
    /// and a refusal in a bare shell pane is exactly when the owner most needs
    /// the reason: the beep is the only other thing that happened.
    @Test func aNoticeGivesABareShellPaneACapsule() {
        #expect(roles(Sample.status(git: nil, agent: nil)) == [])
        #expect(roles(Sample.status(git: nil, agent: nil, notice: "nothing to send")) == [.notice])
    }

    /// Only the notice declines a card. Written over `allCases` rather than as
    /// four literals so a role added later has to answer the question rather
    /// than inherit an answer.
    @Test func everyRoleButTheNoticeOpensACard() {
        for role in PaneClusterSegmentRole.allCases {
            #expect(role.opensCard == (role != .notice))
        }
    }

    @Test func aFinishedAgentStillEarnsTheAttentionDot() {
        // The footer draws a mark for every attention level except `.none`
        // (`PaneStatusBarView.capsuleGlyph(ink:)`), and `done` is a level. A
        // capsule keyed on `wantsAttention` alone would go quiet on exactly the
        // pane that finished while the owner was elsewhere.
        let status = Sample.status(
            agent: .init(label: "claude", wantsAttention: false, hasFinishedUnseen: true)
        )
        #expect(roles(status) == [.agent, .attention])
    }
}
