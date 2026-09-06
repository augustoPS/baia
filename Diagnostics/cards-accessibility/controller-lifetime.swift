import AppKit
import GitWorkspace
import PaneChrome

/// The shipped `PalettePanel`'s two overrides, guarded by the runner against
/// `CommandPaletteController.swift`. `ClusterCardController` itself and every
/// card below are compiled from production source.
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private var failures = 0

private func check(_ passed: Bool, _ message: String) {
    if passed {
        print("  ok    \(message)")
    } else {
        failures += 1
        print("  FAIL  \(message)")
    }
}

private func pump(_ seconds: TimeInterval = 0.35) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if let event = NSApp.nextEvent(
            matching: .any,
            until: deadline,
            inMode: .default,
            dequeue: true
        ) {
            NSApp.sendEvent(event)
        }
    }
}

@MainActor
private func children(of element: any NSAccessibilityProtocol) -> [any NSAccessibilityProtocol] {
    element.accessibilityChildren() as? [any NSAccessibilityProtocol] ?? []
}

@MainActor
private func press(_ element: (any NSAccessibilityProtocol)?) -> Bool {
    element?.accessibilityPerformPress() ?? false
}

@MainActor
private func child(
    labelled label: String,
    of element: any NSAccessibilityProtocol
) -> (any NSAccessibilityProtocol)? {
    children(of: element).first { $0.accessibilityLabel() == label }
}

