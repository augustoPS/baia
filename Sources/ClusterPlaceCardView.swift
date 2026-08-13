import AppKit

/// One row of a cluster card, drawn rather than an `NSControl`.
///
/// The row idiom is hover and press as drawn washes, the click fired on
/// mouse-up inside the row, a drag off it cancelling, and a pointing hand over
/// anything clickable. `SidebarActionRowView` was where this file learned it and
/// named it here until 2026-08-12, when the owner's ruling removed that row as a
/// second face for the `New Tab` menu item; ``FileTreeRowsView`` is the idiom's
/// surviving statement in the sidebar and this is its statement in a card. The
/// class was never reused either way: that view was sidebar-coupled through
/// `PaneTheme` fills, a `ResolvedChrome` gate and a hard-coded label, and a card
/// row that fed those would be plumbing theme state this task deliberately
/// leaves out. Cards
/// follow the theme through window appearance alone, so every ink here is a
/// system colour resolved against the panel's `NSAppearance` (which
/// `ClusterCardController.isDark` sets from the theme's own derivation).
///
/// Two shapes in one class rather than two classes: a fact row (a caption and
/// a value, nothing clickable) and an action row (a label, hover, `onClick`).
/// Which one a row is falls out of whether ``onClick`` is set, so a row cannot
/// be styled clickable while going nowhere.
@MainActor
final class ClusterCardRowView: NSView {
    /// Fired on mouse-up inside the row. Nil makes this a fact row: no wash,
    /// no hand cursor, and a click lands on the card behind it.
    var onClick: (() -> Void)? {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    /// The leading caption of a fact row ("branch", "directory"), drawn
    /// secondary in its own fixed column. Nil for an action row, whose label
    /// starts at the inset.
    var caption: String? { didSet { needsDisplay = true } }

    /// The row's text: the fact's value, or the action's label.
    var text: String = "" { didSet { needsDisplay = true } }

    /// The text's font. Facts are terminal-adjacent strings (a branch, a
    /// path) and read monospaced at the footer's 11pt; action labels read as
    /// UI and stay on the system font. The card sets it per row.
    var font: NSFont = .systemFont(ofSize: 11) { didSet { needsDisplay = true } }

    private var isHovered = false { didSet { guard isHovered != oldValue else { return }; needsDisplay = true } }
    private var isPressed = false { didSet { guard isPressed != oldValue else { return }; needsDisplay = true } }

    override var isFlipped: Bool { true }

    /// Never first responder: the card view holds the keyboard for ⎋, and a
    /// row taking it would break that without gaining anything a click does
    /// not already deliver.
    override var acceptsFirstResponder: Bool { false }

    override func draw(_: NSRect) {
        if onClick != nil, isPressed || isHovered {
            // The sidebar row's two-step wash, in appearance terms: the label
            // ink at a whisper for hover, a little more for press.
            NSColor.labelColor.withAlphaComponent(isPressed ? 0.10 : 0.06).setFill()
            bounds.fill()
        }

        var x = Self.inset
        if let caption {
            let drawn = NSAttributedString(string: caption, attributes: [
                .font: Self.captionFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let size = drawn.size()
            drawn.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
            x += Self.captionColumn
        }

        // Truncated in the middle, not the tail: the strings that overflow
        // here are paths and branch names, and their distinguishing half is
        // usually the end.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let value = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        let height = value.size().height
        value.draw(
            with: NSRect(
                x: x,
                y: (bounds.height - height) / 2,
                width: max(0, bounds.width - x - Self.inset),
                height: height
            ),
            options: [.usesLineFragmentOrigin]
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        guard onClick != nil else { return }
        // `.activeAlways` rather than the sidebar row's `.activeInKeyWindow`:
        // the card lives in a nonactivating panel whose key status AppKit
        // does not count as "the key window" for tracking purposes, and a row
        // that only highlighted while some other window held key would read
        // as dead exactly when the card is in use.
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with _: NSEvent) { isHovered = true }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with _: NSEvent) {
        guard onClick != nil else { return }
        isPressed = true
    }

    /// Held rather than fired on the way down, the rule every drawn row in this
    /// app follows and ``FileTreeRowsView`` states: a press is a state the eye
    /// can see and a drag off the row cancels rather than acts.
    override func mouseDragged(with event: NSEvent) {
        guard onClick != nil else { return }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        guard wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func resetCursorRects() {
        guard onClick != nil else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    static let height: Double = 26

    private static let inset: Double = 14
    private static let captionColumn: Double = 76
    private static let captionFont = NSFont.systemFont(ofSize: 10, weight: .regular)
}

/// The place card: what springs from the capsule's place segment (design v6,
/// Task 5). The facts the pill's one word compresses, then the two verbs a
/// place supports today.
///
/// Fact rows first (repository, the worktree when the pane sits in a linked
/// one, the branch with its ahead/behind, the working directory), a hairline,
/// then the action rows. No worktree verbs yet, on purpose: the card grows a
/// verb when a task builds one, not a scaffolded empty menu before.
///
/// The card computes nothing. ``Model`` arrives assembled by the pane
/// controller from the same `PaneStatus.Git` the capsule reads, and the
/// actions are closures because the pasteboard and Finder effects belong to
/// the caller, the same split every sidebar row keeps.
///
/// Drawing matches ``ApprovalPopoverView``'s restraint: a flat fill, a
/// hairline stroke, hand-drawn text, no `NSControl`, no materials. Unlike the
/// popover there is no glass branch at all in this task; the card follows the
/// theme through the panel's appearance alone, so the fill and every ink are
/// system colours.
@MainActor
final class ClusterPlaceCardView: NSView {
    /// The card's facts, assembled by the caller.
    struct Model {
        var repositoryName: String

        /// The linked worktree's name, or nil for a main checkout, where the
        /// row is absent rather than restating ``repositoryName``.
        var worktreeName: String?

        /// `head ↑a↓b`, the footer's own spelling, or nil outside a
        /// repository.
        var branch: String?

        /// The operation the repository is halfway through (`REBASE`,
        /// `CHERRY-PICK`, …), or nil when it is not.
        ///
        /// **The pill says this too, and that is the stated exception to one
        /// home per fact.** The capsule's own rule is that a fact lives in one
        /// place, and the linked-worktree prefix obeys it by living here alone.
        /// This one is drawn twice on purpose, because the two draws answer
        /// different questions: the pill's segment is the *alarm* — it must be
        /// readable without a click, since it is what explains why the branch
        /// beside it has become a bare commit hash — and this row is the
        /// *caption*, the operation named next to the branch and the repository
        /// it applies to, where a reader who clicked through to understand the
        /// hash finds the two facts adjacent. Dropping the row would leave the
        /// place card describing a checkout while silently omitting the reason
        /// it is in the state it is in; dropping the segment would put the fact
        /// behind a click, which is exactly what a fact that changes the meaning
        /// of the pill's other facts cannot be.
        ///
        /// **Twice drawn, once decided.** The caller fills this from
        /// ``PaneChrome/PaneStatus/Git/displayableOperation``, the predicate the
        /// pill's segment is also built from, so "is there an operation to show"
        /// is answered in one place for both. Nil here therefore means the same
        /// thing it means on the pill, blanks included — this row read the raw
        /// field until 2026-08-13 and drew a captioned empty box for `"   "`.
        var operation: String?

        /// The pane's working directory, tilde-abbreviated for display. The
        /// full path stays with the caller, whose Copy path closure is the
        /// one place that needs it.
        var workingDirectory: String
    }

    var onCopyPath: (() -> Void)?
    var onReveal: (() -> Void)?

    /// Raised by ⎋. The card cannot dismiss itself; only its controller
    /// knows the panel.
    var onClose: (() -> Void)?

    /// Where the hairline between facts and actions draws, in this flipped
    /// view's coordinates. Solved once in `init`; the card never relayouts.
    private let separatorY: Double

    init(model: Model) {
        var facts: [(String, String, NSFont)] = [
            ("repository", model.repositoryName, Self.valueFont)
        ]
        if let worktree = model.worktreeName {
            facts.append(("worktree", worktree, Self.valueFont))
        }
        if let branch = model.branch {
            facts.append(("branch", branch, Self.valueFont))
        }
        // Directly under the branch, not above it as on the pill, and the two
        // orders are consistent rather than contradictory. The pill is read
        // left-to-right in one glance, so the operation leads there to colour
        // everything after it. The card is a list of captioned facts read
        // top-down, where the operation's job is to qualify the branch line the
        // eye has just landed on — a repository row, then the branch, then what
        // is being done to it.
        if let operation = model.operation {
            facts.append(("operation", operation, Self.valueFont))
        }
        facts.append(("directory", model.workingDirectory, Self.valueFont))

        let factsHeight = Double(facts.count) * ClusterCardRowView.height
        separatorY = Self.padding + factsHeight + Self.separatorGap / 2

        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: Self.width,
            height: Self.padding + factsHeight + Self.separatorGap
                + 2 * ClusterCardRowView.height + Self.padding
        ))

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

        y += Self.separatorGap
        let actions: [(String, () -> Void)] = [
            ("Copy path", { [weak self] in self?.onCopyPath?() }),
            ("Reveal in Finder", { [weak self] in self?.onReveal?() }),
        ]
        for (label, action) in actions {
            let row = ClusterCardRowView(frame: NSRect(
                x: 0, y: y, width: Self.width, height: ClusterCardRowView.height
            ))
            row.text = label
            row.font = Self.actionFont
            row.onClick = action
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
    /// grant, which is what routes ⎋ here.
    override var acceptsFirstResponder: Bool { true }

    /// ⎋ can arrive as `cancelOperation` rather than `keyDown`;
    /// ``ApprovalPopoverView`` documents the route on its own copy.
    override func cancelOperation(_: Any?) { onClose?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == Self.escapeKeyCode {
            onClose?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: separatorY, width: bounds.width, height: 1).fill()

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

    /// The approval popover's radius, so the cluster's panels read as one
    /// family.
    private static let cornerRadius: Double = 10
    private static let padding: Double = 8

    /// Air, hairline, air.
    private static let separatorGap: Double = 9

    private static let valueFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let actionFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    /// `kVK_Escape`, spelled as a literal for ``ApprovalPopoverView``'s
    /// reason: no Carbon is linked and the code is stable ABI.
    private static let escapeKeyCode: UInt16 = 0x35
}
