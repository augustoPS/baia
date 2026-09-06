import AppKit

/// One mechanism for the cluster's cards. A ``PalettePanel``, not an
/// `NSPopover` — `ApprovalPopoverController.swift:61` records why (appearance
/// must come from `NSWindow.appearance` so chrome follows the theme, set the
/// same way the palette and the workspace window set theirs). The key
/// discipline is the approval popover's, whole: take key while open, restore
/// on dismiss only if still held, resign-key dismisses.
///
/// Content-agnostic where ``ApprovalPopoverController`` owns one view for its
/// whole life: three different cards will drop three different views in here,
/// so ``show(content:anchoredTo:in:)`` takes any sized `NSView` and this
/// controller holds it only while it is on screen. What a card draws, and the
/// theme/chrome it draws with, is the card's own business — the one
/// window-level fact a view cannot set for itself is ``isDark``, which is why
/// it alone lives here.
///
/// It is a separate key window rather than a view floated over the pane for
/// the reason ``PalettePanel``'s own doc comment states: nothing in a pane may
/// take first responder, and a card that wants ⎋ needs the keyboard.
@MainActor
final class ClusterCardController {
    /// The presented card's cleanup, taken as a parameter of
    /// ``show(content:anchoredTo:in:onDismiss:)`` rather than as a settable
    /// property — the same shape as ``ApprovalPopoverController``'s `present`
    /// taking `onAction`, and for a concrete reason here: `show` dismisses any
    /// card already up, and a property assigned before the call would be the
    /// *new* card's handler fired (and cleared) for the *old* card's teardown.
    /// A parameter is assigned after that internal dismiss, so it cannot be.
    private var onDismiss: (() -> Void)?

    /// Revokes the presented view's action callbacks at the same lifetime
    /// boundary that removes it from the panel. Accessibility clients may
    /// retain an old card (not just one of its virtual children), so releasing
    /// `panel.contentView` cannot by itself make an obsolete action refuse.
    /// Like `onDismiss`, this belongs to the presentation and is installed
    /// only after `show` has dismissed the outgoing card.
    private var invalidateActions: (() -> Void)?

    private let panel: PalettePanel

    private var resignObserver: (any NSObjectProtocol)?

    /// The window the card was summoned over, so key can be handed back to it
    /// on dismissal rather than to nothing. Weak for the reason
    /// ``ApprovalPopoverController/hostWindow`` gives: a window closed behind
    /// the card must not be kept alive by it.
    private weak var hostWindow: NSWindow?

    /// Whether the panel is on screen, as AppKit sees it right now.
    ///
    /// **Not what the app target should ask, and it no longer does.** This said
    /// it was "exposed so the caller can make a second click on the same segment
    /// dismiss instead of reopen" — the one use that has since been taken away
    /// from it. ``TerminalPaneController/clusterCardIsShowing`` answers that
    /// question off ``TerminalPaneController/clusterCardRole`` instead, for two
    /// reasons stated in full at that property: reading this one *builds* the
    /// lazy controller, so every pane that has never opened a card would pay for
    /// a floating panel to be told there is no card; and `hidesOnDeactivate`
    /// lets AppKit order the panel out with no dismissal path run, so
    /// `isVisible` can go false under a card the pane still believes is up.
    ///
    /// It survives because `Diagnostics/cluster-card-key` compiles this file
    /// verbatim and needs exactly the reading the app target must not take: the
    /// probe's subject is the key discipline, so "is the panel actually on
    /// screen" has to come from the panel rather than from a controller flag
    /// agreeing with itself. That probe owns no `TerminalPaneController` and has
    /// no role to read. A new app-target caller wanting "is a card up" wants
    /// `clusterCardIsShowing`.
    var isShowing: Bool { panel.isVisible }

    /// Whether this card's window-level appearance is dark.
    /// ``ApprovalPopoverController/isDark`` carries the full reasoning; this is
    /// the same property on the next floating panel, fed from the same
    /// `ConfigurationCenter.windowIsDark`. Chrome follows the theme, never the
    /// system.
    var isDark: Bool = true {
        didSet {
            guard isDark != oldValue else { return }
            applyAppearance()
        }
    }

