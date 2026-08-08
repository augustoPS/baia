import AppKit
import PaneChrome

// The pane-wash opacity sweep: terminal ink straight over a real
// `NSGlassEffectView` plane fails legibility (glass-backdrop finding 6b measured
// raw ink at 1.19:1 over bright glass). The planned repair is a wash —
// `theme.background` painted at opacity α over the glass plane, under the text —
// and this binary renders that arrangement at each α so the contrast curve can be
// measured rather than assumed.
//
// Per capture: a non-opaque pane-shaped window holding, bottom to top,
//
//   1. an `NSGlassEffectView` plane filling the window (`.regular`, untinted,
//      `cornerRadius = 0`),
//   2. a wash view filling the plane with `theme.background` at α,
//   3. terminal-like rows in `theme.foreground` at 11.5 pt monospaced — with an
//      **ink-free band** at a known y-fraction, because contrast must be sampled
//      from backdrop rows carrying no glyphs (the ink-contamination lesson from
//      glass-backdrop: a band through glyph rows compares the ink against a
//      region containing that same ink and inflates the ratio).
//
// The wash and the text are *siblings above* the glass rather than its
// `contentView`, deliberately: `contentView` invites AppKit's legibility
// treatments (see glass-backdrop's arm notes), and the number this probe wants is
// what the wash buys on its own.
//
// Theme values are read off `PaneChrome` at run time (`PaneTheme.darkPastel`:
// background `#141414`, foreground `#bbbbbb`) rather than transcribed, per the
// same rule every glass-backdrop arm follows.
//
// This binary never becomes key and never activates.
// `NSApp.setActivationPolicy(.accessory)` plus `orderFrontRegardless()` is the
// `SAFE_PROBES` standard (`guard-baia-alive.sh`: the criterion is focus, not
// invisibility). Windows appear over whatever is in front for the capture
// session, take no focus, and are ordered out again.

// MARK: - shared geometry
//
// These fractions are the contract between this binary and `measure.py`, which
// hardcodes the same values. Change one, change both.

enum Bands {
    /// The ink-free band: no glyph row may intersect height × 0.55...0.80.
    static let inkFreeTop: CGFloat = 0.55
    static let inkFreeBottom: CGFloat = 0.80
    /// Where the settle check reads the band (inside the ink-free band with
    /// margin on both sides; `measure.py` samples y 0.60-0.75).
    static let checkY = 0.675
}

// MARK: - the controlled backdrop

/// A full-screen window: pure white on the left half, pure black on the right,
/// ordered below the probe window. Same arrangement as glass-backdrop, and for
/// the same reason: glass samples what is behind the window, so the backdrop has
/// to be controlled or every number is a photograph of the owner's wallpaper.
/// One seam-straddling capture carries both extremes in a single frame, which is
/// what keeps the whole sweep inside one capture session.
///
/// No mid-grey ruler lines (glass-backdrop drew them to make refraction visible):
/// this probe measures band means, not edge displacement, and a ruler behind the
/// sample band would contaminate the mean it exists to keep clean.
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
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        window.contentView = BackdropView(frame: NSRect(origin: .zero, size: frame.size))
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
    }
}

// MARK: - the pane

/// The wash: `theme.background` at α, filling the plane.
final class WashView: NSView {
    var color: NSColor = .clear

    override var isFlipped: Bool { true }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func draw(_: NSRect) {
        color.setFill()
        bounds.fill()
    }
}

/// Terminal-like rows at the terminal's own scale, with the ink-free band held
/// clear. Lines are repeated to span the full width so the glyph band carries ink
/// on **both** halves of the seam — `measure.py` samples the ink from each half.
final class TerminalTextView: NSView {
    var ink: NSColor = .white

    override var isFlipped: Bool { true }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func draw(_: NSRect) {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: ink,
        ]
        let pitch = font.boundingRectForFont.height + 3
        let bandTop = bounds.height * Bands.inkFreeTop
        let bandBottom = bounds.height * Bands.inkFreeBottom
        var y: CGFloat = 8
        var row = 0
        while y + pitch < bounds.height - 4 {
            defer {
                y += pitch
                row += 1
            }
            // The ink-free band, with 2 pt of margin on either side. A glyph
            // descender straying into the sample band is exactly the
            // contamination the band exists to exclude.
            if y + pitch > bandTop - 2, y < bandBottom + 2 { continue }
            let base = row % 3 == 0
                ? "$ git status --porcelain=v2 --branch  # row \(row)  "
                : "  MM Sources/PaneSurfaceView.swift  wash sweep \(row)  "
            String(repeating: base, count: 4)
                .draw(at: NSPoint(x: 10, y: y), withAttributes: attributes)
        }
    }
}

/// One pane at one wash opacity: glass plane, wash, text.
final class WashSweepWindow: NSWindow {
    init(contentRect: NSRect, washAlpha: CGFloat, theme: PaneTheme) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Against the 26.2 regression (glass in borderless *non-movable*
        // transparent windows stops re-sampling; forums 810314). Same flag every
        // glass-backdrop window sets, for the same reason.
        isMovable = true
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]

