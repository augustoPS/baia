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
//
// Generation three (10...12) exists because generation two shipped and the
// owner's verdict was "titlebar is not glass/transparent". The material
// generation two restored is the *system* titlebar slab: opaque-reading, and
// nothing like the untinted `NSGlassEffectView` every other chrome surface in
// this app wears. These arms ask whether the sidebar's own treatment —
// `titlebarAppearsTransparent` to stop the slab painting, a real glass backing
// spanning the band, and a `theme.background`-at-`backgroundOpacity` wash over
// it — reads as glass in the band while the toolbar's 40 pt metric, the title,
// the subtitle and the tab bar all survive.
//
// The two ownership candidates are separate arms because the answer decides
// where the view lives in the app: `glass-in-content` puts the backing in the
// contentViewController's own view with `.fullSizeContentView` extending it
// under the band, and `glass-in-frame` puts it in the window's frame view (the
// `contentView`'s superview) with no style-mask change at all.
enum Arm: Int, CaseIterable {
    case none, unified, unifiedCompact, unifiedTransparentTitlebar
    case shippedClear, clearFullSize, backgroundAlpha, backgroundAlphaFullSize, opaqueBaseline
    case minimalAlpha
    case transparentNoGlass, glassInContent, glassInFrame

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
        case .transparentNoGlass: return "transparent-no-glass"
        case .glassInContent: return "glass-in-content"
        case .glassInFrame: return "glass-in-frame"
        }
    }

    /// Generation-three arms keep the shipped window shape (non-opaque, minimal
    /// alpha background, toolbar present) and add `titlebarAppearsTransparent`.
    /// `transparentNoGlass` is the control: the slab stopped painting and
    /// nothing replaced it, so the band must read show-through. The two glass
    /// arms must read as *neither* the slab nor bare wallpaper.
    var isGlassGeneration: Bool { rawValue >= Arm.transparentNoGlass.rawValue }

    /// Where the glass backing is parented, or `nil` for an arm that adds none.
    enum GlassOwner { case contentView, frameView }

    var glassOwner: GlassOwner? {
        switch self {
        case .glassInContent: return .contentView
        case .glassInFrame: return .frameView
        default: return nil
        }
    }

    /// Generation-two arms model the shipped workspace window: nothing is drawn
    /// in the titlebar band by the app, so whatever reads there came from
    /// AppKit.
    var isShippedShape: Bool { rawValue >= Arm.shippedClear.rawValue }

    /// The glass generation keeps the shipped fix's own background, since it is
    /// testing what to put *over* that window rather than revisiting it.
    var wantsTransparentTitlebar: Bool {
        self == .unifiedTransparentTitlebar || isGlassGeneration
    }

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
        case .minimalAlpha, .transparentNoGlass, .glassInContent, .glassInFrame:
            return NSColor(calibratedWhite: 0.09, alpha: 0.005)
        case .opaqueBaseline:
            return .windowBackgroundColor
        default:
            return .clear
        }
    }

    var isOpaqueWindow: Bool { self == .opaqueBaseline }

    var wantsFullSizeContentView: Bool {
        self == .clearFullSize || self == .backgroundAlphaFullSize || self == .glassInContent
    }
}

/// The probe's stand-in for `SidebarGlassBacking`: an untinted `.regular`
/// `NSGlassEffectView` that refuses hit testing, exactly what
/// `Sources/SurfaceHosts.swift` builds for the sidebar column.
private func makeTitlebarGlass() -> NSGlassEffectView {
    let glass = NSGlassEffectView(frame: .zero)
    glass.style = .regular
    glass.cornerRadius = 0
    glass.tintColor = nil
    glass.wantsLayer = true
    return glass
}

