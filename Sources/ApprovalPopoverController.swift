import AppKit
import PaneChrome

/// The approval popover that springs from a footer's attention capsule.
/// Design v5 §6.
///
/// One instance, owned by the app delegate exactly the way ``palette`` and
/// `find` are: the popover can be summoned from any pane in any window, and a
/// per-window copy would have to be found by the same window lookup the
/// summoning click already resolved. It is its own key window, the same
/// pattern ``CommandPaletteController`` and `FindPanelController` both use,
/// for the reason `PalettePanel`'s own doc comment states: nothing in a pane
/// may take first responder, so a popover that needs the keyboard for ⏎/⎋ has
/// to be a separate window rather than a view floated over the pane.
@MainActor
final class ApprovalPopoverController: NSObject {
    /// Raised with the action chosen, by click or by ⏎/⎋. The controller does
    /// not know what a pane is or how to write to one — ``TerminalPaneController/send(_:)``
    /// already exists and is the app delegate's to call, the same seam the
    /// sidebar's path picker already writes through.
    var onAction: ((ApprovalPopover.Action) -> Void)?

    private let panel: PalettePanel
    private let contentView = ApprovalPopoverView(frame: .zero)

    private var resignObserver: (any NSObjectProtocol)?

    /// The window the popover was summoned over, so key can be handed back to
    /// it on dismissal rather than to nothing. Weak for the same reason the
    /// palette's own copy is: a window closed behind the popover must not be
    /// kept alive by it.
    private weak var hostWindow: NSWindow?

    var isVisible: Bool { panel.isVisible }

    var theme: PaneTheme = .darkPastel {
        didSet { contentView.theme = theme }
    }

    var resolvedChrome: ResolvedChrome = .flat {
        didSet { contentView.resolvedChrome = resolvedChrome }
    }

    /// Whether this popover's window-level appearance is dark — what AppKit
    /// reads when it renders the `NSGlassEffectView` behind the content and
    /// anything else drawn from `NSWindow.appearance`.
    ///
    /// The palette's own ``CommandPaletteController/isDark`` carries the
    /// reasoning; this is the same property on the other floating panel, fed
    /// from the same `ConfigurationCenter.windowIsDark`. Chrome follows the
    /// theme, never the system.
    ///
    /// This is an `NSWindow` (``PalettePanel``) rather than an `NSPopover`
    /// despite the name — see this type's own header — so the appearance is set
    /// the same way the palette and the workspace window set theirs, not through
    /// `NSPopover.appearance`.
    var isDark: Bool = true {
        didSet {
            guard isDark != oldValue else { return }
            applyAppearance()
        }
    }

    override init() {
        panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: ApprovalPopoverView.width, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // `isMovable = true` deliberately, against the 26.2 regression in §6.8:
        // glass inside a borderless *non-movable* transparent window stops
        // re-sampling as content moves beneath it (forums 810314), and the
        // documented partial workaround is exactly this flag — the same one the
        // glass-backdrop spike's probe set on all three window types
        // (`Diagnostics/glass-backdrop/backdroptest.swift`). This popover wears
        // glass under `resolvedChrome == .glass`, so it needs the workaround.
        //
        // `isMovableByWindowBackground` is never set and stays AppKit's `false`
        // default, and `contentView`'s `mouseDown`/`mouseUp`
        // (`ApprovalPopoverView` above) only track which button is pressed —
        // neither calls `performDrag` or falls through to one. So a user still
        // cannot drag this popover; it stays anchored to the capsule that
        // spawned it, and `present(anchoredTo:...)` repositions it fresh on
        // every summon regardless.
        panel.isMovable = true
        // No animation either way, per the plan's "appears and dismisses
        // without animation": the same unconditional `.none` the palette and
        // the find panel already set, not a Reduce Motion branch, since
        // neither of those two carries one either.
        panel.animationBehavior = .none
        // Written by hand once, because a property observer is silent during
        // initialisation; `AppDelegate` overwrites it with
        // `configuration.windowIsDark` immediately after, alongside `theme` and
        // `resolvedChrome`. See ``CommandPaletteController``'s identical line.
        applyAppearance()

        contentView.frame = NSRect(x: 0, y: 0, width: ApprovalPopoverView.width, height: 100)
        panel.contentView = contentView

        contentView.onAction = { [weak self] action in
            self?.commit(action)
        }
    }

