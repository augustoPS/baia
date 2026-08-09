import AppKit
import PaneChrome

// The pane-glass-blur spike: what does an `NSGlassEffectView` plane over
// terminal-ish content look like with the window's *compositor* blur ON versus
// OFF?
//
// baia's background blur is window-wide: `CGSSetWindowBackgroundBlurRadius`
// frosts whatever the window server has behind the window, at
// `PaneChrome.parityBlurRadius` (20, ghostty's own `background-blur = true`
// value). In-window glass then samples that already-frosted composite. The
// pane-as-glass plan ships with the compositor blur OFF so the glass does all
// the lensing; this probe measures what that choice buys and what leaving the
// blur on would cost (double-lensing), against a controlled high-frequency
// backdrop whose fine detail is exactly what blur destroys.
//
// This binary never becomes key and never activates.
// `NSApp.setActivationPolicy(.accessory)` plus `orderFrontRegardless()` is the
// `SAFE_PROBES` standard `glass-backdrop` meets, and this probe copies it: the
// windows appear over whatever is in front, take no focus, and are ordered out
// again. A focus steal mid-capture would land keystrokes in whatever the owner
// was typing into.

// MARK: - the CGS SPI, mirrored from Sources/WorkspaceWindowController.swift

/// A connection to the window server. Opaque on purpose; obtained and handed
/// straight back to ``CGSSetWindowBackgroundBlurRadius(_:_:_:)``.
private typealias CGSConnectionID = UInt32

/// **Private Apple SPI**, declared exactly as the app declares it in
/// `Sources/WorkspaceWindowController.swift`, because the measurement is only
/// worth anything if the probe blurs its window through the same mechanism the
/// app blurs its windows. See that file for the full account of what relying
/// on this symbol means; the short version is that failure is silent and the
/// worst case is no blur, which this probe *detects* (the bare band's
/// fine-detail energy fails to collapse) rather than assumes away.
@_silgen_name("CGSDefaultConnectionForThread")
private func CGSDefaultConnectionForThread() -> CGSConnectionID

/// **Private Apple SPI.** Same shape as the app's declaration. Radius in
/// points; `0` removes the blur, which is what makes one live window usable
/// for both arms of this measurement.
@_silgen_name("CGSSetWindowBackgroundBlurRadius")
@discardableResult
private func CGSSetWindowBackgroundBlurRadius(
    _ connection: CGSConnectionID,
    _ windowNumber: Int,
    _ radius: Int
) -> CGError

func setCompositorBlur(_ window: NSWindow, radius: Int) {
    CGSSetWindowBackgroundBlurRadius(
        CGSDefaultConnectionForThread(), window.windowNumber, radius
    )
}

// MARK: - the controlled backdrop

/// A full-screen window of deliberate high-frequency detail, ordered below the
/// probe window: vertical gratings at four spatial frequencies, thin horizontal
/// rules, and small text in the top third.
///
/// Fine detail is what blur destroys, so the backdrop is made of it. The
/// grating repeats every 80 pt along x — 1 pt stripes, then 4 pt, then 8 pt,
/// then 16 pt — so any measurement band wider than 80 pt contains every
/// frequency and a per-band gradient number aggregates over all of them.
/// The wallpaper cannot be the backdrop for the measured arms: blur graded
/// against the owner's wallpaper is different on every machine and different
/// again next week. A separate wallpaper pair is captured anyway, labeled
/// wallpaper-dependent, because the spec question is ultimately about desktops.
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
        // Below the probe window but above everything else. glass-backdrop put
        // its backdrop at `.normal - 1`, and the first run of this probe copied
        // that and measured someone else's pixels: another probe's windows were
        // mid-screen at normal level, over this backdrop, and the reference
        // capture photographed them instead of the pattern (caught by the
        // reference gradient check). `.floating` for the backdrop and
        // `.floating + 1` for the probe window keep the pair above the normal
        // band; window level does not affect key status, so the no-focus
        // arrangement is untouched.
        window.level = .floating
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        window.contentView = PatternView(frame: NSRect(origin: .zero, size: frame.size))
        return window
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }
}

final class PatternView: NSView {
    override var isFlipped: Bool { true }

    /// Which half of a stripe pair a given x lands in, over the 80 pt unit:
    /// [0,16) 1 pt stripes, [16,32) 4 pt, [32,48) 8 pt, [48,80) 16 pt.
    private func isDarkStripe(_ x: CGFloat) -> Bool {
        let phase = x.truncatingRemainder(dividingBy: 80)
        let (base, width): (CGFloat, CGFloat) = phase < 16 ? (0, 1)
            : phase < 32 ? (16, 4)
            : phase < 48 ? (32, 8)
            : (48, 16)
        return Int((phase - base) / width) % 2 == 0
    }

