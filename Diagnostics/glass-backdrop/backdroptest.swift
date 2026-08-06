import AppKit
import PaneChrome

// The four-arm backdrop spike: what does an `NSGlassEffectView` over a pane's
// bottom 22 pt actually sample, and does any arrangement make it lens?
//
// Design v5 Plans 2-3 shipped glass that renders and cannot refract. The research
// report names two causes at once (§6.1 the colored-slab failure, §6.2 the
// empty-backdrop failure), and the shipped footer commits both: it tints the
// glass toward the theme background *and* sits beside the terminal with nothing
// under it. Two failures stacked means fixing either alone proves nothing, which
// is why the arms below vary tint and backdrop independently rather than
// together.
//
// This binary never becomes key and never activates. `NSApp.setActivationPolicy(
// .accessory)` plus `orderFrontRegardless()` puts a window on screen that the
// window server composites and the user's focus never leaves. That is the
// `SAFE_PROBES` standard (`pane-resize`, `theme-refresh`), and it is also the
// only honest way to run this: a focus steal mid-capture would land keystrokes in
// whatever the owner was typing into.
//
// The consequence for the inactive-state question is stated rather than worked
// around. See `ARMS` below and the README's "what inactive means here".

// MARK: - the controlled backdrop

/// A full-screen window of pure white beside pure black, ordered below the probe
/// window.
///
/// The desktop cannot be the backdrop. Glass adapts to what is behind it, so an
/// arm captured over the owner's wallpaper grades against a photograph that is
/// different on every machine and different again next week. Two flat halves at
/// the extremes make "bright" and "dark" mean the same thing on any machine, and
/// make a lensing edge visible as a *bend in the boundary between them*, which a
/// flat slab cannot produce and a blur can only soften.
///
/// The boundary is the measurement. A material that merely blurs leaves the
/// white/black edge straight and fuzzy; a material that refracts displaces it.
/// That is why the halves are split vertically through the middle of the bar
/// rather than being two separate captures over two flat fields.
final class BackdropWindow: NSWindow {
    static func make(covering frame: NSRect) -> BackdropWindow {
        let window = BackdropWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Below the probe window but above the desktop. `.normal - 1` rather than
        // `.desktop`, because a desktop-level window sits under the wallpaper's
        // own icon layer and the point of this window is to *replace* the
        // wallpaper as the thing being sampled.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        let view = BackdropView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = view
        return window
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }
}

final class BackdropView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_: NSRect) {
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height).fill()
        NSColor.black.setFill()
        NSRect(
            x: bounds.width / 2,
            y: 0,
            width: bounds.width - bounds.width / 2,
            height: bounds.height
        ).fill()

        // A mid-grey ruler across the seam. A displaced edge is easier to see
        // against a straight line than against nothing, and this line is what a
        // human compares between arms: glass that lenses bends it where the bar
        // crosses, glass that only blurs leaves it straight.
        NSColor(white: 0.5, alpha: 1).setFill()
        var y = bounds.height * 0.25
        while y < bounds.height {
            NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
            y += 24
        }
    }
}

// MARK: - the pane stand-in

/// The terminal surface stand-in: the theme background at the shipped 0.42 well
/// opacity, over a non-opaque window, so the backdrop shows through exactly as it
/// does under a real pane.
///
/// A plain fill rather than a live ghostty surface, and that substitution is
/// sound for arms 1, 2 and 4 for one reason only: what glass samples is the
/// composited pixels beneath its frame, and 0.42-alpha dark grey over the
/// backdrop composites to the same pixels whether a Metal layer or `NSColor` put
/// them there. It is *not* sound for the grid question, which is why arm 3's
/// measurement lives in a separate binary against a real PTY (`gridtest.swift`).
///
/// The one thing this cannot answer is whether `NSGlassEffectView` samples a
/// `CAMetalLayer` at all. Ghostty never found out: they place glass strictly
/// *below* the terminal view (`addSubview(effectView, positioned: .below,
/// relativeTo: terminalView)`) and clear the renderer's background, so the
/// question never arose upstream. `gridtest.swift` answers it here.
final class SurfaceStandIn: NSView {
    /// The shipped well opacity. `ac22f14` made 0.42 the default; a stand-in at
    /// any other alpha would grade the arms against a pane that does not ship.
    static let wellOpacity: CGFloat = 0.42