        let bounds = NSRect(origin: .zero, size: contentRect.size)
        let content = NSView(frame: bounds)
        content.wantsLayer = true
        contentView = content

        let glass = NSGlassEffectView(frame: bounds)
        glass.style = .regular
        glass.cornerRadius = 0
        glass.autoresizingMask = [.width, .height]
        content.addSubview(glass)

        let wash = WashView(frame: bounds)
        wash.color = NSColor(
            srgbRed: CGFloat(theme.background.red),
            green: CGFloat(theme.background.green),
            blue: CGFloat(theme.background.blue),
            alpha: washAlpha
        )
        wash.autoresizingMask = [.width, .height]
        content.addSubview(wash, positioned: .above, relativeTo: glass)

        let text = TerminalTextView(frame: bounds)
        text.ink = NSColor(
            srgbRed: CGFloat(theme.foreground.red),
            green: CGFloat(theme.foreground.green),
            blue: CGFloat(theme.foreground.blue),
            alpha: 1
        )
        text.autoresizingMask = [.width, .height]
        content.addSubview(text, positioned: .above, relativeTo: wash)
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }
}

// MARK: - capture
//
// Lifted from glass-backdrop, whose README records why both routes exist.
//
// **Measured 2026-08-08: for this material the measured route is `-R`, and the
// first version of this probe assumed `-l` and was wrong.** glass-backdrop's
// 22 pt bar glass composited its sampled backdrop into its own window's buffer,
// so `-l` saw it. This probe's *full-pane* glass plane does not: its `-l` band
// reads a flat `(20, 20, 20, 255)` slab at every α including α = 0, while the
// `-R` companion carries the white/black split — the same behaviour
// glass-backdrop recorded for its 220 pt sidebar column ("their `-l` files are
// flat slabs however long the probe waits"). A pane-sized glass plane
// composites at the window-server level, and only the screen grab sees it.
// The consequence is inherited with the route: `-R` carries the display's
// brightness and EDR tone response at capture time, so every absolute in this
// probe is within-run only. `-l` files are still written; they are the record
// of the flat-slab negative result and the check on the drawn ink value.

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

func capture(window: NSWindow, to path: String) -> Bool {
    guard runScreencapture(["-l", String(window.windowNumber)], to: path) else {
        return false
    }
    if let main = NSScreen.screens.first {
        let frame = window.frame
        let left = frame.minX.rounded()
        let right = frame.maxX.rounded()
        let top = (main.frame.maxY - frame.maxY).rounded()
        let bottom = (main.frame.maxY - frame.minY).rounded()
        let rect = "\(Int(left)),\(Int(top)),\(Int(right - left)),\(Int(bottom - top))"
        let screenPath = path.replacingOccurrences(of: ".png", with: "-screen.png")
        _ = runScreencapture(["-R", rect], to: screenPath)
    }
    return true
}

/// Reads one pixel out of a capture, including its alpha byte.
///
/// The alpha byte is what established the negative result recorded above: the
/// `-l` band arrived opaque (α = 255) *and* flat at every wash opacity, which
/// is a rendered slab rather than an uncomposited translucent layer — the glass
/// paints its placeholder into the buffer and the sampled backdrop never joins
/// it there.
func samplePixel(_ path: String, fx: Double, fy: Double) -> (Int, Int, Int, Int)? {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return nil }
    let x = min(max(Int(Double(cg.width) * fx), 0), cg.width - 1)
    let y = min(max(Int(Double(cg.height) * fy), 0), cg.height - 1)

    var pixel = [UInt8](repeating: 0, count: 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: &pixel,
              width: 1,
              height: 1,
              bitsPerComponent: 8,
              bytesPerRow: 4,
              space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }
    context.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
    return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]), Int(pixel[3]))
}

/// Did this capture's ink-free band actually sample the backdrop?
///
/// Checked against the **`-R` companion**, because that is the only route that
/// sees this material at all (see the capture note above: the full-pane glass
/// plane composites at the window-server level, and its `-l` band is a flat
/// slab at every α — verified in this probe's first run, where the check read
/// `-l` and every glass capture failed it while the `-R` files carried the
/// split). Glass that sampled a white/black seam carries tens of units of
/// difference between the halves; glass that did not is flat. The split
/// requirement is skipped when the wash is opaque and would lawfully hide it.
func bandSampled(_ path: String, requireSplit: Bool) -> Bool {
    let screenPath = path.replacingOccurrences(of: ".png", with: "-screen.png")
    guard FileManager.default.fileExists(atPath: screenPath) else { return false }
    guard let l = samplePixel(screenPath, fx: 0.22, fy: Bands.checkY),
          let r = samplePixel(screenPath, fx: 0.78, fy: Bands.checkY) else { return false }
    guard requireSplit else { return true }
    let delta = abs(l.0 - r.0) + abs(l.1 - r.1) + abs(l.2 - r.2)
    return delta > 12
}