    override func draw(_: NSRect) {
        let dark = NSColor(white: 0.18, alpha: 1)
        let light = NSColor(white: 0.82, alpha: 1)
        var x: CGFloat = 0
        while x < bounds.width {
            (isDarkStripe(x) ? dark : light).setFill()
            NSRect(x: x, y: 0, width: 1, height: bounds.height).fill()
            x += 1
        }

        // Thin horizontal rules, for the eye rather than the metric: the metric
        // reads horizontal gradients, which a horizontal line does not carry,
        // but a human comparing captures sees whether a 1 pt line survives.
        NSColor(white: 0.95, alpha: 1).setFill()
        var y = bounds.height * 0.05
        while y < bounds.height {
            NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
            y += 28
        }

        // Small text in the top third only, clear of the measurement bands
        // (which sit below the probe window's vertical midline, i.e. in the
        // bottom half of a centred window): the finest structure a terminal
        // owner actually cares about surviving behind a translucent window.
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(white: 0.05, alpha: 1),
        ]
        var textY = bounds.height * 0.06
        var row = 0
        while textY < bounds.height * 0.34 {
            let line = "backdrop row \(row)  0123456789 the quick brown fox il1I|.,:; == -- __"
            line.draw(at: NSPoint(x: 12, y: textY), withAttributes: attributes)
            textY += 22
            row += 1
        }
    }
}

// MARK: - the pane stand-in

/// Terminal-like content: the shipped theme-background wash at the shipped
/// 0.42 well opacity, with monospaced rows over it — except a deliberate
/// text-free gap at window-y fractions 0.56–0.84, which is where the metrics
/// read the backdrop show-through without glyph contamination.
///
/// Used twice: as the glass plane's `contentView` (the pane-as-glass
/// arrangement), and as a bare sibling view (today's arrangement, no glass).
/// One class so the two arms cannot drift apart in what they draw.
final class TerminalContentView: NSView {
    /// The shipped well opacity: `Settings.default.backgroundOpacity` is 0.42
    /// (design v5's well value, re-verified by the 2026-08-05 wells audit).
    static let wellOpacity: CGFloat = 0.42

    /// The window height, needed to place the text-free gap in *window*
    /// fractions even though this view may be inset inside the window.
    var windowHeight: CGFloat = 0

    /// This view's y offset inside the window (flipped, from the top).
    var windowYOffset: CGFloat = 0

    override var isFlipped: Bool { true }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func draw(_: NSRect) {
        // The shipped theme background, `#141414`-adjacent dark grey as
        // rendered by the dark theme's well (rgb 18,20,24 is the value the
        // glass-backdrop probe read off MaterialSet and graded against).
        NSColor(srgbRed: 18.0 / 255, green: 20.0 / 255, blue: 24.0 / 255, alpha: 1)
            .withAlphaComponent(Self.wellOpacity)
            .setFill()
        bounds.fill()

        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(white: 0.86, alpha: 1),
        ]
        let gapTop = windowHeight * 0.56
        let gapBottom = windowHeight * 0.84
        var y: CGFloat = 8
        var row = 0
        while y < bounds.height {
            let windowY = y + windowYOffset
            let rowHeight = font.boundingRectForFont.height
            if windowY + rowHeight < gapTop || windowY > gapBottom {
                let line = row % 3 == 0
                    ? "$ rg --line-number parityBlurRadius Packages/  # row \(row)"
                    : "  Packages/PaneChrome/Sources/ChromeAppearance.swift:\(280 + row)"
                line.draw(at: NSPoint(x: 8, y: y), withAttributes: attributes)
            }
            y += font.boundingRectForFont.height + 3
            row += 1
        }
    }
}

/// One pane-shaped window: a non-opaque window whose left ~100 pt stays bare
/// (backdrop shows through the transparent window region directly — the strip
/// where the compositor blur is measured on its own) and whose remainder holds
/// either the glass plane or the plain well, toggled per arm.
final class ProbeWindow: NSWindow {
    let glassPlane: NSGlassEffectView
    let plainPane: TerminalContentView

