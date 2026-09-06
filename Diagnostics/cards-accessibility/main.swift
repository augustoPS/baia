import AppKit
import GitWorkspace
import PaneChrome

var failures = 0

func check(_ passed: Bool, _ message: String) {
    if passed {
        print("  ok    \(message)")
    } else {
        failures += 1
        print("  FAIL  \(message)")
    }
}

@MainActor
func children(of element: any NSAccessibilityProtocol) -> [any NSAccessibilityProtocol] {
    element.accessibilityChildren() as? [any NSAccessibilityProtocol] ?? []
}

func actionNames(of element: any NSAccessibilityProtocol) -> [NSAccessibility.Action] {
    guard let object = element as? NSObject else { return [] }
    let selector = NSSelectorFromString("accessibilityActionNames")
    guard object.responds(to: selector),
          let value = object.perform(selector)?.takeUnretainedValue()
    else { return [] }
    return value as? [NSAccessibility.Action] ?? []
}

func labels(_ elements: [any NSAccessibilityProtocol]) -> [String] {
    elements.map { $0.accessibilityLabel() ?? "" }
}

@MainActor
func press(_ element: (any NSAccessibilityProtocol)?) -> Bool {
    element?.accessibilityPerformPress() ?? false
}

@MainActor
func cancel(_ element: any NSAccessibilityProtocol) -> Bool {
    element.accessibilityPerformCancel()
}

func identical(_ lhs: (any NSAccessibilityProtocol)?, _ rhs: (any NSAccessibilityProtocol)?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return (lhs as AnyObject) === (rhs as AnyObject)
}