/// The probe's stand-in for the sidebar's glass wash, at the default the owner
/// ran it at: `theme.background` at `backgroundOpacity`. A plain layer-backed
/// fill rather than a `draw(_:)` override, because the probe only needs pixels.
///
/// **That wash retired from the app on 2026-08-08** (owner's naked-glass
/// ruling; see `Sources/SurfaceHosts.swift`). This stand-in stays because the
/// question this probe asks is whether a titlebar band carries material with an
/// opaque-ish layer stacked over it, and a fill above the glass is the harshest
/// version of that question rather than a claim about what the app now draws.
private func makeWash() -> NSView {
    let wash = NSView(frame: .zero)
    wash.wantsLayer = true
    wash.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.42).cgColor
    return wash
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

    /// Held for the run for the toolbars' reason: a glass view whose only
    /// strong reference is its superview is fine, but holding them here makes
    /// the retention explicit and keeps the arm inspectable after capture.
    var glasses: [NSGlassEffectView] = []

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
            if arm.wantsTransparentTitlebar { w.titlebarAppearsTransparent = true }

            // Generation three: the glass backing and its wash, spanning the
            // titlebar band, in whichever of the two candidate owners this arm
            // is testing.
            //
            // The band's height is read from the window rather than hardcoded
            // at 40, because that is the number under test: an arm whose
            // toolbar metric collapsed would otherwise be measured with a
            // 40 pt strip over a 32 pt band and read as a partial success.
            if let owner = arm.glassOwner {
                let bandHeight = w.frame.height - w.contentLayoutRect.height
                let glass = makeTitlebarGlass()
                let wash = makeWash()
                self.glasses.append(glass)

                switch owner {
                case .contentView:
                    // `.fullSizeContentView` is already in this arm's style
                    // mask, so `content` spans the whole window and the band is
                    // its top `bandHeight` points. The well is anchored to the
                    // safe area above, so the visible layout does not move.
                    guard let content = w.contentView else { break }
                    glass.frame = NSRect(
                        x: 0, y: content.bounds.height - bandHeight,
                        width: content.bounds.width, height: bandHeight)
                    glass.autoresizingMask = [.width, .minYMargin]
                    wash.frame = glass.frame
                    wash.autoresizingMask = glass.autoresizingMask
                    content.addSubview(glass, positioned: .below, relativeTo: nil)
                    content.addSubview(wash, positioned: .above, relativeTo: glass)

                case .frameView:
                    // The window's frame view — `contentView.superview` — is
                    // the whole window including its titlebar, so no style-mask
                    // change is needed to reach the band. This is the AppKit
                    // internal the arm exists to judge: it works, and it is a
                    // view no public API names.
                    guard let frameView = w.contentView?.superview else { break }
                    glass.frame = NSRect(
                        x: 0, y: frameView.bounds.height - bandHeight,
                        width: frameView.bounds.width, height: bandHeight)
                    glass.autoresizingMask = [.width, .minYMargin]
                    wash.frame = glass.frame
                    wash.autoresizingMask = glass.autoresizingMask
                    frameView.addSubview(glass, positioned: .below, relativeTo: nil)
                    frameView.addSubview(wash, positioned: .above, relativeTo: glass)
                }
            }

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
                        + "fullSize=\(w.styleMask.contains(.fullSizeContentView)) "
                        // The survival facts, measured rather than eyeballed
                        // off the capture. `titlebarAppearsTransparent` is the
                        // flag under test in generation three and the question
                        // is whether it costs the toolbar's metric or the
                        // title: an arm that reads as glass but drops the band
                        // to 32 pt has moved the content, not restyled it.
                        + "transparentTitlebar=\(w.titlebarAppearsTransparent) "
                        + "toolbarVisible=\(w.toolbar?.isVisible ?? false) "
                        + "title=\(w.title.isEmpty ? "GONE" : w.title) "
                        + "subtitle=\(w.subtitle.isEmpty ? "GONE" : w.subtitle)")
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

            // The same question asked of the *new* arrangement, because the
            // first flip only covers the background colour and generation
            // three changes two more things: `titlebarAppearsTransparent` and
            // a subview added to the frame view. Either could in principle
            // move `contentLayoutRect`, which is what the pane tree lays out
            // against, so a single point of movement here is a live grid
            // resize and a `SIGWINCH` to every running shell.
            //
            // Flipped on the frame-view arm, since that is the one the app
            // adopts: the backing is added and removed the way
            // `applyResolvedChrome()` does it rather than merely hidden, so
            // the measurement covers the teardown path too.
            DispatchQueue.main.sync {
                let w = self.windows[Arm.glassInFrame.rawValue]
                w.makeKeyAndOrderFront(nil)
                w.orderFrontRegardless()
            }
            Thread.sleep(forTimeInterval: 0.6)

            var glassGeometry: [String] = []
            for label in ["glass on (shipped)", "glass off", "glass on again",
                          "glass off again", "glass on, settled"] {
                DispatchQueue.main.sync {
                    let w = self.windows[Arm.glassInFrame.rawValue]
                    let on = label.hasPrefix("glass on")
                    w.titlebarAppearsTransparent = on
                    if let frameView = w.contentView?.superview {
                        let existing = frameView.subviews.compactMap { $0 as? NSGlassEffectView }
                        if on, existing.isEmpty {
                            let glass = makeTitlebarGlass()
                            let band = w.frame.height - w.contentLayoutRect.height
                            glass.frame = NSRect(
                                x: 0, y: frameView.bounds.height - band,
                                width: frameView.bounds.width, height: band)
                            frameView.addSubview(glass, positioned: .below, relativeTo: nil)
                        } else if !on {
                            for glass in existing { glass.removeFromSuperview() }
                        }
                    }
                    w.contentView?.layoutSubtreeIfNeeded()
                    let f = w.contentView?.frame ?? .zero
                    let layout = w.contentLayoutRect
                    let pad = label.padding(toLength: 24, withPad: " ", startingAt: 0)
                    glassGeometry.append(
                        "\(pad) contentView=\(Int(f.width))x\(Int(f.height)) "
                        + "contentLayoutRect=\(Int(layout.width))x\(Int(layout.height))"
                        + "@\(Int(layout.minX)),\(Int(layout.minY)) "
                        + "frame=\(Int(w.frame.width))x\(Int(w.frame.height))")
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            DispatchQueue.main.sync { self.windows[Arm.glassInFrame.rawValue].orderOut(nil) }

            DispatchQueue.main.sync {
                for line in out { print(line) }
                print("--- geometry across the background flip (must not move) ---")
                for line in geometry { print(line) }
                print("--- geometry across the titlebar-glass flip (must not move) ---")
                for line in glassGeometry { print(line) }
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