    init(contentRect: NSRect) {
        let paneInset: CGFloat = 16
        let bareMargin: CGFloat = 100
        let planeFrame = NSRect(
            x: bareMargin,
            y: paneInset,
            width: contentRect.width - bareMargin - paneInset,
            height: contentRect.height - paneInset * 2
        )

        glassPlane = NSGlassEffectView(frame: planeFrame)
        plainPane = TerminalContentView(frame: planeFrame)

        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // The pane's own arrangement: non-opaque, clear background, which is
        // what lets the compositor's backdrop show through at all.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        // One above the backdrop's `.floating`; see BackdropWindow.make for
        // why the pair sits above the normal window band.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        // Deliberate, against the 26.2 regression glass-backdrop documents
        // (§6.8 / forums 810314): glass inside a borderless *non-movable*
        // transparent window stops re-sampling. Without this flag the probe
        // measures the bug rather than the material.
        isMovable = true

        let container = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        contentView = container

        // The glass plane, untinted `.regular`, with the terminal content as
        // its `contentView` — the arrangement the pane-as-glass plan ships.
        glassPlane.style = .regular
        let glassContent = TerminalContentView(
            frame: NSRect(origin: .zero, size: planeFrame.size)
        )
        glassContent.windowHeight = contentRect.height
        glassContent.windowYOffset = paneInset
        glassPlane.contentView = glassContent
        container.addSubview(glassPlane)

        // Today's arrangement for arm (c): the same content with no glass under
        // it, over the same transparent window — the well plus the compositor
        // blur and nothing else.
        plainPane.windowHeight = contentRect.height
        plainPane.windowYOffset = paneInset
        plainPane.isHidden = true
        container.addSubview(plainPane)
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }

    func showGlass(_ glass: Bool) {
        glassPlane.isHidden = !glass
        plainPane.isHidden = glass
    }
}

// MARK: - capture

/// Runs `screencapture` and reports whether it wrote the file.
func runScreencapture(_ arguments: [String], to path: String) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x"] + arguments + [path]
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        FileHandle.standardError.write("capture failed to launch: \(error)\n".data(using: .utf8)!)
        return false
    }
    return task.terminationStatus == 0 && FileManager.default.fileExists(atPath: path)
}

/// The `-R` rect for a window frame, in the global display coordinates
/// `screencapture` wants: origin at the main display's top-left, y growing
/// downward, each edge rounded and the size derived from the rounded edges.
/// Same conversion glass-backdrop uses, for the same reasons its capture
/// comment records.
func screenRect(for frame: NSRect) -> String? {
    guard let main = NSScreen.screens.first else { return nil }
    let left = frame.minX.rounded()
    let right = frame.maxX.rounded()
    let top = (main.frame.maxY - frame.maxY).rounded()
    let bottom = (main.frame.maxY - frame.minY).rounded()
    return "\(Int(left)),\(Int(top)),\(Int(right - left)),\(Int(bottom - top))"
}

/// Captures the *screen composite* over `frame` as `<name>.png` — the primary
/// route here, because the compositor blur exists only in the window server's
/// composite; the window's own backing store never contains it. When a window
/// is passed, its backing store is also written as `<name>-window.png`
/// (`screencapture -l`), which is the file that answers the side question of
/// whether the SPI changes what *glass itself* samples: glass composites its
/// sampled backdrop into its own buffer, so if the two `-window` files differ
/// between the blur-off and blur-on arms, the SPI feeds glass sampling; if
/// they are identical, it does not.
///
/// `-R` carries the display's brightness and EDR tone response at capture
/// time, so every number read off these files is within-run comparable only.
/// glass-backdrop measured pure white crushed to 21% luminance by that curve;
/// nothing here quotes an absolute across runs.
func capture(frame: NSRect, window: NSWindow?, to path: String) -> Bool {
    guard let rect = screenRect(for: frame) else { return false }
    guard runScreencapture(["-R", rect], to: path) else { return false }
    if let window {
        let windowPath = path.replacingOccurrences(of: ".png", with: "-window.png")
        // Best-effort: the -l companion is diagnostic for the sampling
        // question, and losing it must not fail a run whose measured -R file
        // was written.
        _ = runScreencapture(["-l", String(window.windowNumber)], to: windowPath)
    }
    return true
}

// MARK: - band metrics, for settle verification only