@main
enum CardsAccessibilityFixture {
    @MainActor static func main() {
        capsuleChecks()
        placeCardChecks()
        changesCardChecks()
        attentionCardChecks()
        print(failures == 0 ? "PASS" : "FAILED \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor
    private static func capsuleChecks() {
        print("=== production capsule semantics ===")
        let capsule = PaneClusterView(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        capsule.segments = [
            PaneClusterSegment(role: .place, text: "main"),
            PaneClusterSegment(role: .changes, text: "*2"),
            PaneClusterSegment(role: .agent, text: "claude"),
            PaneClusterSegment(role: .attention, text: "!", isAcknowledged: true),
        ]
        var clicks: [(PaneClusterSegmentRole, NSRect)] = []
        capsule.onSegmentClick = { clicks.append(($0, $1)) }
        capsule.activeRole = .changes

        check(capsule.window == nil, "the capsule fixture creates no window")
        check(!capsule.acceptsFirstResponder && !capsule.canBecomeKeyView, "the capsule still refuses terminal focus")
        check(capsule.isAccessibilityElement(), "the capsule is a semantic element")
        check(capsule.accessibilityRole() == .group, "the capsule role is group")
        check(capsule.accessibilityLabel() == "Pane status", "the capsule has a stable spoken label")

        let initial = children(of: capsule)
        check(initial.count == 4, "one accessibility child exists per placed segment")
        if initial.count == 4 {
            check(initial.allSatisfy { $0.accessibilityRole() == .button }, "placed segments are buttons")
            check(labels(initial) == ["Place, main", "Changes, *2", "Agent, claude", "Attention, acknowledged"], "segment labels name role and meaning")
            check(initial.map { $0.isAccessibilitySelected() } == [false, true, false, false], "selected state follows activeRole")
            check(initial.allSatisfy { $0.isAccessibilityEnabled() }, "card-opening segments are enabled")
            check(press(initial[0]), "an enabled capsule segment accepts AXPress")
            check(clicks.count == 1 && clicks[0].0 == .place, "AXPress uses onSegmentClick with the exact role")
            check(clicks[0].1 == capsule.segmentRect(for: .place), "AXPress uses the production placed rect")
        }

        let stable = initial.first
        capsule.activeRole = .place
        check(identical(children(of: capsule).first, stable), "selection changes preserve segment child identity")

        let retained = stable
        capsule.segments = [PaneClusterSegment(role: .place, text: "other")]
        let replacement = children(of: capsule)
        check(replacement.count == 1 && !identical(replacement[0], retained), "model replacement creates a fresh semantic segment")
        check(!press(retained), "a retained segment from the previous model refuses AXPress")
        check(clicks.count == 1, "an obsolete capsule segment calls no callback")

        capsule.segments = [PaneClusterSegment(role: .notice, text: "path refused")]
        let notice = children(of: capsule).first
        check(notice?.accessibilityLabel() == "Notice, path refused", "a notice remains readable")
        check(notice?.isAccessibilityEnabled() == false, "a notice that opens no card is disabled")
        check(!press(notice), "a disabled notice refuses AXPress")

        capsule.segments = [PaneClusterSegment(role: .place, text: "before")]
        let reentrant = children(of: capsule).first
        capsule.onSegmentClick = { role, rect in
            clicks.append((role, rect))
            capsule.segments = [PaneClusterSegment(role: .agent, text: "after")]
        }
        check(press(reentrant), "an in-flight capsule press completes its current callback")
        check(clicks.last?.0 == .place, "reentrant replacement cannot retarget the pressed role")
        check(!press(reentrant), "the pre-replacement segment becomes obsolete")
    }

    @MainActor
    private static func placeCardChecks() {
        print("=== production place card rows and close ===")
        let model = ClusterPlaceCardModel(
            repositoryName: "baia",
            worktreeName: "ax-worktree",
            branch: "settings-rebuild ↑1",
            operation: nil,
            workingDirectory: "~/Projects/baia"
        )
        let card = ClusterPlaceCardView(model: model)
        check(card.window == nil, "the place card creates no window")
        check(card.accessibilityRole() == .group, "the place card role is group")
        check(card.accessibilityLabel() == "Place", "the place card has a spoken label")
        let rows = children(of: card)
        check(labels(rows) == [
            "repository, baia", "worktree, ax-worktree", "branch, settings-rebuild ↑1",
            "directory, ~/Projects/baia", "Copy path", "Reveal in Finder",
        ], "place facts and actions expose their complete text")
        check(rows.prefix(4).allSatisfy { $0.accessibilityRole() == .staticText }, "place facts are static text")
        check(rows.suffix(2).allSatisfy { $0.accessibilityRole() == .button }, "place actions are buttons")
        check(rows.prefix(4).allSatisfy { actionNames(of: $0).isEmpty }
            && rows.suffix(2).allSatisfy { actionNames(of: $0).contains(.press) },
            "only place action rows expose AXPress")
        check(rows.suffix(2).allSatisfy { !$0.isAccessibilityEnabled() }, "unwired place actions are disabled")

        var copyCount = 0
        var revealCount = 0
        var closeCount = 0
        card.onCopyPath = { copyCount += 1 }
        card.onReveal = { revealCount += 1 }
        card.onClose = { closeCount += 1 }
        if rows.count == 6 {
            check(press(rows[4]) && copyCount == 1, "Copy path AXPress uses the existing callback")
            check(press(rows[5]) && revealCount == 1, "Reveal AXPress uses the existing callback")
        }
        check(actionNames(of: card).contains(.cancel), "the card exposes the standard cancel action")
        check(cancel(card) && closeCount == 1, "AX cancel uses the existing onClose callback")

        var inFlightCopyCount = 0
        card.onCopyPath = { [weak card] in
            card?.invalidateActions()
            inFlightCopyCount += 1
        }
        check(press(rows[4]) && inFlightCopyCount == 1,
            "a place action already in flight completes while dismissal invalidates its card")
        check(rows.suffix(2).allSatisfy { !$0.isAccessibilityEnabled() },
            "a retained dismissed place card disables every action row")
        check(!press(rows[4]) && !press(rows[5]) && !cancel(card),
            "a retained dismissed place card refuses copy, reveal, and close")
        check(copyCount == 1 && revealCount == 1 && closeCount == 1,
            "dismissed place actions call no owner callback")
    }

    @MainActor
    private static func changesCardChecks() {
        print("=== production changes result fencing ===")
        let first = RepositoryFileChange(
            path: "Sources/Old.swift", index: .modified, kind: .ordinary
        )
        let second = RepositoryFileChange(
            path: "Notes.txt", kind: .untracked
        )
        let card = ClusterChangesCardView()
        card.changes = [first, second]
        var fileDiffs: [RepositoryFileChange] = []
        var fullDiffs = 0
        card.onFileDiff = { fileDiffs.append($0) }
        card.onFullDiff = { fullDiffs += 1 }

        check(card.window == nil, "the changes card creates no window")
        check(card.accessibilityRole() == .group && card.accessibilityLabel() == "Changes", "the changes card is a labelled group")
        let initial = children(of: card)
        check(labels(initial) == ["M  Sources/Old.swift", "A  Notes.txt", "Full diff"], "change rows expose drawn status and path text")
        check(initial.allSatisfy { $0.accessibilityRole() == .button }, "change and full-diff rows are buttons")
        check(initial.allSatisfy { actionNames(of: $0).contains(.press) }, "changes actions expose AXPress")
        if initial.count == 3 {
            check(press(initial[0]), "a changed-file row accepts AXPress")
            check(fileDiffs == [first], "file AXPress hands the exact change to onFileDiff")
            check(press(initial[2]) && fullDiffs == 1, "Full diff AXPress uses onFullDiff")
        }

        let obsolete = initial.first
        let replacement = RepositoryFileChange(path: "Sources/New.swift", worktree: .added, kind: .ordinary)
        card.changes = [replacement]
        check(!press(obsolete), "a retained row from an old changes result refuses")
        check(fileDiffs == [first], "an obsolete changes row calls no callback")

        let current = children(of: card).first
        card.onFileDiff = { change in
            fileDiffs.append(change)
            card.changes = [second]
        }
        check(press(current), "a reentrant current changes row completes its callback")
        check(fileDiffs.last == replacement, "reentrant result replacement cannot retarget the change argument")
        check(!press(current), "the row becomes obsolete after reentrant replacement")

        var closeCount = 0
        card.onClose = { closeCount += 1 }
        check(actionNames(of: card).contains(.cancel), "the changes card exposes the standard cancel action")
        check(cancel(card) && closeCount == 1, "changes AX cancel uses onClose")

        let retainedRows = children(of: card)
        let labelsBeforeDismissal = labels(retainedRows)
        card.onFileDiff = { [weak card] change in
            card?.invalidateActions()
            fileDiffs.append(change)
        }
        check(press(retainedRows.first) && fileDiffs.last == second,
            "a diff action already in flight completes while dismissal invalidates its card")
        card.changes = [replacement]
        check(labels(children(of: card)) == labelsBeforeDismissal,
            "a late changes result cannot publish into a dismissed retained card")
        check(retainedRows.allSatisfy { !$0.isAccessibilityEnabled() },
            "a retained dismissed changes card disables file and full-diff rows")
        check(retainedRows.allSatisfy { !press($0) } && !cancel(card),
            "a retained dismissed changes card refuses diff and close actions")
        check(fileDiffs.last == second && fullDiffs == 1 && closeCount == 1,
            "dismissed changes actions call no owner callback")
    }

    @MainActor
    private static func attentionCardChecks() {
        print("=== production attention facts and approval ===")
        let model = ClusterAttentionCardModel(
            agentLabel: "claude",
            state: "waiting",
            attention: "asking",
            approval: .init(title: "claude · baia", message: "Run migration?")
        )
        weak var weakCard: ClusterAttentionCardView?
        var retainedDeny: (any NSAccessibilityProtocol)?
        autoreleasepool {
            let card = ClusterAttentionCardView(model: model, theme: .darkPastel)
            weakCard = card
            check(card.window == nil, "the attention card creates no window")
            check(card.accessibilityRole() == .group && card.accessibilitySubrole() == .dialog && card.accessibilityLabel() == "Attention", "the attention card is a labelled dialog")
            let cardChildren = children(of: card)
            check(labels(Array(cardChildren.prefix(3))) == ["agent, claude", "state, waiting", "attention, asking"], "attention fact rows expose caption and value")
            guard let approval = cardChildren.last else {
                check(false, "the attention card exposes its embedded approval")
                return
            }
            check(approval.accessibilityRole() == .group, "the embedded approval is a semantic group")
            check(approval.accessibilityLabel() == "claude · baia", "the approval group is labelled by its title")
            let approvalChildren = children(of: approval)
            check(labels(approvalChildren) == ["claude · baia", "Run migration?", "Deny", "Approve"], "approval exposes title, message, and visual button order")
            check(approvalChildren.prefix(2).allSatisfy { $0.accessibilityRole() == .staticText }, "approval copy is static text")
            check(approvalChildren.suffix(2).allSatisfy { $0.accessibilityRole() == .button }, "approval actions are buttons")
            check(approvalChildren.prefix(2).allSatisfy { actionNames(of: $0).isEmpty }
                && approvalChildren.suffix(2).allSatisfy { actionNames(of: $0).contains(.press) },
                "only approval buttons expose AXPress")
            check(approvalChildren.suffix(2).allSatisfy { !$0.isAccessibilityEnabled() }, "approval actions are disabled before the owner is wired")

            var answers: [ApprovalPopover.Action] = []
            card.onApprovalAction = { answers.append($0) }
            let deny = approvalChildren.count == 4 ? approvalChildren[2] : nil
            let approve = approvalChildren.count == 4 ? approvalChildren[3] : nil
            check(deny?.isAccessibilityEnabled() == true && approve?.isAccessibilityEnabled() == true, "wiring the owner enables both approval actions")
            check(press(deny) && answers == [.deny], "Deny AXPress uses the existing approval callback")
            card.onApprovalAction = nil
            check(approve?.isAccessibilityEnabled() == false, "clearing the one-answer callback disables retained buttons")
            check(!press(approve) && answers == [.deny], "a disabled approval button refuses a second answer")

            if let approvalView = approval as? ApprovalPopoverView {
                let beforeReplacement = children(of: approvalView)
                let pressedBeforeReplacement = beforeReplacement.count == 4 ? beforeReplacement[3] : nil
                card.onApprovalAction = { action in
                    answers.append(action)
                    approvalView.messageText = "Replacement prompt"
                }
                check(press(pressedBeforeReplacement) && answers.last == .approve,
                    "an in-flight approval press completes its current callback")
                let afterReplacement = children(of: approvalView)
                check(afterReplacement.count == 4
                    && afterReplacement[1].accessibilityLabel() == "Replacement prompt"
                    && !identical(pressedBeforeReplacement, afterReplacement[3]),
                    "approval content replacement creates fresh semantic children")
                check(!press(pressedBeforeReplacement),
                    "the approval button becomes obsolete after reentrant replacement")
                let currentApprovalChildren = children(of: approvalView)
                let currentDeny = currentApprovalChildren.count == 4 ? currentApprovalChildren[2] : nil
                let currentApprove = currentApprovalChildren.count == 4 ? currentApprovalChildren[3] : nil
                card.onApprovalAction = { [weak card] action in
                    card?.invalidateActions()
                    answers.append(action)
                }
                check(press(currentApprove) && answers.last == .approve,
                    "an approval already in flight completes while dismissal invalidates its card")
                check(currentDeny?.isAccessibilityEnabled() == false
                    && currentApprove?.isAccessibilityEnabled() == false,
                    "a retained dismissed approval disables both answers")
                check(!press(currentDeny) && !press(currentApprove) && !cancel(card),
                    "a retained dismissed approval refuses deny, approve, and cancel")
            }
            retainedDeny = deny
        }
        check(weakCard == nil, "retaining a virtual approval child does not retain its old card")
        check(!press(retainedDeny), "an approval child retained past its card refuses")

        let closeOnly = ClusterAttentionCardView(
            model: .init(agentLabel: "claude", state: "working", attention: nil, approval: nil),
            theme: .darkPastel
        )
        var closeCount = 0
        closeOnly.onClose = { closeCount += 1 }
        check(actionNames(of: closeOnly).contains(.cancel), "the attention card exposes the standard cancel action")
        check(cancel(closeOnly) && closeCount == 1, "attention AX cancel uses onClose without approval")
    }
}
