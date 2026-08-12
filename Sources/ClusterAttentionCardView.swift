import AppKit
import PaneChrome

/// The attention card: what springs from the capsule's agent segment and its
/// attention dot both (design v6, Task 6). One card for the two segments,
/// because they describe one thing: the agent running in the pane, and how
/// hard it is asking for the owner.
///
/// Fact rows first, the family shape ``ClusterPlaceCardView`` set: the
/// agent's label, its state (`working`/`waiting`, `PaneStatus.Agent.isBusy`'s
/// own vocabulary), and the attention level spelled by
/// `PaneStatus.Attention.name(of:)`, which is the one place the levels have
/// names. Below them, when an approval is pending, the approval itself:
/// ``ApprovalPopoverView`` embedded whole rather than forked, so the message,
/// the two buttons, and what ⏎/⎋ mean are the standalone popover's own code
/// with no second copy to drift. The embedded view draws its own panel fill
/// and hairline outline, which reads here as an inset unit inside the card;
/// accepted, because the alternative is forking the view to strip its chrome.
///
/// The card computes nothing. ``Model`` arrives assembled by the pane
/// controller from the same `PaneStatus.Agent` the capsule reads, and the
/// approval's answer is a closure because the bytes belong to the pane
/// (`TerminalPaneController.send(_:)`), the same split every card keeps.
///
/// Drawing follows ``ClusterPlaceCardView``: system colours over the panel's
/// appearance, hand-drawn rows, no materials. The one deviation is `theme`,
/// taken at `init` for the embedded ``ApprovalPopoverView`` alone, which is
/// themed (its inks come from `PaneTheme`, not the appearance) and cannot be
/// handed system colours without forking it.
@MainActor
final class ClusterAttentionCardView: NSView {
    /// The card's facts, assembled by the caller. All display values: the
    /// caller derives the words, this view only places them.
    struct Model {
        /// The agent's label, or nil when it is empty, where the row is
        /// absent rather than blank.
        var agentLabel: String?

        /// `working` or `waiting`, from `PaneStatus.Agent.isBusy`.
        var state: String?

        /// `asking`, `acknowledged` or `done`, from
        /// `PaneStatus.Attention.name(of:)`, or nil when the pane is not
        /// asking, where the row is absent.
        var attention: String?

        /// Present exactly when the standalone popover would present
        /// (`ApprovalPopover.presents(for:)`); the caller applies that gate.
        var approval: Approval?

        /// What the embedded ``ApprovalPopoverView`` shows: the same title
        /// and body the standalone presentation would be handed.
        struct Approval {
            var title: String
            var message: String
        }
    }

    /// The embedded approval's answer, raised by a button click or by ⏎/⎋.
    /// The caller writes the bytes and dismisses the card.
    var onApprovalAction: ((ApprovalPopover.Action) -> Void)?

    /// Raised by ⎋ while no approval is embedded. The card cannot dismiss
    /// itself; only its controller knows the panel. With an approval embedded
    /// ⎋ is Deny instead — see ``keyDown(with:)``.
    var onClose: (() -> Void)?

    /// The embedded approval, or nil when nothing is pending. Held so the
    /// key-event forwarding below has a target.
    private let approvalView: ApprovalPopoverView?

    /// Where the hairline between facts and the approval draws, or nil when
    /// no approval is embedded and the card is facts alone.
    private let separatorY: Double?

