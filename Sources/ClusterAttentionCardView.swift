import AppKit
import BaiaSettings
import PaneChrome

private nonisolated final class ApprovalAccessibilityElement: NSAccessibilityElement {
    enum Kind {
        case title
        case message
        case action(ApprovalPopover.Action)
    }

    weak var approvalView: ApprovalPopoverView?
    let kind: Kind
    let generation: Int

    init(approvalView: ApprovalPopoverView, kind: Kind, generation: Int) {
        self.approvalView = approvalView
        self.kind = kind
        self.generation = generation
        super.init()
    }

    override func accessibilityParent() -> Any? { approvalView }

    override func accessibilityRole() -> NSAccessibility.Role? {
        switch kind {
        case .title, .message: .staticText
        case .action: .button
        }
    }

    override func accessibilityLabel() -> String? {
        guard let approvalView else { return nil }
        let kind = kind
        return MainActor.assumeIsolated { approvalView.accessibilityLabel(for: kind) }
    }

    override func accessibilityFrame() -> NSRect {
        guard let approvalView else { return .zero }
        let kind = kind
        return MainActor.assumeIsolated { approvalView.accessibilityFrame(for: kind) }
    }

    override func isAccessibilityEnabled() -> Bool {
        guard let approvalView else { return false }
        let kind = kind
        let generation = generation
        return MainActor.assumeIsolated {
            approvalView.isAccessibilityEnabled(for: kind, generation: generation)
        }
    }

    override func accessibilityActionNames() -> [NSAccessibility.Action] {
        switch kind {
        case .title, .message: []
        case .action: [.press]
        }
    }

    override func accessibilityPerformAction(_ action: NSAccessibility.Action) {
        guard action == .press else { return }
        _ = accessibilityPerformPress()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let approvalView, case let .action(action) = kind else { return false }
        let generation = generation
        return MainActor.assumeIsolated {
            approvalView.accessibilityPerformPress(action, generation: generation)
        }
    }
}

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
/// ``ApprovalPopoverView`` embedded whole, so the message, the two buttons,
/// and what ⏎/⎋ mean are one piece of code with no second copy to drift. The
/// embedded view draws its own panel fill and hairline outline, which reads
/// here as an inset unit inside the card; accepted, because the alternative
/// is forking the view to strip its chrome.
///
/// **`ApprovalPopoverView` lives in this file since Task 4.** It was a
/// standalone popover's content view, shared with a separate
/// `ApprovalPopoverController` that presented it as its own floating panel —
/// "a second door into the same room", in this card's own words while both
/// doors stood. That door is retired: this card is the only door as of Task
/// 4, and the view it opens onto has no reason to live anywhere else. Moved
/// here verbatim rather than redesigned; its own doc comments below still
/// describe the standalone panel's routing where that is what explains a
/// choice (⏎/⎋ needing a first responder, `cancelOperation`'s AppKit
/// quirk), because both facts are still true of this card's own panel.
///
/// The card computes nothing. ``Model`` arrives assembled by the pane
/// controller from the same `PaneStatus.Agent` the capsule reads
/// (``PaneChrome/ClusterAttentionCardModel/make(status:attentionMessage:)``),
/// and the approval's answer is a closure because the bytes belong to the
/// pane (`TerminalPaneController.send(_:)`), the same split every card keeps.
///
/// Drawing follows ``ClusterPlaceCardView``: system colours over the panel's
/// appearance, hand-drawn rows, no materials. The one deviation is `theme`,
/// taken at `init` for the embedded ``ApprovalPopoverView`` alone, which is
/// themed (its inks come from `PaneTheme`, not the appearance) and cannot be
/// handed system colours without forking it.
@MainActor
final class ClusterAttentionCardView: NSView {
    /// The card's facts, assembled by
    /// ``PaneChrome/ClusterAttentionCardModel/make(status:attentionMessage:)``
    /// (`Task 4`). Was this view's own nested `Model` until then; moved to
    /// `PaneChrome` so the `agent · repo` title rule and the approval gate can
    /// be tested without AppKit.
    typealias Model = ClusterAttentionCardModel

