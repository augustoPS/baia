import AppKit

// Four arms, each a non-opaque window with a dark translucent content view
// standing in for the terminal well, differing only in titlebar treatment.
//   0: no toolbar (current baia)
//   1: empty NSToolbar, .unified
//   2: empty NSToolbar, .unifiedCompact
//   3: empty NSToolbar, .unified, titlebarAppearsTransparent = true
enum Arm: Int, CaseIterable {
    case none, unified, unifiedCompact, unifiedTransparentTitlebar
    var label: String {
        switch self {
        case .none: return "no-toolbar"
        case .unified: return "unified"
        case .unifiedCompact: return "unified-compact"
        case .unifiedTransparentTitlebar: return "unified-transparent-titlebar"
        }
    }
}

final class Delegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    var windows: [NSWindow] = []

    func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] { [] }

    func applicationDidFinishLaunching(_: Notification) {
        var out: [String] = []
        for (i, arm) in Arm.allCases.enumerated() {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 300),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            w.title = "baia"
            w.subtitle = "Projects"
            w.isOpaque = false
            w.backgroundColor = .clear

            let content = NSView(frame: .zero)
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.42).cgColor
            w.contentView = content

            let beforeContent = w.contentLayoutRect.height

            if arm != .none {
                let tb = NSToolbar(identifier: "probe.\(arm.label)")
                tb.delegate = self
                tb.displayMode = .iconOnly
                w.toolbar = tb
                switch arm {
                case .unifiedCompact: w.toolbarStyle = .unifiedCompact
                default: w.toolbarStyle = .unified
                }
            }
            if arm == .unifiedTransparentTitlebar { w.titlebarAppearsTransparent = true }

            w.setFrameTopLeftPoint(NSPoint(x: 60, y: 900 - CGFloat(i) * 340))
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
            windows.append(w)

            // Measured after the window is on screen, so the toolbar has laid out.
            let afterContent = w.contentLayoutRect.height
            let titlebarHeight = w.frame.height - w.contentLayoutRect.height
            out.append("\(arm.label): frameH=\(Int(w.frame.height)) contentLayoutH=\(Int(afterContent)) titlebar+toolbar=\(Int(titlebarHeight)) contentBeforeToolbar=\(Int(beforeContent)) titleVisible=\(w.titleVisibility == .visible)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            for line in out { print(line) }
            // Re-measure once laid out for real.
            print("--- after layout ---")
            for (i, arm) in Arm.allCases.enumerated() {
                let w = self.windows[i]
                print("\(arm.label): titlebar+toolbar=\(Int(w.frame.height - w.contentLayoutRect.height))")
            }
            fflush(stdout)
        }
    }
}

let app = NSApplication.shared
let d = Delegate()
app.delegate = d
app.setActivationPolicy(.regular)
app.run()