@main
enum CardControllerLifetimeFixture {
    @MainActor static func main() {
        _ = NSApplication.shared
        let host = NSWindow(
            contentRect: NSRect(x: 300, y: 300, width: 480, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        host.isReleasedWhenClosed = false
        host.makeKeyAndOrderFront(nil)

        let controller = ClusterCardController()
        let anchor = NSRect(x: 300, y: 280, width: 80, height: 20)

        retainedPlaceCardRefusesAfterDismiss(controller: controller, host: host, anchor: anchor)
        replacementInvalidatesChangesCard(controller: controller, host: host, anchor: anchor)
        approvalCannotSendAfterDismiss(controller: controller, host: host, anchor: anchor)
        resignKeyInvalidatesCard(controller: controller, host: host, anchor: anchor)

        controller.dismiss()
        host.orderOut(nil)
        host.close()
        print(failures == 0 ? "PASS" : "FAILED \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor
    private static func retainedPlaceCardRefusesAfterDismiss(
        controller: ClusterCardController,
        host: NSWindow,
        anchor: NSRect
    ) {
        print("=== direct dismissal lifetime ===")
        let card = ClusterPlaceCardView(model: ClusterPlaceCardModel(
            repositoryName: "baia",
            worktreeName: nil,
            branch: "settings-rebuild",
            operation: nil,
            workingDirectory: "~/Projects/baia"
        ))
        var copyCount = 0
        var closeCount = 0
        var invalidationCount = 0
        var dismissalCount = 0
        card.onCopyPath = { copyCount += 1 }
        card.onReveal = {}
        card.onClose = { [weak controller] in
            closeCount += 1
            controller?.dismiss()
        }
        let copy = child(labelled: "Copy path", of: card)

        controller.show(
            content: card,
            anchoredTo: anchor,
            in: host,
            invalidateActions: { [weak card] in
                invalidationCount += 1
                card?.invalidateActions()
            },
            onDismiss: { dismissalCount += 1 }
        )
        check(press(copy) && copyCount == 1, "a presented place action remains usable")
        controller.dismiss()
        controller.dismiss()

        check(invalidationCount == 1, "direct dismissal invalidates the presentation exactly once")
        check(dismissalCount == 1, "direct dismissal runs cleanup exactly once")
        check(copy?.isAccessibilityEnabled() == false && !press(copy),
            "a whole retained place card refuses its old action")
        check(!card.accessibilityPerformCancel() && closeCount == 0,
            "a dismissed retained card refuses its close route")

        let closeCard = ClusterPlaceCardView(model: ClusterPlaceCardModel(
            repositoryName: "close-route",
            worktreeName: nil,
            branch: nil,
            operation: nil,
            workingDirectory: "/tmp/close-route"
        ))
        var closeRouteCount = 0
        var closeInvalidationCount = 0
        var closeDismissalCount = 0
        closeCard.onClose = { [weak controller] in
            closeRouteCount += 1
            controller?.dismiss()
        }
        controller.show(
            content: closeCard,
            anchoredTo: anchor,
            in: host,
            invalidateActions: { [weak closeCard] in
                closeInvalidationCount += 1
                closeCard?.invalidateActions()
            },
            onDismiss: { closeDismissalCount += 1 }
        )
        check(closeCard.accessibilityPerformCancel() && closeRouteCount == 1,
            "the card close callback enters the production controller dismissal")
        check(closeInvalidationCount == 1 && closeDismissalCount == 1,
            "the close route invalidates and cleans up exactly once")
        check(!closeCard.accessibilityPerformCancel() && closeRouteCount == 1,
            "the retained card refuses a second close")
    }

    @MainActor
    private static func replacementInvalidatesChangesCard(
        controller: ClusterCardController,
        host: NSWindow,
        anchor: NSRect
    ) {
        print("=== replacement lifetime ===")
        let oldChange = RepositoryFileChange(
            path: "Sources/Old.swift", index: .modified, kind: .ordinary
        )
        let replacement = RepositoryFileChange(
            path: "Sources/Replacement.swift", worktree: .added, kind: .ordinary
        )
        let card = ClusterChangesCardView()
        card.changes = [oldChange]
        var diffs: [RepositoryFileChange] = []
        var invalidationCount = 0
        var dismissalCount = 0
        card.onFileDiff = { diffs.append($0) }
        card.onFullDiff = {}
        card.onClose = { [weak controller] in controller?.dismiss() }
        let retainedRow = child(labelled: "M  Sources/Old.swift", of: card)

        controller.show(
            content: card,
            anchoredTo: anchor,
            in: host,
            invalidateActions: { [weak card] in
                invalidationCount += 1
                card?.invalidateActions()
            },
            onDismiss: { dismissalCount += 1 }
        )

        let next = ClusterPlaceCardView(model: ClusterPlaceCardModel(
            repositoryName: "replacement",
            worktreeName: nil,
            branch: nil,
            operation: nil,
            workingDirectory: "/tmp/replacement"
        ))
        controller.show(
            content: next,
            anchoredTo: anchor,
            in: host,
            invalidateActions: { [weak next] in next?.invalidateActions() }
        )

        check(invalidationCount == 1 && dismissalCount == 1,
            "replacement ends the outgoing presentation exactly once")
        check(retainedRow?.isAccessibilityEnabled() == false && !press(retainedRow),
            "a retained outgoing changes row refuses after replacement")
        card.changes = [replacement]
        check(child(labelled: "M  Sources/Old.swift", of: card) != nil
            && child(labelled: "A  Sources/Replacement.swift", of: card) == nil,
            "a result arriving after replacement cannot republish old card content")
        check(diffs.isEmpty, "replacement invokes no obsolete diff callback")
    }

    @MainActor
    private static func approvalCannotSendAfterDismiss(
        controller: ClusterCardController,
        host: NSWindow,
        anchor: NSRect
    ) {
        print("=== approval dismissal lifetime ===")
        let card = ClusterAttentionCardView(
            model: ClusterAttentionCardModel(
                agentLabel: "agent",
                state: "waiting",
                attention: "asking",
                approval: .init(title: "agent · baia", message: "Approve command?")
            ),
            theme: .darkPastel
        )
        var answers: [ApprovalPopover.Action] = []
        var invalidationCount = 0
        var dismissalCount = 0
        card.onApprovalAction = { [weak controller] action in
            controller?.dismiss()
            answers.append(action)
        }
        card.onClose = { [weak controller] in controller?.dismiss() }
        let approval = children(of: card).last
        let approve = approval.flatMap { child(labelled: "Approve", of: $0) }

        controller.show(
            content: card,
            anchoredTo: anchor,
            in: host,
            invalidateActions: { [weak card] in
                invalidationCount += 1
                card?.invalidateActions()
            },
            onDismiss: { dismissalCount += 1 }
        )
        check(press(approve) && answers == [.approve],
            "an in-flight approval completes through the production callback")
        check(invalidationCount == 1 && dismissalCount == 1,
            "approval dismissal invalidates and cleans up exactly once")
        check(approve?.isAccessibilityEnabled() == false && !press(approve),
            "a retained dismissed approval cannot send again")
        check(!card.accessibilityPerformCancel() && answers == [.approve],
            "dismissed approval and cancel routes send no further answer")
    }

    @MainActor
    private static func resignKeyInvalidatesCard(
        controller: ClusterCardController,
        host: NSWindow,
        anchor: NSRect
    ) {
        print("=== resign-key dismissal lifetime ===")
        let card = ClusterPlaceCardView(model: ClusterPlaceCardModel(
            repositoryName: "resign-route",
            worktreeName: nil,
            branch: nil,
            operation: nil,
            workingDirectory: "/tmp/resign-route"
        ))
        var copyCount = 0
        var invalidationCount = 0
        var dismissalCount = 0
        card.onCopyPath = { copyCount += 1 }
        card.onReveal = {}
        card.onClose = { [weak controller] in controller?.dismiss() }
        let retainedCopy = child(labelled: "Copy path", of: card)

        controller.show(
            content: card,
            anchoredTo: anchor,
            in: host,
            invalidateActions: { [weak card] in
                invalidationCount += 1
                card?.invalidateActions()
            },
            onDismiss: { dismissalCount += 1 }
        )
        host.makeKey()
        pump()
        controller.dismiss()

        check(invalidationCount == 1 && dismissalCount == 1,
            "resign-key invalidates and cleans up exactly once")
        check(retainedCopy?.isAccessibilityEnabled() == false && !press(retainedCopy),
            "a card retained after resign-key refuses its actions")
        check(copyCount == 0, "resign-key invokes no obsolete action callback")
    }
}
