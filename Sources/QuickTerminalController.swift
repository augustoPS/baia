import AppKit
import WorkspaceLayout

private final class QuickTerminalPanel: NSPanel {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performClose(_ sender: Any?) {
        onClose?()
    }
}

/// A dedicated terminal whose lifetime is independent of its visibility.
final class QuickTerminalController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private(set) var pane: TerminalPaneController?

    private let configuration: ConfigurationCenter
    private var isPresented = false
    private var transition = 0

    init(configuration: ConfigurationCenter) {
        self.configuration = configuration
        let panel = QuickTerminalPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        self.panel = panel
        super.init()
        panel.delegate = self
        panel.onClose = { [weak self] in self?.hide() }
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hasShadow = true
        panel.title = "Quick Terminal"
        panel.animationBehavior = .none
        refreshAppearance()
    }

    func toggle() {
        if isPresented {
            hide()
        } else {
            show()
        }
    }

    private func show() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let frame = NSRect(
            x: visible.minX, y: visible.midY,
            width: visible.width, height: visible.height / 2
        )
        let wasVisible = panel.isVisible
        transition += 1
        isPresented = true

        // Set the final grid size before creating the surface. Animation only
        // changes the origin, so it never sends a resize for every frame.
        panel.setFrame(frame, display: false)
        if pane == nil {
            let pane = TerminalPaneController(
                paneID: PaneID(),
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                createdBy: nil,
                controlSocketPath: nil
            )
            configuration.register(pane)
            self.pane = pane
            pane.onProcessClose = { [weak self, weak pane] in
                guard let self, let pane, self.pane === pane else { return }
                self.shutdown()
            }
            panel.contentViewController = pane
            pane.setPaneFocused(true)
        }
        // A content controller's preferred size can change the panel on attach.
        panel.setFrame(frame, display: false)
        refreshAppearance()
        if !wasVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrameOrigin(NSPoint(x: frame.minX, y: frame.minY + 24))
            panel.alphaValue = 0
        }
        panel.makeKeyAndOrderFront(nil)
        pane?.takeFocus()
        animate(to: frame.origin, alpha: 1)
    }

    func hide() {
        guard isPresented else { return }
        isPresented = false
        transition += 1
        let current = transition
        let origin = NSPoint(x: panel.frame.minX, y: panel.frame.minY + 24)
        animate(to: origin, alpha: 0) { [weak self] in
            guard let self, self.transition == current, !self.isPresented else { return }
            self.panel.orderOut(nil)
        }
    }

    private func animate(
        to origin: NSPoint,
        alpha: CGFloat,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrameOrigin(origin)
            panel.animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }

    func refreshAppearance() {
        panel.appearance = NSAppearance(named: configuration.windowIsDark ? .darkAqua : .aqua)
        panel.isOpaque = !configuration.windowIsTransparent
        // A nonzero alpha keeps the compositor backing available for glass.
        panel.backgroundColor = configuration.windowIsTransparent
            ? NSColor.black.withAlphaComponent(0.001) : .windowBackgroundColor
        panel.invalidateShadow()
    }

    func shutdown() {
        transition += 1
        isPresented = false
        panel.orderOut(nil)
        pane?.onProcessClose = nil
        panel.contentViewController = nil
        panel.contentView = nil
        pane = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}
