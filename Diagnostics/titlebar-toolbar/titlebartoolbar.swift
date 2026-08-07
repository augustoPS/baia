import AppKit

// Two generations of arms live here, and the second exists because the first
// measured the wrong window.
//
// Generation one (0...3) asked which titlebar treatment produces material at
// all, over a window whose content view fills the whole frame with a dark
// translucent fill. That answered "an empty toolbar is enough, .unifiedCompact
// is the cheaper metric" and shipped in `5f3b88c`.
//
// Generation two (4...8) exists because that shipped and the owner saw no
// titlebar. Those arms all set a dark fill under the whole window, which the
// real workspace window does *not* have: it is `isOpaque = false` with
// `backgroundColor = .clear`, and its content starts below `contentLayoutRect`,
// so the titlebar band has nothing beneath it at all. The owner's evidence is
// that the failure is binary on that flip rather than proportional to opacity
// — at 0.99 the wells are near-solid and the titlebar is still bare wallpaper,
// at exactly 1.0 it is fine — which points at the window *background* rather
// than at content sampling. These arms separate the two.
enum Arm: Int, CaseIterable {
    case none, unified, unifiedCompact, unifiedTransparentTitlebar
    case shippedClear, clearFullSize, backgroundAlpha, backgroundAlphaFullSize, opaqueBaseline
    case minimalAlpha

    var label: String {
        switch self {
        case .none: return "no-toolbar"
        case .unified: return "unified"
        case .unifiedCompact: return "unified-compact"
        case .unifiedTransparentTitlebar: return "unified-transparent-titlebar"
        case .shippedClear: return "shipped-clear"
        case .clearFullSize: return "clear-fullsize"
        case .backgroundAlpha: return "background-alpha"
        case .backgroundAlphaFullSize: return "background-alpha-fullsize"
        case .opaqueBaseline: return "opaque-baseline"
        case .minimalAlpha: return "minimal-alpha"
        }
    }

    /// Generation-two arms model the shipped workspace window: nothing is drawn
    /// in the titlebar band by the app, so whatever reads there came from
    /// AppKit.
    var isShippedShape: Bool { rawValue >= Arm.shippedClear.rawValue }

    /// `.clear` is the shipped value whenever `backgroundOpacity < 1`. The
    /// alpha arms ask whether a non-clear window background restores the
    /// material while the content area stays see-through.
    var windowBackground: NSColor {
        switch self {
        case .backgroundAlpha, .backgroundAlphaFullSize:
            return NSColor(calibratedWhite: 0.09, alpha: 0.42)
        // The smallest alpha that was found to restore the material. Kept as its
        // own arm because it is the shipped fix: it separates "the material
        // needs a non-clear background" from "the material needs a *dark*
        // background", and only this arm shows the first is the whole rule.
        case .minimalAlpha:
            return NSColor(calibratedWhite: 0.09, alpha: 0.005)
        case .opaqueBaseline:
            return .windowBackgroundColor
        default:
            return .clear
        }
    }

    var isOpaqueWindow: Bool { self == .opaqueBaseline }

    var wantsFullSizeContentView: Bool {
        self == .clearFullSize || self == .backgroundAlphaFullSize
    }
}

/// A flat fill standing in for a terminal well, so an arm can be judged on
/// whether the *wells* still composite onto the desktop rather than only on
/// whether the titlebar carries material.
private func makeWell() -> NSView {
    let well = NSView(frame: .zero)
    well.wantsLayer = true
    well.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.42).cgColor
    return well
}