/// Mean luminance and mean absolute horizontal-neighbour luminance difference
/// over a fractional band of a capture. The README's numbers come from
/// `analyze.py` over the written files; this in-process copy exists so the
/// probe can *verify* that the SPI took effect (bare-band fine energy
/// collapses) and retry the settle, rather than photographing an
/// un-recomposited frame and reporting it as a measurement.
func bandMetrics(
    _ path: String, fx0: Double, fy0: Double, fx1: Double, fy1: Double
) -> (mean: Double, gradient: Double)? {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return nil }
    let width = cg.width
    let height = cg.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: &pixels,
              width: width,
              height: height,
              bitsPerComponent: 8,
              bytesPerRow: width * 4,
              space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }
    context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

    // CGContext rows run bottom-up relative to the flipped fractions used
    // everywhere else in this probe; flip y.
    let x0 = max(Int(Double(width) * fx0), 0)
    let x1 = min(Int(Double(width) * fx1), width - 1)
    let yTop = max(Int(Double(height) * fy0), 0)
    let yBottom = min(Int(Double(height) * fy1), height - 1)
    guard x1 > x0 + 1, yBottom > yTop else { return nil }

    var sum = 0.0
    var gradientSum = 0.0
    var count = 0
    var gradientCount = 0
    for fy in yTop ... yBottom {
        let y = height - 1 - fy
        var previous: Double?
        for x in x0 ... x1 {
            let offset = (y * width + x) * 4
            let lum = (Double(pixels[offset]) + Double(pixels[offset + 1])
                + Double(pixels[offset + 2])) / 3
            sum += lum
            count += 1
            if let p = previous {
                gradientSum += abs(lum - p)
                gradientCount += 1
            }
            previous = lum
        }
    }
    return (sum / Double(count), gradientSum / Double(gradientCount))
}