    /// The embedded approval's answer, raised by a button click or by ⏎/⎋.
    /// The caller writes the bytes and dismisses the card.
    var onApprovalAction: ((ApprovalPopover.Action) -> Void)? {
        didSet {
            approvalView?.accessibilityAvailabilityChanged()
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
    }

    /// Raised by ⎋ while no approval is embedded. The card cannot dismiss
    /// itself; only its controller knows the panel. With an approval embedded
    /// ⎋ is Deny instead — see ``keyDown(with:)``.
    var onClose: (() -> Void)? {
        didSet { NSAccessibility.post(element: self, notification: .layoutChanged) }
    }

    /// The embedded approval, or nil when nothing is pending. Held so the
    /// key-event forwarding below has a target.
    private let approvalView: ApprovalPopoverView?
    private var rows: [ClusterCardRowView] = []
    private var actionsAreValid = true

    /// Ends this presentation's action lifetime. The whole card may remain
    /// retained by an accessibility client after dismissal, so both answers
    /// and the close route are cleared independently of object lifetime.
    func invalidateActions() {
        guard actionsAreValid else { return }
        actionsAreValid = false
        onApprovalAction = nil
        onClose = nil
    }

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
                self?.performApproval(action)
            }
            view.isActionAvailable = { [weak self] in
                self?.actionsAreValid == true && self?.onApprovalAction != nil
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

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .dialog }

    override func accessibilityLabel() -> String? { "Attention" }

    override func accessibilityChildren() -> [Any]? {
        if let approvalView { return rows + [approvalView] }
        return rows
    }