    init() {
        // The contentRect is a placeholder: unlike the approval popover, whose
        // view has one known width, every `show` here sizes the panel to the
        // card it was handed.
        panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // `isMovable = true` against the 26.2 glass-in-nonmovable-window
        // regression; `ApprovalPopoverController`'s identical line carries the
        // full account (forums 810314, the backdrop spike's probe). Cards may
        // wear glass the way the popover does, so they need the same
        // workaround, and nothing here initiates a drag either, so the panel
        // still cannot be moved by hand.
        panel.isMovable = true
        // Appears and dismisses without animation, the same unconditional
        // `.none` the palette, the find panel and the approval popover all set.
        panel.animationBehavior = .none
        // Written by hand once because a property observer is silent during
        // initialisation; see ``CommandPaletteController``'s identical line.
        applyAppearance()
    }

    // No `deinit` removing `resignObserver`, for the reason the palette's own
    // copy of this comment states: the observer is registered against `panel`,
    // which this object owns for the process's whole life.

    /// Writes ``isDark`` onto the panel. `.darkAqua` / `.aqua` only, for the
    /// reason `WorkspaceWindowController.applyAppearance()` states.
    private func applyAppearance() {
        panel.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    /// Presents `content` as the card, anchored below `segmentRect`.
    ///
    /// `segmentRect` is the summoning segment's frame in `host`'s coordinate
    /// space — the caller converts out of the capsule's view and into the
    /// window, the same contract ``ApprovalPopoverController/present(anchoredTo:in:title:message:onAction:)``
    /// states for its anchor — which is what `NSWindow.convertToScreen`
    /// expects.
    ///
    /// The caller sizes `content`; this controller reads `content.frame.size`,
    /// or `fittingSize` when the frame is zero. The approval popover measures
    /// its own view instead, because it knows what the view is; this one
    /// cannot, so sizing is part of the content contract.
    ///
    /// Calling this while another card is up dismisses that card first — the
    /// old card's `onDismiss` must fire so its subscriptions are cleaned up
    /// before its view leaves the panel, and reusing the dismiss path keeps
    /// one exit for cards rather than two. `onDismiss` is the incoming card's
    /// cleanup, assigned only after that internal dismiss so the old card's
    /// teardown cannot consume it — see the stored property.
    func show(
        content: NSView,
        anchoredTo segmentRect: NSRect,
        in host: NSWindow,
        invalidateActions: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        // Unconditional, not `if panel.isVisible`: an outgoing card whose panel
        // AppKit already hid (`hidesOnDeactivate`) still has an `onDismiss`
        // holding its subscriptions and the capsule's wash, and the visibility
        // test skipped exactly that teardown. `dismiss()` guards its own window
        // work and returns having called nothing when there was no card.
        dismiss()
        self.invalidateActions = invalidateActions
        self.onDismiss = onDismiss

        hostWindow = host

        let size = content.frame.size == .zero ? content.fittingSize : content.frame.size
        panel.setContentSize(size)
        content.frame = NSRect(origin: .zero, size: size)
        panel.contentView = content

        panel.setFrameOrigin(origin(forAnchor: segmentRect, size: size, in: host))
        panel.makeKeyAndOrderFront(nil)
        // The card itself takes first responder, the same direct grant the
        // approval popover makes and for its reason: there may be no text
        // field, and this is what routes ⎋ (and whatever keys the card
        // handles) to the content view's own responder methods.
        panel.makeFirstResponder(content)

        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Ignore a resignation that has since been reversed.
                    // Switching cards makes this panel resign and retake key
                    // inside one `show`: the internal dismiss orders it out
                    // (enqueueing this notification — it is delivered a turn
                    // late, the fact `dismiss()` cites), then `show`
                    // synchronously makes it key again with the new card.
                    // Without this guard the queued delivery then tore the new
                    // card down one turn after it opened. A genuine
                    // click-elsewhere resign passes: by delivery time AppKit
                    // has already handed key onward, so the panel is not key —
                    // the same fact the `hadKey` guard leans on.
                    guard !self.panel.isKeyWindow else { return }
                    self.dismiss()
                }
            }
        }
    }

    /// Takes the card down and runs its `onDismiss`.
    ///
    /// **The visible-panel guard is on the window work, not on the teardown,
    /// and moving it there is the fix for a card whose caller outlived it.**
    /// `hidesOnDeactivate` is set, so AppKit may order this panel out with no
    /// dismissal path run at all — the owner clicks another application and the
    /// card is simply gone. The resign-key observer above does call `dismiss()`
    /// for that case, but the notification is delivered a turn late (the fact
    /// the observer's own guard leans on), and by then `isVisible` is already
    /// false: the old `guard panel.isVisible else { return }` at the top
    /// returned before `onDismiss`, so `TerminalPaneController.clusterCardRole`
    /// and the capsule's hot wash survived the card that owned them. The pill
    /// then wore a wash behind a segment with nothing open, and the segment's
    /// toggle read as already-showing and refused to reopen it.
    ///
    /// Idempotent either way: the handler is nil'd before it is called, so a
    /// second `dismiss()` — the toggle's, the resign observer's, `showNotice`'s
    /// — runs the window work against an already-hidden panel (all no-ops) and
    /// calls nothing.
    func dismiss() {
        if panel.isVisible {
            // Read before ordering out, and honoured only when the card itself
            // still held the keyboard — ``ApprovalPopoverController/dismiss()``
            // explains the one-turn-late resign-key notification this guards
            // against.
            let hadKey = panel.isKeyWindow
            panel.orderOut(nil)
            if hadKey { hostWindow?.makeKey() }
        }
        // Revoke first while the panel still owns the card. The callbacks are
        // taken and nil'd before either runs so a callback that reenters
        // `dismiss()` cannot fire the presentation's cleanup twice.
        let invalidation = invalidateActions
        let handler = onDismiss
        invalidateActions = nil
        onDismiss = nil
        invalidation?()

        // Unlike the approval popover, which owns its view for the process's
        // life, the card view belongs to the caller and only visits: it is
        // released here so a dismissed card's view (and whatever it holds) does
        // not outlive its card behind an empty stand-in. Outside the visibility
        // branch on purpose — an AppKit-hidden panel still holds the card view,
        // and that is exactly the leak this releases.
        panel.contentView = NSView()
        handler?()
    }

    /// Below the segment, right-aligned to its right edge, clamped so the
    /// panel never draws off the screen it opened on — the approval popover's
    /// clamp arithmetic with the horizontal alignment flipped. Right-aligned
    /// rather than left because the summoning capsule sits at the pane's
    /// TOP-right: a card growing rightward from the segment's left edge would
    /// run off the pane (and often the screen), while one hanging from the
    /// right edge opens into the pane. The below-with-flip-above fallback is
    /// kept even though an anchor at the top of a pane rarely needs it — a
    /// short pane near the screen bottom still can.
    private func origin(forAnchor anchor: NSRect, size: NSSize, in host: NSWindow) -> NSPoint {
        let screenAnchor = host.convertToScreen(anchor)
        let screen = host.screen ?? NSScreen.main
        var origin = NSPoint(
            x: screenAnchor.maxX - size.width,
            y: screenAnchor.minY - Self.anchorGap - size.height
        )

        if let frame = screen?.visibleFrame {
            origin.x = min(max(origin.x, frame.minX), frame.maxX - size.width)
            if origin.y < frame.minY {
                origin.y = screenAnchor.maxY + Self.anchorGap
            }
            origin.y = min(max(origin.y, frame.minY), frame.maxY - size.height)
        }
        return origin
    }

    /// The approval popover's gap, unchanged.
    private static let anchorGap: Double = 6
}