final class Delegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    var windows: [NSWindow] = []

    func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] { [] }

    /// Toolbars are held for the run. `NSWindow.toolbar` does not keep one
    /// alive on its own, and a deallocated toolbar takes the material with it —
    /// the same retention the workspace controller documents.
    var toolbars: [NSToolbar] = []

    func applicationDidFinishLaunching(_: Notification) {
        var out: [String] = []

        for arm in Arm.allCases {
            var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
            if arm.wantsFullSizeContentView { style.insert(.fullSizeContentView) }

            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 260),
                styleMask: style,
                backing: .buffered, defer: false)
            w.title = "baia"
            w.subtitle = "~/Projects/baia"
            w.isOpaque = arm.isOpaqueWindow
            w.backgroundColor = arm.windowBackground

            let content = NSView(frame: .zero)
            content.wantsLayer = true

            if arm.isShippedShape {
                // The shipped shape: the content view draws NOTHING itself, and
                // the well is a subview inset to `contentLayoutRect` so the
                // titlebar band is left bare. With `.fullSizeContentView` the
                // content view's frame grows to the full window, and the well is
                // anchored to the safe area so the visible layout does not move
                // — only the window's backing extends under the titlebar.
                let well = makeWell()
                well.translatesAutoresizingMaskIntoConstraints = false
                content.addSubview(well)
                let top = arm.wantsFullSizeContentView
                    ? content.safeAreaLayoutGuide.topAnchor
                    : content.topAnchor
                NSLayoutConstraint.activate([
                    well.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                    well.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                    well.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                    well.topAnchor.constraint(equalTo: top),
                ])
            } else {
                // Generation one: the content view itself is the dark fill and
                // covers the whole window.
                content.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.42).cgColor
            }
            w.contentView = content

            if arm != .none {
                let tb = NSToolbar(identifier: "probe.\(arm.label)")
                tb.delegate = self
                tb.displayMode = .iconOnly
                toolbars.append(tb)
                w.toolbar = tb
                switch arm {
                case .unified: w.toolbarStyle = .unified
                case .unifiedTransparentTitlebar: w.toolbarStyle = .unified
                default: w.toolbarStyle = .unifiedCompact
                }
            }
            if arm == .unifiedTransparentTitlebar { w.titlebarAppearsTransparent = true }

            // Arms are stacked at one position and shown one at a time. Nine
            // 620x260 windows do not fit on a screen without touching, and an
            // overlap is not cosmetic here: a window's titlebar landing over the
            // arm above it puts that arm's traffic lights and material inside
            // the band being measured, which is exactly the quantity in
            // question. `run.sh` raises one arm at a time and captures it alone.
            w.setFrameTopLeftPoint(NSPoint(x: 200, y: 800))
            windows.append(w)
        }

        // One arm on screen at a time. Each is raised, given a moment to lay
        // out and render, captured by `screencapture` in-process, then ordered
        // out before the next comes up — so every band measurement sees that
        // arm over bare desktop and nothing else.
        let outDir = ProcessInfo.processInfo.environment["PROBE_OUT"] ?? NSTemporaryDirectory()
        DispatchQueue.global().async {
            for (i, arm) in Arm.allCases.enumerated() {
                DispatchQueue.main.sync {
                    let w = self.windows[i]
                    w.makeKeyAndOrderFront(nil)
                    w.orderFrontRegardless()
                }
                Thread.sleep(forTimeInterval: 0.9)

                var frame = NSRect.zero
                DispatchQueue.main.sync {
                    let w = self.windows[i]
                    frame = w.frame
                    let chrome = Int(w.frame.height - w.contentLayoutRect.height)
                    out.append(
                        "\(arm.label): chrome=\(chrome) "
                        + "contentViewH=\(Int(w.contentView?.frame.height ?? 0)) "
                        + "contentLayoutH=\(Int(w.contentLayoutRect.height)) "
                        + "opaque=\(w.isOpaque) "
                        + "bgAlpha=\(String(format: "%.2f", w.backgroundColor.alphaComponent)) "
                        + "fullSize=\(w.styleMask.contains(.fullSizeContentView))")
                }

                // Screen coordinates for `screencapture` are top-left origin;
                // `NSWindow.frame` is bottom-left off the primary screen.
                let screenH = NSScreen.screens.first?.frame.height ?? 1080
                let top = screenH - frame.maxY
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = [
                    "-x", "-o",
                    "-R\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))",
                    "\(outDir)/arm-\(i)-\(arm.label).png",
                ]
                try? task.run()
                task.waitUntilExit()

                DispatchQueue.main.sync { self.windows[i].orderOut(nil) }
                Thread.sleep(forTimeInterval: 0.3)
            }

            // The SIGWINCH question, asked on one window rather than across the
            // arms: flipping the background between `.clear` and the shipped
            // alpha is claimed to move no geometry, which is what makes the fix
            // safe to apply live rather than only at window creation. Every
            // number here must be identical down the column; a pane tree lays
            // out against `contentLayoutRect`, and a single point of movement
            // there is a grid resize and a `SIGWINCH` to whatever is running.
            DispatchQueue.main.sync {
                let w = self.windows[Arm.minimalAlpha.rawValue]
                w.makeKeyAndOrderFront(nil)
                w.orderFrontRegardless()
            }
            Thread.sleep(forTimeInterval: 0.6)

            var geometry: [String] = []
            let states: [(String, Bool, NSColor)] = [
                ("clear (the defect)", false, .clear),
                ("alpha 0.005 (the fix)", false, NSColor(calibratedWhite: 0.09, alpha: 0.005)),
                ("clear again", false, .clear),
                ("alpha again", false, NSColor(calibratedWhite: 0.09, alpha: 0.005)),
                ("opaque (untouched)", true, .windowBackgroundColor),
            ]
            for (label, opaque, colour) in states {
                DispatchQueue.main.sync {
                    let w = self.windows[Arm.minimalAlpha.rawValue]
                    w.isOpaque = opaque
                    w.backgroundColor = colour
                    w.contentView?.layoutSubtreeIfNeeded()
                    let f = w.contentView?.frame ?? .zero
                    let layout = w.contentLayoutRect
                    let pad = label.padding(toLength: 24, withPad: " ", startingAt: 0)
                    geometry.append(
                        "\(pad) contentView=\(Int(f.width))x\(Int(f.height)) "
                        + "contentLayoutRect=\(Int(layout.width))x\(Int(layout.height))"
                        + "@\(Int(layout.minX)),\(Int(layout.minY)) "
                        + "frame=\(Int(w.frame.width))x\(Int(w.frame.height))")
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            DispatchQueue.main.sync { self.windows[Arm.minimalAlpha.rawValue].orderOut(nil) }

            DispatchQueue.main.sync {
                for line in out { print(line) }
                print("--- geometry across the background flip (must not move) ---")
                for line in geometry { print(line) }
                fflush(stdout)
                NSApp.terminate(nil)
            }
        }
    }
}

let app = NSApplication.shared
let d = Delegate()
app.delegate = d
app.setActivationPolicy(.regular)
app.run()