    var themeBackground: NSColor = .init(
        srgbRed: 18.0 / 255, green: 20.0 / 255, blue: 24.0 / 255, alpha: 1
    )

    override var isFlipped: Bool { true }

    override func draw(_: NSRect) {
        themeBackground.withAlphaComponent(Self.wellOpacity).setFill()
        bounds.fill()

        // Text at the same scale the terminal draws, because legibility through
        // the bar is half of what the captures are graded on and a blank well
        // cannot show it. Rows are drawn all the way to the bottom edge, so under
        // arm 3 the bar genuinely overlaps live-looking content rather than an
        // empty strip that would make any arrangement look fine.
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(white: 0.86, alpha: 1),
        ]
        var y: CGFloat = 8
        var row = 0
        while y < bounds.height {
            let line = row % 3 == 0
                ? "$ git status --porcelain=v2 --branch  # row \(row)"
                : "  MM Sources/PaneStatusBarView.swift          \(row)"
            line.draw(at: NSPoint(x: 8, y: y), withAttributes: attributes)
            y += font.boundingRectForFont.height + 3
            row += 1
        }
    }
}

// MARK: - the arms

enum Arm: String, CaseIterable {
    /// Arm 1. The current shipped state, reproduced rather than described:
    /// `PaneStatusGlassBacking` is an `NSGlassEffectView` with `style = .regular`
    /// and `tintColor` written from `MaterialSet.fillChrome`, sitting in a 22 pt
    /// strip *below* the terminal view with nothing behind it but the window.
    /// Both failures at once, which is the point: it is the control every other
    /// arm is read against.
    case shippedTinted = "1-shipped-tinted"

    /// Arm 2. Resolution (A). The tint comes off; the bar still sits beside the
    /// surface, so its backdrop is the transparent window region and therefore
    /// the desktop. Costs no layout change at all.
    case untintedBesideSurface = "2-untinted-beside"

    /// Arm 3. Resolution (B). The tint comes off *and* the surface stand-in
    /// extends under the bar's full 22 pt, so glass samples well pixels rather
    /// than the desktop. The research report's preferred arrangement (§6.2).
    case untintedOverSurface = "3-untinted-over-surface"

    /// Arm 4. `NSVisualEffectView` at `.underWindowBackground`, the pre-26
    /// material, in the same 22 pt strip with the same absent tint. Not a
    /// candidate: the control that says how much of any difference above is glass
    /// rather than blur. If arms 2 and 3 are indistinguishable from this one,
    /// nothing in Plans 2-6 is buying refraction and the verdict has to say so.
    case visualEffectControl = "4-nsvisualeffect-control"

    var extendsSurfaceUnderBar: Bool { self == .untintedOverSurface }

    var isTinted: Bool { self == .shippedTinted }

    var usesGlass: Bool { self != .visualEffectControl }
}

/// One pane-shaped window: a translucent surface stand-in over a non-opaque
/// window, and a 22 pt bar along the bottom rendered per arm.
final class ProbeWindow: NSWindow {
    let arm: Arm
    private let surface = SurfaceStandIn()
    private var bar: NSView?

    init(arm: Arm, contentRect: NSRect) {
        self.arm = arm
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // The pane's own arrangement: a non-opaque window with a clear background,
        // which is what lets the 0.42 well composite over the desktop at all.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        // `isMovable = true` deliberately, against the 26.2 regression in §6.8:
        // glass inside a borderless *non-movable* transparent window stops
        // re-sampling as content moves beneath it (forums 810314), and the
        // documented partial workaround is exactly this flag. A probe that left it
        // false would be measuring the bug rather than the material, and would
        // report "glass does not lens" for a reason that has nothing to do with
        // the backdrop question this exists to answer.
        isMovable = true

        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]

        let content = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        content.wantsLayer = true
        contentView = content

        let barHeight = PaneStatusBarMetrics.height