    override func accessibilityPerformCancel() -> Bool {
        if let approvalView {
            return approvalView.accessibilityPerform(action: .deny)
        }
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
    /// ``ApprovalPopoverView`` documents the route on its own copy. With an
    /// approval embedded the forward makes ⎋ mean Deny, exactly what it
    /// means in the standalone popover; without one it closes the card, the
    /// other cards' rule.
    override func cancelOperation(_ sender: Any?) {
        if let approvalView {
            approvalView.cancelOperation(sender)
        } else {
            _ = accessibilityPerformCancel()
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
            _ = accessibilityPerformCancel()
        } else {
            super.keyDown(with: event)
        }
    }

    private func performApproval(_ action: ApprovalPopover.Action) {
        guard actionsAreValid, let onApprovalAction else { return }
        onApprovalAction(action)
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

/// `NSGlassEffectView`, with the same refusals every other popover-owned glass
/// backing in this app makes (the palette's own copy carries the identical doc
/// comment, and `PaneStatusBarView`'s did until that view was deleted on
/// 2026-08-13): a plain `NSGlassEffectView`
/// hit-tests itself, and ``ApprovalPopoverView`` relies on the buttons
/// underneath it (in ``ApprovalPopoverContentView``) receiving every click.
private final class ApprovalPopoverGlassBacking: NSGlassEffectView {
    override var acceptsFirstResponder: Bool { false }

    override var canBecomeKeyView: Bool { false }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// The title, body and buttons, drawn above ``ApprovalPopoverGlassBacking``
/// rather than in ``ApprovalPopoverView/draw(_:)`` itself.
///
/// `draw(_:)` is a view's own base layer, which every subview (including a
/// glass backing) renders above — the same fact `PaneStatusBarView.draw(_:)`
/// documented on its own copy of this split before it was deleted. Content painted in the parent's
/// `draw(_:)` would sit *under* the glass and be blurred and refracted along
/// with it, so the title, the message and both capsules live in this sibling
/// view instead, stacked above the backing.
///
/// Returns nil from `hitTest` for the same reason `PaneStatusContentView` and
/// `CommandPaletteController`'s own content children do: the parent
/// (``ApprovalPopoverView``) is what stays first responder and answers
/// `mouseDown`/`mouseUp` for the buttons and ⏎/⎋, and a child that accepted
/// hits would take the click before the parent ever saw it.
private final class ApprovalPopoverContentView: NSView {
    var render: ((NSRect) -> Void)?

    override func draw(_: NSRect) { render?(bounds) }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { false }

    override var canBecomeKeyView: Bool { false }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// The approval popover's content: the title, the message, and the two
/// buttons. Design v5 §6.
///
/// A plain `NSView` drawing everything itself rather than `NSButton`s for the
/// two capsules. Nothing in this popover sits inside a pane — it is its own
/// panel, the same as the palette and the find panel — so the first-responder
/// rule that forbids `NSControl` in a pane does not reach here. Drawn anyway,
/// for one reason specific to this surface: ⏎ and ⎋ are already bound to
/// Approve and Deny while the popover holds the keyboard (the controller's own
/// key handling), and a real `NSButton` bound to the same keys through
/// `keyEquivalent` would fight the controller for which one answers a key
/// press. Drawn buttons keep exactly one place deciding what a key does.
final class ApprovalPopoverView: NSView {
    var theme: PaneTheme = .darkPastel {
        didSet {
            needsDisplay = true
            contentView.needsDisplay = true
        }
    }

    /// Flat, unchanged, or glass with the menu material, mirroring the palette's
    /// own copy (and `PaneStatusBarView.resolvedChrome`, until that view was
    /// deleted on 2026-08-13).
    var resolvedChrome: ResolvedChrome = .flat {
        didSet {
            guard resolvedChrome != oldValue else { return }
            applyResolvedChrome()
        }
    }

    /// Which of the four fill roles this popover's glass is tinted with, or nil
    /// for the untinted glass that ships.
    ///
    /// Nil unless the debug design panel has pointed this surface somewhere, and
    /// in Release it can hold nothing else. See ``SurfaceFill``.
    var fillMaterial: DesignOverrides.Chrome.Material? {
        didSet {
            guard fillMaterial != oldValue else { return }
            updateGlassMaterial()
        }
    }

    /// `agent · repo`, or the bare repo name when no agent is running.
    var title: String = "" {
        didSet {
            contentView.needsDisplay = true
            replaceAccessibilityChildren()
        }
    }

    /// The attention message verbatim, or ``ApprovalPopover/body(for:)``'s
    /// fallback. Set by the caller, which is the one place that knows both
    /// the reported message and the fallback rule.
    var messageText: String = "" {
        didSet {
            contentView.needsDisplay = true
            replaceAccessibilityChildren()
        }
    }

    /// Which button, if any, currently reads as pressed: the mouse is down
    /// inside it. ⏎/⎋ commit straight through ``keyDown(with:)`` without ever
    /// setting this — a key press dismisses the popover in the same turn, so
    /// there is no frame in which a pressed key state would be seen. Drawn as
    /// a filled highlight; nothing here is a real `NSControl` so there is no
    /// system pressed state to inherit.
    private var pressedAction: ApprovalPopover.Action?

    var onAction: ((ApprovalPopover.Action) -> Void)? {
        didSet { accessibilityAvailabilityChanged() }
    }

    var isActionAvailable: (() -> Bool)? {
        didSet { accessibilityAvailabilityChanged() }
    }

    private var accessibilityGeneration = 0
    private var accessibilityElements: [ApprovalAccessibilityElement]?

    private var glassBacking: ApprovalPopoverGlassBacking?

    /// Title, body and buttons, stacked above ``glassBacking`` so glass never
    /// composites over them. See ``ApprovalPopoverContentView``'s own doc
    /// comment for why this has to be a sibling rather than this view's own
    /// `draw(_:)`. Always a subview (flat has no glass to sit above, but the
    /// content still needs to live somewhere), added once in `init` and never
    /// torn down the way ``glassBacking`` is.
    private let contentView = ApprovalPopoverContentView(frame: .zero)

    /// This view is first responder while the popover is up (the controller
    /// makes it so on presenting), which is what design v5 §6's "⏎/⎋ map to
    /// the buttons only while the popover is presented" needs: a borderless
    /// `NSPanel` with no field inside it still routes key events to whatever
    /// the window's first responder is, and this view is the only thing in
    /// this window that could be it. Nothing here joins a pane's key view
    /// loop or fights `AppTerminalView.performKeyEquivalent` for first
    /// responder — this popover is its own window, the same exemption
    /// ``PaletteQueryField`` already carries.
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? { title }

    override func accessibilityChildren() -> [Any]? {
        if let accessibilityElements { return accessibilityElements }
        let generation = accessibilityGeneration
        let elements = [
            ApprovalAccessibilityElement(approvalView: self, kind: .title, generation: generation),
            ApprovalAccessibilityElement(approvalView: self, kind: .message, generation: generation),
            ApprovalAccessibilityElement(approvalView: self, kind: .action(.deny), generation: generation),
            ApprovalAccessibilityElement(approvalView: self, kind: .action(.approve), generation: generation),
        ]
        accessibilityElements = elements
        return elements
    }

    fileprivate func accessibilityLabel(for kind: ApprovalAccessibilityElement.Kind) -> String {
        switch kind {
        case .title: title
        case .message: messageText
        case let .action(action): Self.title(for: action)
        }
    }

    fileprivate func accessibilityFrame(for kind: ApprovalAccessibilityElement.Kind) -> NSRect {
        let rect: NSRect
        switch kind {
        case .title:
            rect = NSRect(x: Self.inset, y: Self.inset, width: bounds.width - 2 * Self.inset, height: Self.titleHeight)
        case .message:
            rect = bodyRect
        case let .action(action):
            rect = self.rect(for: action)
        }
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }

    fileprivate func isAccessibilityEnabled(
        for kind: ApprovalAccessibilityElement.Kind,
        generation: Int
    ) -> Bool {
        guard generation == accessibilityGeneration else { return false }
        return switch kind {
        case .title, .message: true
        case .action: onAction != nil && (isActionAvailable?() ?? true)
        }
    }

    fileprivate func accessibilityPerformPress(
        _ action: ApprovalPopover.Action,
        generation: Int
    ) -> Bool {
        guard generation == accessibilityGeneration else { return false }
        return accessibilityPerform(action: action)
    }

    fileprivate func accessibilityAvailabilityChanged() {
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private func replaceAccessibilityChildren() {
        accessibilityGeneration &+= 1
        accessibilityElements = nil
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// Escape does not reach `keyDown(with:)` as reliably as Return does,
    /// because AppKit can route it through `cancelOperation(_:)` on the
    /// responder chain first — the same fact ``PaletteQueryField`` documents
    /// on its own copy of this override. Caught here as well so Deny answers
    /// however Escape arrives.
    override func cancelOperation(_: Any?) {
        _ = accessibilityPerform(action: .deny)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case Self.returnKeyCode: _ = accessibilityPerform(action: .approve)
        case Self.escapeKeyCode: _ = accessibilityPerform(action: .deny)
        default: super.keyDown(with: event)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true

        contentView.render = { [weak self] bounds in self?.drawContent(in: bounds) }
        addSubview(contentView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("baia does not use nibs")
    }

    override var isFlipped: Bool { true }

    // MARK: - Chrome material

    private var materialSet: MaterialSet? {
        switch resolvedChrome {
        case .flat: nil
        case let .glass(set): set
        }
    }

    /// **Untinted glass (Task 2) is still what ships.** `backing.tintColor` used
    /// to carry `set.fillMenu`; the tint is nil now, the same untinted glass the
    /// pane's own plane (`PaneGlassPlaneView`) ships with, at the native style
    /// the set names.
    ///
    /// ``fillMaterial`` can put the tint back and only the debug design panel
    /// can set it. The `.glass` case binds its `set` for the creation-time
    /// style alone; ``updateGlassMaterial()`` re-reads ``resolvedChrome`` for
    /// the style and the tint on every pass, so a tint written before the
    /// backing existed still lands and a live `liquidGlass`/`sheer` switch
    /// reaches an existing backing. See ``SurfaceFill``.
    private func applyResolvedChrome() {
        switch resolvedChrome {
        case .flat:
            glassBacking?.removeFromSuperview()
            glassBacking = nil
        case let .glass(set):
            let backing: ApprovalPopoverGlassBacking
            if let existing = glassBacking {
                backing = existing
            } else {
                backing = ApprovalPopoverGlassBacking(frame: bounds)
                backing.style = NSGlassEffectView.Style(set.nativeStyle)
                backing.wantsLayer = true
                // Below `contentView`, not below every subview: `nil` here
                // would still be above this view's own `draw(_:)` layer (an
                // `NSView`'s base layer always renders under its subviews
                // regardless of subview order), but ordering explicitly
                // against `contentView` is what keeps the title, body and
                // buttons stacked above the glass rather than under it.
                addSubview(backing, positioned: .below, relativeTo: contentView)
                glassBacking = backing
            }
            backing.frame = bounds
        }
        updateGlassMaterial()
        needsDisplay = true
        // `effectiveBackground` (and so the body's ink) depends on
        // `materialSet`, which just changed.
        contentView.needsDisplay = true
    }

    /// Writes the set's native style and ``fillMaterial``'s colour onto the
    /// backing; the colour is nil in what ships and in every Release build.
    private func updateGlassMaterial() {
        guard let glassBacking, let materialSet else { return }
        glassBacking.style = NSGlassEffectView.Style(materialSet.nativeStyle)
        glassBacking.tintColor = SurfaceFill.colour(fillMaterial, in: materialSet)
    }

    override func layout() {
        super.layout()
        glassBacking?.frame = bounds
        contentView.frame = bounds
    }

    // MARK: - Drawing

    /// This view's own base layer: the flat fill (glass draws none, Task 2)
    /// and the hairline stroke. Everything else lives in ``contentView``, a
    /// sibling stacked above ``glassBacking`` — see
    /// ``ApprovalPopoverContentView``'s doc comment for why the split exists.
    override func draw(_: NSRect) {
        if materialSet == nil {
            nsColor(theme.panelBackground).setFill()
            bounds.fill()
        }

        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        path.lineWidth = 1
        nsColor(theme.hairline).setStroke()
        path.stroke()
    }

    private func drawContent(in _: NSRect) {
        drawTitle()
        drawBody()
        drawButtons()
    }

    private func drawTitle() {
        let string = NSAttributedString(string: title, attributes: [
            .font: Self.titleFont,
            .foregroundColor: nsColor(theme.foreground),
        ])
        string.draw(at: NSPoint(x: Self.inset, y: Self.inset))
    }

    /// The message, wrapped rather than truncated: it is the whole reason the
    /// popover is open, and a body cut to one line could hide the part of the
    /// prompt that matters.
    private func drawBody() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let string = NSAttributedString(string: messageText, attributes: [
            .font: Self.bodyFont,
            .foregroundColor: nsColor(theme.color(for: .normal, focused: true, on: effectiveBackground)),
            .paragraphStyle: paragraph,
        ])
        string.draw(with: bodyRect, options: [.usesLineFragmentOrigin])
    }

    private func drawButtons() {
        for action in ApprovalPopover.Action.allCases {
            drawButton(action, in: rect(for: action))
        }
    }

    private func drawButton(_ action: ApprovalPopover.Action, in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        let pressed = pressedAction == action
        let fill: RGB
        let ink: RGB
        switch action {
        case .approve:
            fill = pressed ? theme.focusedAccent.blended(with: theme.background, fraction: 0.12) : theme.focusedAccent
            ink = theme.ink(on: theme.focusedAccent)
            nsColor(fill).setFill()
            path.fill()
        case .deny:
            // Clear fill: only the stroke, so Approve stays the one accented
            // control in the overlay, per the plan. The pressed state still
            // needs some fill to read as pressed at all, so it borrows the
            // same neutral wash a selected row wears rather than reaching for
            // the accent Deny is deliberately drawn without.
            ink = theme.foreground
            if pressed {
                nsColor(theme.selectedRowBackground).setFill()
                path.fill()
            }
            nsColor(theme.hairline).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        let label = "\(Self.title(for: action))  \(Self.glyph(for: action))"
        let string = NSAttributedString(string: label, attributes: [
            .font: Self.buttonFont,
            .foregroundColor: nsColor(ink),
        ])
        let size = string.size()
        string.draw(at: NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2
        ))
    }

    /// The surface the body text is judged readable against:
    /// `theme.panelBackground`, unconditionally, on both flat and glass now.
    ///
    /// **Task 2, superseding Task 4's original clause.** See
    /// `PaneStatusBarView.effectiveBarFill` for the measured reason grading
    /// against a flattened menu-fill swatch was dropped in favour of the same
    /// ungraded ink flat always used: the repair chain now applies to the
    /// flat/Reduce-Transparency rendering only.
    private var effectiveBackground: RGB {
        theme.panelBackground
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressedAction = ApprovalPopover.Action.allCases.first { rect(for: $0).contains(point) }
        contentView.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressedAction = nil
            contentView.needsDisplay = true
        }
        let point = convert(event.locationInWindow, from: nil)
        guard let action = pressedAction, rect(for: action).contains(point) else { return }
        _ = accessibilityPerform(action: action)
    }

    @discardableResult
    fileprivate func accessibilityPerform(action: ApprovalPopover.Action) -> Bool {
        guard let onAction, isActionAvailable?() ?? true else { return false }
        onAction(action)
        return true
    }

    // MARK: - Layout

    /// Where the button row's top edge sits, in this flipped view's
    /// coordinates, measured down from the title and the wrapped body.
    /// Recomputed from ``bounds`` and ``messageText`` rather than cached,
    /// because ``draw(_:)`` and the two mouse handlers all need the same
    /// answer and this view has no autolayout pass to keep a cached one
    /// current when either input changes.
    private var buttonRowY: Double {
        Self.inset + Self.titleHeight + wrappedBodyHeight + Self.buttonRowGap
    }

    private var bodyRect: NSRect {
        NSRect(
            x: Self.inset,
            y: Self.inset + Self.titleHeight,
            width: bounds.width - Self.inset * 2,
            height: wrappedBodyHeight
        )
    }

    private var wrappedBodyHeight: Double {
        Self.wrappedBodyHeight(for: messageText, width: bounds.width - Self.inset * 2)
    }

    private func rect(for action: ApprovalPopover.Action) -> NSRect {
        let width = (bounds.width - Self.inset * 2 - Self.buttonGap) / 2
        let x = Self.inset + (action == .deny ? 0 : width + Self.buttonGap)
        return NSRect(x: x, y: buttonRowY, width: width, height: Self.buttonHeight)
    }

    private func nsColor(_ rgb: RGB, alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: CGFloat(alpha))
    }

    private static func title(for action: ApprovalPopover.Action) -> String {
        switch action {
        case .approve: "Approve"
        case .deny: "Deny"
        }
    }

    private static func glyph(for action: ApprovalPopover.Action) -> String {
        switch action {
        case .approve: "\u{23CE}" // ⏎
        case .deny: "\u{238B}" // ⎋
        }
    }

    private static let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let bodyFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let buttonFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    static let width: Double = 300
    static let cornerRadius: Double = 10
    private static let inset: Double = 14
    private static let titleHeight: Double = 20
    static let buttonHeight: Double = 22
    private static let buttonGap: Double = 10
    private static let buttonRowGap: Double = 14

    /// `messageText`'s height once wrapped to `width`, the one measurement
    /// ``wrappedBodyHeight``, ``measuredHeight(forMessage:width:)`` and
    /// ``bodyRect`` all need and must agree on. A static function of the
    /// string and the width rather than a value read off `self` in two
    /// places, so the panel the controller sizes before presenting and the
    /// view drawn inside it cannot measure the same message two different
    /// ways.
    private static func wrappedBodyHeight(for text: String, width: Double) -> Double {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let string = NSAttributedString(string: text, attributes: [
            .font: Self.bodyFont,
            .paragraphStyle: paragraph,
        ])
        return string.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        ).height
    }

    /// The total height this view needs to draw `messageText` in full: title,
    /// wrapped body and button row stacked with their fixed insets. The
    /// controller sizes the panel to this before presenting, so the message
    /// is never clipped and the button row this view computes at draw time
    /// lands exactly at the panel's own bottom inset.
    static func measuredHeight(forMessage message: String, width: Double) -> Double {
        let bodyHeight = wrappedBodyHeight(for: message, width: width - inset * 2)
        return inset + titleHeight + bodyHeight + buttonRowGap + buttonHeight + inset
    }

    // Virtual key codes, `Carbon/HIToolbox`'s own constants (`kVK_Return` /
    // `kVK_Escape`) spelled as literals: this target links no Carbon, and the
    // two codes are stable ABI, unchanged since the original ADB keyboard map.
    private static let returnKeyCode: UInt16 = 0x24
    private static let escapeKeyCode: UInt16 = 0x35
}
