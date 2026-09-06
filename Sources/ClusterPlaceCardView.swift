import AppKit
import PaneChrome

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
        didSet {
            window?.invalidateCursorRects(for: self)
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
    }

    /// The owner-side availability behind an action row. `onClick` identifies
    /// the row as an action; this predicate prevents a retained row from acting
    /// after its card or result generation has been replaced.
    var isActionEnabled: (() -> Bool)? {
        didSet { NSAccessibility.post(element: self, notification: .layoutChanged) }
    }

    /// The leading caption of a fact row ("branch", "directory"), drawn
    /// secondary in its own fixed column. Nil for an action row, whose label
    /// starts at the inset.
    var caption: String? {
        didSet {
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .titleChanged)
        }
    }

    /// The row's text: the fact's value, or the action's label.
    var text: String = "" {
        didSet {
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .titleChanged)
        }
    }

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

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? {
        onClick == nil ? .staticText : .button
    }

    override func accessibilityLabel() -> String? {
        caption.map { "\($0), \(text)" } ?? text
    }

    override func accessibilityValue() -> Any? { text }

    override func isAccessibilityEnabled() -> Bool {
        guard onClick != nil else { return true }
        return isActionEnabled?() ?? true
    }

    override func accessibilityPerformPress() -> Bool { activate() }

    nonisolated override func accessibilityActionNames() -> [NSAccessibility.Action] {
        let row = self
        return MainActor.assumeIsolated { row.onClick == nil ? [] : [.press] }
    }

    nonisolated override func accessibilityPerformAction(_ action: NSAccessibility.Action) {
        guard action == .press else { return }
        let row = self
        MainActor.assumeIsolated { _ = row.accessibilityPerformPress() }
    }

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
        _ = activate()
    }

    @discardableResult
    private func activate() -> Bool {
        guard let onClick, isActionEnabled?() ?? true else { return false }
        onClick()
        return true
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
    /// The card's facts, assembled by ``PaneChrome/ClusterPlaceCardModel/make(anchorDisplayName:isLinkedWorktree:mainCheckoutName:git:workingDirectoryPath:home:)``
    /// (`Task 4`). Was this view's own nested `Model` until then; moved to
    /// `PaneChrome` so the derivation — the branch marker string, the
    /// linked-worktree repository-name substitution — can be tested without
    /// AppKit.
    typealias Model = ClusterPlaceCardModel

    var onCopyPath: (() -> Void)? {
        didSet { NSAccessibility.post(element: self, notification: .layoutChanged) }
    }
    var onReveal: (() -> Void)? {
        didSet { NSAccessibility.post(element: self, notification: .layoutChanged) }
    }

    /// Raised by ⎋. The card cannot dismiss itself; only its controller
    /// knows the panel.
    var onClose: (() -> Void)? {
        didSet { NSAccessibility.post(element: self, notification: .layoutChanged) }
    }

    private var rows: [ClusterCardRowView] = []
    private var actionsAreValid = true

    /// Ends this presentation's action lifetime. A dismissed card can remain
    /// alive when an accessibility client retains it, but none of its old
    /// callbacks may remain available or executable.
    func invalidateActions() {
        guard actionsAreValid else { return }
        actionsAreValid = false
        onCopyPath = nil
        onReveal = nil
        onClose = nil
    }

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
            rows.append(row)
            y += ClusterCardRowView.height
        }

        y += Self.separatorGap
        let actions: [(String, () -> Void, () -> Bool)] = [
            (
                "Copy path",
                { [weak self] in self?.copyPath() },
                { [weak self] in self?.actionsAreValid == true && self?.onCopyPath != nil }
            ),
            (
                "Reveal in Finder",
                { [weak self] in self?.reveal() },
                { [weak self] in self?.actionsAreValid == true && self?.onReveal != nil }
            ),
        ]
        for (label, action, enabled) in actions {
            let row = ClusterCardRowView(frame: NSRect(
                x: 0, y: y, width: Self.width, height: ClusterCardRowView.height
            ))
            row.text = label
            row.font = Self.actionFont
            row.onClick = action
            row.isActionEnabled = enabled
            addSubview(row)
            rows.append(row)
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

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? { "Place" }

    override func accessibilityChildren() -> [Any]? { rows }

    override func accessibilityPerformCancel() -> Bool {
        guard actionsAreValid, let onClose else { return false }
        onClose()
        return true
    }

    nonisolated override func accessibilityActionNames() -> [NSAccessibility.Action] { [.cancel] }

    nonisolated override func accessibilityPerformAction(_ action: NSAccessibility.Action) {
        guard action == .cancel else { return }
        let card = self
        MainActor.assumeIsolated { _ = card.accessibilityPerformCancel() }
    }

    /// ⎋ can arrive as `cancelOperation` rather than `keyDown`;
    /// ``ApprovalPopoverView`` documents the route on its own copy.
    override func cancelOperation(_: Any?) { _ = accessibilityPerformCancel() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == Self.escapeKeyCode {
            _ = accessibilityPerformCancel()
        } else {
            super.keyDown(with: event)
        }
    }

    private func copyPath() {
        guard actionsAreValid, let onCopyPath else { return }
        onCopyPath()
    }

    private func reveal() {
        guard actionsAreValid, let onReveal else { return }
        onReveal()
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