        // The one layout difference between (A) and (B), and the whole reason the
        // grid question exists: under arm 3 the surface view's frame runs to the
        // window's bottom edge and the bar overlaps its last 22 pt. Under every
        // other arm the surface stops where the bar begins.
        surface.frame = NSRect(
            x: 0,
            y: arm.extendsSurfaceUnderBar ? 0 : barHeight,
            width: contentRect.width,
            height: arm.extendsSurfaceUnderBar
                ? contentRect.height
                : contentRect.height - barHeight
        )
        surface.autoresizingMask = [.width, .height]
        content.addSubview(surface)

        let barFrame = NSRect(x: 0, y: 0, width: contentRect.width, height: barHeight)
        let bar = Self.makeBar(arm: arm, frame: barFrame)
        // Above the surface in every arm. Under arms 1, 2 and 4 they do not
        // overlap so the ordering is inert; under arm 3 it is load-bearing, and it
        // is the opposite of Ghostty's arrangement, which puts glass *below* the
        // terminal view. Theirs cannot lens in-window content by construction.
        content.addSubview(bar, positioned: .above, relativeTo: surface)
        self.bar = bar
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }

    /// The bar for one arm.
    ///
    /// The glass path mirrors `PaneStatusBarView.applyResolvedChrome()` and
    /// `updateGlassTint()` rather than paraphrasing them: `.regular` style,
    /// `cornerRadius = 0`, `tintColor` from `MaterialSet.fillChrome` when tinted.
    /// The values are read off `PaneChrome` at run time, not transcribed, so an
    /// arm cannot grade the shipped state against numbers that have moved.
    static func makeBar(arm: Arm, frame: NSRect) -> NSView {
        let label = BarContentView(frame: NSRect(origin: .zero, size: frame.size))
        label.autoresizingMask = [.width, .height]

        guard arm.usesGlass else {
            let effect = NSVisualEffectView(frame: frame)
            effect.material = .underWindowBackground
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.autoresizingMask = [.width]
            effect.addSubview(label)
            return effect
        }

        let glass = NSGlassEffectView(frame: frame)
        glass.style = .regular
        glass.cornerRadius = 0
        if arm.isTinted {
            // `MaterialSet.dark.fillChrome`, the exact value the shipped footer
            // writes onto its backing for an unfocused pane. Read from the package
            // rather than spelled here.
            // The identical conversion `PaneStatusBarView.nsColor(_:alpha:)`
            // performs: `RGB`'s components are already 0...1, so they go into
            // `srgbRed:` unscaled. Dividing by 255 here would have tinted the bar
            // with near-black at the shipped alpha and made arm 1 look like a
            // problem the shipped code does not have.
            let fill = MaterialSet.dark.fillChrome
            glass.tintColor = NSColor(
                srgbRed: CGFloat(fill.rgb.red),
                green: CGFloat(fill.rgb.green),
                blue: CGFloat(fill.rgb.blue),
                alpha: CGFloat(fill.alpha)
            )
        }
        // `contentView`, never `addSubview`: assigning it is what lets AppKit
        // apply the legibility treatments as the glass adapts, and the shipped
        // code's own doc comment says so.
        glass.contentView = label
        glass.autoresizingMask = [.width]
        return glass
    }
}

/// What the bar draws: the segments a real footer carries, at the real sizes, so
/// the captures grade legibility rather than an empty band.
final class BarContentView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func draw(_: NSRect) {
        let inset = PaneStatusBarMetrics.horizontalInset
        let baseline = PaneStatusBarMetrics.baselineFromTop

        // The attention capsule, drawn rather than glassed. Which of the two it
        // should be is the second question this probe carries (glass-in-container
        // versus drawn-on-glass), and drawing it here is the *baseline*: the
        // captures show what a drawn capsule on a bar's glass looks like, and the
        // container arm below shows the alternative in the same window.
        let capsule = PaneStatusBarMetrics.attentionCapsuleFrame(glyphWidth: 7)
        let capsuleRect = NSRect(
            x: capsule.x, y: capsule.y, width: capsule.width, height: capsule.height
        )
        NSColor(srgbRed: 0.92, green: 0.55, blue: 0.15, alpha: 0.9).setFill()
        NSBezierPath(
            roundedRect: capsuleRect,
            xRadius: capsuleRect.height / 2,
            yRadius: capsuleRect.height / 2
        ).fill()