    /// Writes ``isDark`` onto the panel. `.darkAqua` / `.aqua` only, for the
    /// reason `WorkspaceWindowController.applyAppearance()` states.
    private func applyAppearance() {
        panel.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    // No `deinit` removing `resignObserver`, for the reason the palette's own
    // copy of this comment states: the observer is registered against
    // `panel`, which this object owns for the process's whole life.

    /// Presents the popover anchored below `anchor`, which is the attention
    /// capsule's own frame in `host`'s coordinates
    /// (``TerminalPaneController/onApprovalRequested``already converts it out
    /// of the pane's view and into the window).
    func present(
        anchoredTo anchor: NSRect,
        in host: NSWindow,
        title: String,
        message: String,
        onAction: @escaping (ApprovalPopover.Action) -> Void
    ) {
        self.onAction = onAction
        hostWindow = host

        contentView.title = title
        contentView.messageText = message

        let height = ApprovalPopoverView.measuredHeight(
            forMessage: message,
            width: ApprovalPopoverView.width
        )
        let size = NSSize(width: ApprovalPopoverView.width, height: height)
        panel.setContentSize(size)
        contentView.frame = NSRect(origin: .zero, size: size)

        panel.setFrameOrigin(origin(forAnchor: anchor, size: size, in: host))
        panel.makeKeyAndOrderFront(nil)
        // The popover has no text field to take first responder the way the
        // palette's query field does; `contentView` takes it directly, which
        // is what routes ⏎/⎋ to `ApprovalPopoverView.keyDown(with:)`.
        panel.makeFirstResponder(contentView)

        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
    }

    func dismiss() {
        guard panel.isVisible else { return }
        // Read before ordering out, the same guard the palette's own
        // `dismiss()` makes and for the identical reason: the resign-key
        // notification is delivered a turn after AppKit already handed key
        // to whatever the user clicked, and restoring unconditionally would
        // yank it back from a window that is not this popover's host anymore.
        let hadKey = panel.isKeyWindow
        panel.orderOut(nil)
        if hadKey { hostWindow?.makeKey() }
        onAction = nil
    }

    /// Below the capsule, left-aligned to it, clamped so the panel never
    /// draws off the screen it opened on. `anchor` arrives in `host`'s own
    /// coordinate space, which is what `NSWindow.convertToScreen` expects.
    private func origin(forAnchor anchor: NSRect, size: NSSize, in host: NSWindow) -> NSPoint {
        let screenAnchor = host.convertToScreen(anchor)
        let screen = host.screen ?? NSScreen.main
        var origin = NSPoint(x: screenAnchor.minX, y: screenAnchor.minY - Self.anchorGap - size.height)

        if let frame = screen?.visibleFrame {
            origin.x = min(max(origin.x, frame.minX), frame.maxX - size.width)
            // If there is no room below the capsule (a footer near the bottom
            // of the screen), open upward instead, above the capsule, rather
            // than let the popover draw off the visible frame.
            if origin.y < frame.minY {
                origin.y = screenAnchor.maxY + Self.anchorGap
            }
            origin.y = min(max(origin.y, frame.minY), frame.maxY - size.height)
        }
        return origin
    }

    /// ⏎ and ⎋ arrive here from ``ApprovalPopoverView/keyDown(with:)`` and
    /// ``ApprovalPopoverView/cancelOperation(_:)`` — design v5 §6's "both keys
    /// ARE the buttons; there is no third action" — the same commit path a
    /// button click already takes.
    private func commit(_ action: ApprovalPopover.Action) {
        let callback = onAction
        dismiss()
        callback?(action)
    }

    private static let anchorGap: Double = 6
}