    init(model: Model, theme: PaneTheme) {
        var facts: [(String, String, NSFont)] = []
        if let label = model.agentLabel {
            // The label is terminal-adjacent (a process's name), so it reads
            // monospaced like the place card's branch and path.
            facts.append(("agent", label, Self.valueFont))
        }
        if let state = model.state {
            facts.append(("state", state, Self.stateFont))
        }
        if let attention = model.attention {
            facts.append(("attention", attention, Self.stateFont))
        }

        let factsHeight = Double(facts.count) * ClusterCardRowView.height

        if let approval = model.approval {
            separatorY = Self.padding + factsHeight + Self.separatorGap / 2
            let approvalWidth = Self.width - 2 * Self.approvalInset
            let approvalHeight = ApprovalPopoverView.measuredHeight(
                forMessage: approval.message,
                width: approvalWidth
            )
            let view = ApprovalPopoverView(frame: NSRect(
                x: Self.approvalInset,
                y: Self.padding + factsHeight + Self.separatorGap,
                width: approvalWidth,
                height: approvalHeight
            ))
            view.theme = theme
            // `resolvedChrome` stays `.flat`, the view's own default: the
            // card family carries no glass branch at all (Task 5's rule), and
            // an inset glass unit inside a flat card would be the one place
            // in the app glass appears without its window-level plumbing.
            view.title = approval.title
            view.messageText = approval.message
            approvalView = view
            super.init(frame: NSRect(
                x: 0,
                y: 0,
                width: Self.width,
                height: Self.padding + factsHeight + Self.separatorGap
                    + approvalHeight + Self.padding
            ))
            addSubview(view)
            view.onAction = { [weak self] action in
                self?.onApprovalAction?(action)
            }
            // The view lays its internal content sibling out in `layout()`,
            // which the standalone panel's resize triggers; embedded, the
            // frame above is the only geometry event, so ask for the pass
            // explicitly rather than rely on first display scheduling one.
            view.needsLayout = true
        } else {
            separatorY = nil
            approvalView = nil
            super.init(frame: NSRect(
                x: 0,
                y: 0,
                width: Self.width,
                height: Self.padding + factsHeight + Self.padding
            ))
        }

        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true

        var y = Self.padding
        for (caption, value, font) in facts {
            let row = ClusterCardRowView(frame: NSRect(
                x: 0, y: y, width: Self.width, height: ClusterCardRowView.height
            ))
            row.caption = caption
            row.text = value
            row.font = font
            addSubview(row)
            y += ClusterCardRowView.height
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("baia does not use nibs")
    }

    override var isFlipped: Bool { true }

    /// First responder while presented, by ``ClusterCardController``'s direct
    /// grant (`show` calls `makeFirstResponder(content)` with this card).
    ///
    /// **The adaptation from the standalone popover's routing.** There the
    /// panel's first responder is ``ApprovalPopoverView`` itself, which is
    /// what routes ⏎/⎋ to its `keyDown`/`cancelOperation`. Here the panel's
    /// first responder is this card, so the two key entry points below
    /// forward to the embedded view's identical handlers rather than
    /// re-deriving what the keys mean. One responder, the standalone's own
    /// arrangement, with a one-hop forward as the whole difference.
    override var acceptsFirstResponder: Bool { true }

    /// ⎋ can arrive as `cancelOperation` rather than `keyDown`;
    /// ``ApprovalPopoverView`` documents the route on its own copy. With an
    /// approval embedded the forward makes ⎋ mean Deny, exactly what it
    /// means in the standalone popover; without one it closes the card, the
    /// other cards' rule.
    override func cancelOperation(_ sender: Any?) {
        if let approvalView {
            approvalView.cancelOperation(sender)
        } else {
            onClose?()
        }
    }

    override func keyDown(with event: NSEvent) {
        // Only ⏎ and ⎋ forward — the two keys the embedded view answers.
        // Forwarding everything would loop: the view's own `default:` calls
        // `super.keyDown`, NSResponder hands an unhandled key to the next
        // responder, and embedded that is this card (its superview), which
        // would forward straight back. The standalone arrangement never
        // meets this because there the view is the panel's contentView and
        // its next responder is the panel, not another forwarder. The
        // filter is what breaks the card → view → card cycle, so any other
        // key falls through to the card's own branches below.
        if let approvalView,
           event.keyCode == Self.returnKeyCode || event.keyCode == Self.escapeKeyCode {
            approvalView.keyDown(with: event)
        } else if event.keyCode == Self.escapeKeyCode {
            onClose?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        if let separatorY {
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: separatorY, width: bounds.width, height: 1).fill()
        }

        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Self.cornerRadius,
            yRadius: Self.cornerRadius
        )
        path.lineWidth = 1
        NSColor.separatorColor.setStroke()
        path.stroke()
    }

    static let width: Double = 300

    /// ``ClusterPlaceCardView``'s own metrics, so the cards read as one
    /// family.
    private static let cornerRadius: Double = 10
    private static let padding: Double = 8
    private static let separatorGap: Double = 9

    /// Air around the embedded approval, so its own rounded outline draws
    /// inside the card's rather than on top of it.
    private static let approvalInset: Double = 8

    private static let valueFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    /// State and attention are UI words, not terminal strings, so they stay
    /// on the system font — the same split the place card makes between fact
    /// values and action labels.
    private static let stateFont = NSFont.systemFont(ofSize: 11, weight: .regular)

    /// `kVK_Return` and `kVK_Escape`, spelled as literals for
    /// ``ApprovalPopoverView``'s reason: no Carbon is linked and the codes
    /// are stable ABI.
    private static let returnKeyCode: UInt16 = 0x24
    private static let escapeKeyCode: UInt16 = 0x35
}