        let glyph: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        "!".draw(at: NSPoint(x: capsuleRect.midX - 2.5, y: capsuleRect.minY + 2), withAttributes: glyph)

        let text: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(white: 0.92, alpha: 1),
        ]
        let x = inset + capsule.width + PaneStatusBarMetrics.capsuleGap
        let line = "baia · main ↑1↓2*3 · claude · ~/Projects/baia"
        line.draw(
            at: NSPoint(x: x, y: baseline - 11),
            withAttributes: text
        )
    }
}

// MARK: - the capsule question

/// A second window per arm-2/arm-3 arrangement that renders the capsule the other
/// way: a tinted `NSGlassEffectView` capsule inside an `NSGlassEffectContainerView`
/// with the bar's own glass.
///
/// This is the arrangement the HIG permits and hand-stacking does not. Session 219
/// forbids glass on glass, but a container's managed merge is one sampling pass
/// over both shapes rather than one sampling the other, which is why
/// `NSGlassEffectContainerView` exists at all. The captures are what say whether
/// the merge reads as a distinct capsule or dissolves into the bar.
final class CapsuleWindow: NSWindow {
    static func make(contentRect: NSRect, extendsUnderBar: Bool) -> CapsuleWindow {
        let window = CapsuleWindow(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]

        let content = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        content.wantsLayer = true
        window.contentView = content

        let barHeight = PaneStatusBarMetrics.height
        let surface = SurfaceStandIn()
        surface.frame = NSRect(
            x: 0,
            y: extendsUnderBar ? 0 : barHeight,
            width: contentRect.width,
            height: extendsUnderBar ? contentRect.height : contentRect.height - barHeight
        )
        content.addSubview(surface)

        // The bar's own untinted glass, and the capsule's tinted glass, as two
        // sibling `NSGlassEffectView`s inside one container. `spacing` is what
        // decides whether they meld; 0 keeps them as distinct shapes sharing one
        // sampling pass, which is the arrangement design v5 §3 wants (one
        // prominent element *on* the bar, not fused into it).
        let container = NSGlassEffectContainerView(
            frame: NSRect(x: 0, y: 0, width: contentRect.width, height: barHeight)
        )
        container.spacing = 0

        let row = NSView(frame: NSRect(x: 0, y: 0, width: contentRect.width, height: barHeight))
        row.autoresizingMask = [.width]

        let barGlass = NSGlassEffectView(
            frame: NSRect(x: 0, y: 0, width: contentRect.width, height: barHeight)
        )
        barGlass.style = .regular
        barGlass.cornerRadius = 0
        let barLabel = BarContentView(
            frame: NSRect(x: 0, y: 0, width: contentRect.width, height: barHeight)
        )
        barLabel.autoresizingMask = [.width]
        barGlass.contentView = barLabel
        barGlass.autoresizingMask = [.width]
        row.addSubview(barGlass)

        // The capsule, tinted, as the one prominent element. `cornerRadius = 999`
        // is Apple's own sample's spelling for a capsule.
        let capsuleFrame = PaneStatusBarMetrics.attentionCapsuleFrame(glyphWidth: 7)
        let capsuleGlass = NSGlassEffectView(frame: NSRect(
            x: capsuleFrame.x,
            y: capsuleFrame.y,
            width: capsuleFrame.width,
            height: capsuleFrame.height
        ))
        capsuleGlass.style = .regular
        capsuleGlass.cornerRadius = 999
        capsuleGlass.tintColor = NSColor(
            srgbRed: 0.92, green: 0.55, blue: 0.15, alpha: 0.9
        )
        let glyphView = CapsuleGlyphView(frame: NSRect(
            origin: .zero,
            size: NSSize(width: capsuleFrame.width, height: capsuleFrame.height)
        ))
        capsuleGlass.contentView = glyphView
        row.addSubview(capsuleGlass, positioned: .above, relativeTo: barGlass)

        container.contentView = row
        content.addSubview(container, positioned: .above, relativeTo: surface)
        return window
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }
}