/// Runs the run loop for a fixed interval without blocking the window server.
/// `Thread.sleep` would stop the run loop, and a glass view that has not had a
/// display pass captures as an unsampled slab (glass-backdrop lost two runs to
/// exactly that).
func settle(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

// MARK: - main

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSTemporaryDirectory() + "baia-pane-glass-blur"

try? FileManager.default.createDirectory(
    atPath: outputDirectory, withIntermediateDirectories: true
)

let app = NSApplication.shared
// `.accessory`, never `.regular`: no Dock tile, no menu bar, cannot become
// active. Every window below is `orderFrontRegardless()`, never
// `makeKeyAndOrderFront`.
app.setActivationPolicy(.accessory)

guard let screen = NSScreen.main else {
    FileHandle.standardError.write("no screen\n".data(using: .utf8)!)
    exit(1)
}

let screenFrame = screen.frame
let paneWidth: CGFloat = 720
let paneHeight: CGFloat = 420
let paneFrame = NSRect(
    x: screenFrame.midX - paneWidth / 2,
    y: screenFrame.midY - paneHeight / 2,
    width: paneWidth,
    height: paneHeight
)

// The app's radius, read off PaneChrome at run time rather than transcribed,
// through the same derivation the window controller calls: shipped defaults
// (blur on, opacity 0.42, no accessibility overrides) resolve to
// `parityBlurRadius`. If the derivation or the constant moves, this probe
// grades against the moved value.
// `paneGlassActive: false` because the number being asked for is the flat
// radius: this probe exists to compare the compositor blur against a glass
// plane, and its own measurement is what later taught `windowBlurRadius` to
// return 0 under a plane. Passing `true` here would ask the derivation for the
// answer the probe is meant to justify.
let appRadius = windowBlurRadius(
    backgroundBlur: true,
    backgroundOpacity: 0.42,
    appearance: ChromeAppearance(isDark: true, reduceTransparency: false, reduceMotion: false),
    paneGlassActive: false
)
guard appRadius > 0 else {
    FileHandle.standardError.write(
        "windowBlurRadius resolved to 0 for the shipped defaults; nothing to measure\n"
            .data(using: .utf8)!
    )
    exit(1)
}
print("app blur radius (PaneChrome.windowBlurRadius, shipped defaults): \(appRadius)")

var failures = 0
var surprises: [String] = []

// The measurement bands, as window fractions. Kept in lockstep with run.sh and
// the README:
//   bare  band  x 0.02–0.11, y 0.60–0.80 — transparent window region left of
//               the plane: the compositor blur alone, no material over it.
//   glass band  x 0.35–0.85, y 0.60–0.80 — inside the plane, inside the
//               text-free gap (window-y 0.56–0.84), so no glyph contaminates
//               the show-through numbers.
let bandY0 = 0.60
let bandY1 = 0.80

let backdrop = BackdropWindow.make(covering: screenFrame)
backdrop.orderFrontRegardless()
settle(0.8)

func record(_ name: String, window: NSWindow?, settleFor: TimeInterval = 1.2) -> String {
    settle(settleFor)
    let path = outputDirectory + "/" + name + ".png"
    if capture(frame: paneFrame, window: window, to: path) {
        print("captured \(name).png")
    } else {
        print("CAPTURE FAILED \(name)")
        failures += 1
    }
    return path
}

// --- reference: the backdrop alone, same rect, no probe window -------------
let referencePath = record("backdrop-reference", window: nil)
guard let reference = bandMetrics(referencePath, fx0: 0.35, fy0: bandY0, fx1: 0.85, fy1: bandY1),
      reference.gradient > 5
else {
    FileHandle.standardError.write(
        "backdrop reference carries no fine detail; the pattern window did not render\n"
            .data(using: .utf8)!
    )
    exit(1)
}
print(String(format: "reference band: mean %.1f, gradient %.2f", reference.mean, reference.gradient))

// --- the probe window ------------------------------------------------------
let probe = ProbeWindow(contentRect: paneFrame)
probe.showGlass(true)
setCompositorBlur(probe, radius: 0)
probe.orderFrontRegardless()

// Arm (a): blur OFF, glass plane only — the pane-as-glass plan as specced.
// Verified by the bare band: with the compositor blur off, the transparent
// margin must show the grating essentially intact. Escalating settle, so an
// unfinished frame is retried rather than measured.
var armAPath = ""
for attempt in 1 ... 5 {
    armAPath = record("arm-a-blur-off-glass", window: probe, settleFor: 1.2 * Double(attempt))
    if let bare = bandMetrics(armAPath, fx0: 0.02, fy0: bandY0, fx1: 0.11, fy1: bandY1),
       bare.gradient > reference.gradient * 0.6 {
        break
    }
    if attempt == 5 {
        surprises.append(
            "arm (a): the bare band never reached 60% of the reference gradient — "
                + "the transparent region is dimming or frosting detail with the SPI at 0"
        )
    }
}

// Arm (b): blur ON at the app's radius, same glass plane — what shipping
// pane-as-glass without turning the compositor blur off would look like.
// Verified by the bare band collapsing: that is the SPI observably taking
// effect on this window, through the same call the app makes. If it never
// collapses, that is a result (the SPI not working here), stated rather than
// hidden.
setCompositorBlur(probe, radius: appRadius)
var armBPath = ""
var spiTookEffect = false
for attempt in 1 ... 5 {
    armBPath = record("arm-b-blur-on-glass", window: probe, settleFor: 1.2 * Double(attempt))
    if let bare = bandMetrics(armBPath, fx0: 0.02, fy0: bandY0, fx1: 0.11, fy1: bandY1),
       let armABare = bandMetrics(armAPath, fx0: 0.02, fy0: bandY0, fx1: 0.11, fy1: bandY1),
       bare.gradient < armABare.gradient * 0.5 {
        spiTookEffect = true
        break
    }
}
if !spiTookEffect {
    surprises.append(
        "the CGS SPI did not measurably frost the bare band at radius \(appRadius): "
            + "bare-band fine energy stayed within 50% of the blur-off arm"
    )
}

// Arm (c): blur ON, no glass — the today-reference. The shipped arrangement:
// the 0.42 well and its text over the compositor blur, no glass material.
probe.showGlass(false)
let armCPath = record("arm-c-blur-on-noglass", window: probe, settleFor: 1.6)

// Arm (d): blur OFF, no glass — the raw show-through control, so the
// glass-only and blur-only arms can each be read against the same unfrosted
// well.
setCompositorBlur(probe, radius: 0)
let armDPath = record("arm-d-blur-off-noglass", window: probe, settleFor: 1.6)
_ = armCPath
_ = armDPath

// --- the wallpaper pair, labeled wallpaper-dependent ------------------------
// Same two glass arms over the owner's real desktop. Nothing measured off
// these transfers to another machine or another week; they exist because the
// spec question is ultimately about desktops, and a reader deserves one
// eye-level pair over a real one.
probe.showGlass(true)
backdrop.orderOut(nil)
setCompositorBlur(probe, radius: 0)
_ = record("wallpaper-blur-off-glass", window: probe, settleFor: 1.6)
setCompositorBlur(probe, radius: appRadius)
_ = record("wallpaper-blur-on-glass", window: probe, settleFor: 1.6)
// The wallpaper reference needs the probe window gone, not just the backdrop.
probe.orderOut(nil)
_ = record("wallpaper-reference", window: nil, settleFor: 0.6)

for surprise in surprises {
    print("SURPRISE: \(surprise)")
}

print(failures == 0 ? "all captures written" : "\(failures) capture(s) failed")
exit(failures == 0 ? 0 : 1)