/// Runs the run loop for a fixed interval without blocking the window server.
/// `Thread.sleep` would stop the run loop and the glass would capture unsampled.
func settle(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

// MARK: - main

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSTemporaryDirectory() + "baia-pane-glass-legibility"

try? FileManager.default.createDirectory(
    atPath: outputDirectory, withIntermediateDirectories: true
)

let app = NSApplication.shared
// `.accessory`, never `.regular`: no Dock tile, no menu bar, cannot become
// active. Every window below is `orderFrontRegardless()`, never
// `makeKeyAndOrderFront`, and none can become key.
app.setActivationPolicy(.accessory)

guard let screen = NSScreen.main else {
    FileHandle.standardError.write("no screen\n".data(using: .utf8)!)
    exit(1)
}

let theme = PaneTheme.darkPastel
let screenFrame = screen.frame

let paneWidth: CGFloat = 640
let paneHeight: CGFloat = 360
// Centred on the seam: white under the left half, black under the right.
let paneFrame = NSRect(
    x: screenFrame.midX - paneWidth / 2,
    y: screenFrame.midY - paneHeight / 2,
    width: paneWidth,
    height: paneHeight
)

let backdrop = BackdropWindow.make(covering: screenFrame)
backdrop.orderFrontRegardless()
settle(0.6)

var failures = 0

// The tone-response calibration: a strip of the *bare* backdrop, above where
// the pane will sit, captured through the same `-R` route as the sweep. The
// display's brightness/EDR response moves between runs (glass-backdrop measured
// pure white at `#373737` one day and `#7d7d7d` another), and every absolute in
// this run is a function of it. This file is what pins "bright half" to a
// number a reader can compare across runs — not to transfer the absolutes, but
// to see how far apart two runs' tone curves were.
do {
    let stripHeight: CGFloat = 80
    let stripY = paneFrame.maxY + 40
    if let main = NSScreen.screens.first {
        let left = (screenFrame.midX - paneWidth / 2).rounded()
        let top = (main.frame.maxY - (stripY + stripHeight)).rounded()
        let rect = "\(Int(left)),\(Int(top)),\(Int(paneWidth)),\(Int(stripHeight))"
        if runScreencapture(["-R", rect], to: outputDirectory + "/calibration.png") {
            print("captured calibration.png (bare backdrop through this run's tone response)")
        } else {
            print("CAPTURE FAILED calibration")
            failures += 1
        }
    }
}
let baseSettle: TimeInterval = 0.8

/// The sweep, finer between 0.5 and 0.8 where the prior numbers put the 4.5:1
/// crossing (glass over the white half read `#a6a6a6` in glass-backdrop, and
/// `#141414` at α over that crosses `#4c4c4c` — the backdrop `#bbbbbb` needs for
/// 4.5:1 — near α 0.6). 1.0 is the shipped-equivalent reference: a fully opaque
/// wash, today's near-solid well.
let alphas: [CGFloat] = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8, 0.9, 1.0]

for alpha in alphas {
    let name = String(format: "sweep-a%03d", Int((alpha * 100).rounded()))
    let window = WashSweepWindow(contentRect: paneFrame, washAlpha: alpha, theme: theme)
    window.orderFrontRegardless()
    let path = outputDirectory + "/" + name + ".png"
    // No split required at α ≥ 0.9: a 0.9 wash leaves ~10% of a tone-curved
    // backdrop difference, which measured under the 12-unit flatness threshold
    // on the first run (the capture was fine; the check was too strict for it).
    let requireSplit = alpha <= 0.8
    var written = false
    for attempt in 1 ... 6 {
        settle(baseSettle * Double(attempt))
        guard capture(window: window, to: path) else {
            print("CAPTURE FAILED \(name)")
            failures += 1
            written = true
            break
        }
        if bandSampled(path, requireSplit: requireSplit) {
            print("captured \(name).png\(attempt > 1 ? " (settled on attempt \(attempt))" : "")")
            written = true
            break
        }
    }
    if !written {
        print("CAPTURE UNSAMPLED \(name) — band not opaque or glass never sampled in 6 attempts")
        failures += 1
    }
    window.orderOut(nil)
}

// For the record only: two opacities over the owner's real wallpaper, backdrop
// ordered out. These captures are wallpaper-dependent by construction — a
// different machine, or the same machine next week, photographs a different
// backdrop — and `measure.py` labels them so. No sampled-split check: the
// wallpaper's two halves are not controlled, so a flat band could be lawful.
backdrop.orderOut(nil)
settle(0.5)
for alpha: CGFloat in [0.0, 0.65] {
    let name = String(format: "wallpaper-a%03d", Int((alpha * 100).rounded()))
    let window = WashSweepWindow(contentRect: paneFrame, washAlpha: alpha, theme: theme)
    window.orderFrontRegardless()
    settle(2.0)
    let path = outputDirectory + "/" + name + ".png"
    if capture(window: window, to: path) {
        print("captured \(name).png (wallpaper-dependent)")
    } else {
        print("CAPTURE FAILED \(name)")
        failures += 1
    }
    window.orderOut(nil)
}

print("")
print("output: \(outputDirectory)")
if failures > 0 {
    print("FAILED \(failures) capture(s)")
    exit(1)
}
print("PASS all captures written")