final class CapsuleGlyphView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_: NSRect) {
        let glyph: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        "!".draw(at: NSPoint(x: bounds.midX - 2.5, y: bounds.midY - 6), withAttributes: glyph)
    }
}

// MARK: - the sidebar question

/// A sidebar-shaped window: a 220 pt column of untinted glass over the
/// transparent window region, beside a pane stand-in.
///
/// The third question. The plan wants to avoid the
/// `NSSplitViewItemAccessoryViewController` restructure (session restore and
/// focus rules both hang off the current controller shape), and the restructure
/// is only worth its blast radius if a sidebar with its own untinted glass over
/// the transparent region fails to read. This window is that arrangement, so the
/// verdict can name a capture rather than an intuition.
final class SidebarWindow: NSWindow {
    static func make(contentRect: NSRect) -> SidebarWindow {
        let window = SidebarWindow(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]

        let content = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        content.wantsLayer = true
        window.contentView = content

        let sidebarWidth: CGFloat = 220

        // The pane beside it, at the shipped well opacity, so the capture shows
        // the sidebar's glass against both the desktop (its own backdrop) and the
        // well (its neighbour) in one frame.
        let surface = SurfaceStandIn()
        surface.frame = NSRect(
            x: sidebarWidth,
            y: 0,
            width: contentRect.width - sidebarWidth,
            height: contentRect.height
        )
        content.addSubview(surface)

        let glass = NSGlassEffectView(frame: NSRect(
            x: 0, y: 0, width: sidebarWidth, height: contentRect.height
        ))
        glass.style = .regular
        glass.cornerRadius = 0
        glass.contentView = SidebarContentView(frame: NSRect(
            x: 0, y: 0, width: sidebarWidth, height: contentRect.height
        ))
        content.addSubview(glass, positioned: .above, relativeTo: surface)
        return window
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }
}

final class SidebarContentView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_: NSRect) {
        let header: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor(white: 0.62, alpha: 1),
        ]
        let row: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: NSColor(white: 0.90, alpha: 1),
        ]
        "CHANGED".draw(at: NSPoint(x: 12, y: 16), withAttributes: header)
        var y: CGFloat = 40
        for name in [
            "Sources/PaneStatusBarView.swift",
            "Sources/PaneTreeController.swift",
            "Packages/PaneChrome/ChromeMaterials.swift",
            "Diagnostics/glass-backdrop/run.sh",
            "project.yml",
        ] {
            name.draw(at: NSPoint(x: 12, y: y), withAttributes: row)
            y += 22
        }
    }
}

// MARK: - capture

/// Captures a window by id through `screencapture -l`, which is what
/// `Diagnostics/lib/drive.sh:shot` does for the real app.
///
/// `-l <windowid>` rather than a screen rectangle, and that choice is the whole
/// reason this probe can measure anything. A screen grab of the region would be
/// composited by the window server the same way, but it would also capture
/// whatever else the owner has on screen at that rectangle, and a probe whose
/// output depends on the owner's open windows is not reproducible.
///
/// `-o` is deliberately absent: it excludes window shadow *and* the windows
/// behind, and the backdrop behind is the thing being sampled. Without the
/// backdrop in the frame every arm captures as a bar over nothing.
func capture(windowNumber: Int, to path: String) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-l", String(windowNumber), path]
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        FileHandle.standardError.write("capture failed to launch: \(error)\n".data(using: .utf8)!)
        return false
    }
    guard task.terminationStatus == 0, FileManager.default.fileExists(atPath: path) else {
        return false
    }
    return true
}

/// Runs the run loop for a fixed interval without blocking the window server.
///
/// `Thread.sleep` would stop the run loop, and a glass view that has not had a
/// display pass captures as an unsampled slab: two runs during this probe's
/// development produced flat grey bars for exactly that reason. The window has to
/// be composited before it can be photographed.
func settle(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

// MARK: - main

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSTemporaryDirectory() + "baia-glass-backdrop"

try? FileManager.default.createDirectory(
    atPath: outputDirectory, withIntermediateDirectories: true
)

let app = NSApplication.shared
// `.accessory`, never `.regular`. This is the `SAFE_PROBES` standard: an
// accessory app has no Dock tile, no menu bar, and cannot become active, so the
// probe's windows are composited without the owner's focus ever moving. Every
// window below is `orderFrontRegardless()`, never `makeKeyAndOrderFront`.
app.setActivationPolicy(.accessory)

guard let screen = NSScreen.main else {
    FileHandle.standardError.write("no screen\n".data(using: .utf8)!)
    exit(1)
}

let screenFrame = screen.frame
let backdrop = BackdropWindow.make(covering: screenFrame)
backdrop.orderFrontRegardless()

// The pane is centred on the white/black seam, so every capture carries the
// bright half and the dark half of the backdrop in one frame. Two captures over
// two flat fields would answer "is it legible over white" and "is it legible over
// black" separately; one capture across the seam additionally answers "does the
// edge bend", which is the refraction question and the only one the flat-field
// pair cannot reach.
let paneWidth: CGFloat = 720
let paneHeight: CGFloat = 320
let paneFrame = NSRect(
    x: screenFrame.midX - paneWidth / 2,
    y: screenFrame.midY - paneHeight / 2,
    width: paneWidth,
    height: paneHeight
)

settle(0.6)

var failures = 0

func record(_ window: NSWindow, _ name: String) {
    window.orderFrontRegardless()
    settle(0.8)
    let path = outputDirectory + "/" + name + ".png"
    if capture(windowNumber: window.windowNumber, to: path) {
        print("captured \(name).png")
    } else {
        print("CAPTURE FAILED \(name)")
        failures += 1
    }
}

for arm in Arm.allCases {
    let window = ProbeWindow(arm: arm, contentRect: paneFrame)
    record(window, "arm-" + arm.rawValue)
    window.orderOut(nil)
}

// The capsule question, in both candidate backdrop arrangements, because the
// answer may depend on which one wins: a container merge over the desktop and a
// container merge over well pixels are not the same sampling problem.
let capsuleBeside = CapsuleWindow.make(contentRect: paneFrame, extendsUnderBar: false)
record(capsuleBeside, "capsule-container-beside")
capsuleBeside.orderOut(nil)

let capsuleOver = CapsuleWindow.make(contentRect: paneFrame, extendsUnderBar: true)
record(capsuleOver, "capsule-container-over-surface")
capsuleOver.orderOut(nil)

// The sidebar question.
let sidebarFrame = NSRect(
    x: screenFrame.midX - 460,
    y: screenFrame.midY - 220,
    width: 920,
    height: 440
)
let sidebar = SidebarWindow.make(contentRect: sidebarFrame)
record(sidebar, "sidebar-untinted-glass")
sidebar.orderOut(nil)

// The inactive-state pair for arms 2 and 3.
//
// Read the README before reading these two files. This process is `.accessory`
// and its windows are never key, so *every* capture above is already of a
// non-key window: the "inactive" pair below is not a second state, it is the
// same state captured while a foreign window is additionally frontmost. What
// that pair can prove is narrow and worth having anyway: whether glass in a
// never-key accessory window degrades further when another application is
// active. What it cannot prove is the shipped app's key-to-non-key transition,
// which is the transition Ghostty's discussion 10170 reports as jarring and
// which needs a probe that owns a key window.
for arm in [Arm.untintedBesideSurface, Arm.untintedOverSurface] {
    let window = ProbeWindow(arm: arm, contentRect: paneFrame)
    window.orderFrontRegardless()
    settle(0.5)
    // Nothing is activated and nothing is made key. The wait is what lets any
    // deactivation the window server applies to a non-key window settle.
    settle(1.0)
    let path = outputDirectory + "/inactive-" + arm.rawValue + ".png"
    if capture(windowNumber: window.windowNumber, to: path) {
        print("captured inactive-\(arm.rawValue).png")
    } else {
        print("CAPTURE FAILED inactive-\(arm.rawValue)")
        failures += 1
    }
    window.orderOut(nil)
}

backdrop.orderOut(nil)

print("")
print("output: \(outputDirectory)")
if failures > 0 {
    print("FAILED \(failures) capture(s)")
    exit(1)
}
print("PASS all captures written")
