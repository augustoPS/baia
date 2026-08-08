import AppKit

// Does an untinted NSGlassEffectView plane behind a pane flatten/desaturate when
// its window stops being key, and is there a knob that pins the key-state look?
// See README.md. This probe TAKES KEY for about two seconds by design; run.sh
// carries the warning and the restore discipline.

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// MARK: - Harness

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

/// The app that owns the keyboard right now. Recorded before anything else so
/// the probe can hand focus back to exactly where it took it from.
let previousFront = NSWorkspace.shared.frontmostApplication

var stateLog = ""
func log(_ line: String) {
    print(line)
    stateLog += line + "\n"
}

/// A real run loop rather than a sleep: key transitions arrive as events, and a
/// blocked main thread never receives them (same reasoning as design-panel-key).
func settle(_ seconds: TimeInterval = 0.5) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

/// A panel rather than a window, for the reason design-panel-key measured:
/// macOS 14+ cooperative activation refuses `NSApp.activate()` from a CLI
/// process with no user interaction to point at, but `makeKey()` on an
/// `.accessory` app's `.nonactivatingPanel` takes key anyway (and moves
/// `NSApplication.isActive` to true). A plain `NSWindow` never becomes key here;
/// this probe's first version proved it by failing.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The escape-hatch arm: with this raised the window claims key status it
    /// does not hold, and `_windowChangedKeyState` is then invoked on each glass
    /// view so it re-reads the lie. If the flatten is applied in-process, this
    /// pins the live look; if it is compositor-side, the lie changes nothing and
    /// the capture proves that too.
    var pretendKey = false
    override var isKeyWindow: Bool { pretendKey || super.isKeyWindow }
}

// MARK: - Private-state access (the escape-hatch question)

func intGetter(_ obj: NSObject, _ name: String) -> Int? {
    let sel = NSSelectorFromString(name)
    guard obj.responds(to: sel) else { return nil }
    let imp = obj.method(for: sel)
    let fn = unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector) -> Int).self)
    return fn(obj, sel)
}

func intSetter(_ obj: NSObject, _ name: String, _ value: Int) -> Bool {
    let sel = NSSelectorFromString(name)
    guard obj.responds(to: sel) else { return false }
    let imp = obj.method(for: sel)
    let fn = unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector, Int) -> Void).self)
    fn(obj, sel, value)
    return true
}

func stringGetter(_ obj: NSObject, _ name: String) -> String {
    let sel = NSSelectorFromString(name)
    guard obj.responds(to: sel) else { return "(missing)" }
    guard let value = obj.perform(sel)?.takeUnretainedValue() else { return "(nil)" }
    return String(describing: value)
}

@available(macOS 26.0, *)
func logGlassState(_ glass: NSGlassEffectView, plane: String, phase: String) {
    let keys = ["_subduedState", "_variant", "_scrimState", "_interactionState",
                "_contentLensing", "_adaptiveAppearance"]
    let values = keys.map { "\($0)=\(intGetter(glass, $0).map(String.init) ?? "?")" }
    let reduced = glass.value(forKey: "_tintOpacityReduced") ?? "?"
    log("state \(phase) \(plane): \(values.joined(separator: " ")) _tintOpacityReduced=\(reduced)")
    log("state \(phase) \(plane): adaptation: \(stringGetter(glass, "_adaptationDebugDescription"))")
}

// MARK: - Geometry

let planeSize = NSSize(width: 320, height: 380)
let planeGap: CGFloat = 20
let margin: CGFloat = 20
let windowSize = NSSize(width: margin * 2 + planeSize.width * 3 + planeGap * 2,
                        height: planeSize.height + margin * 2)

// Plane-local rects (bottom-left origin). The wash covers the top half like a
// pane's well; the text sits on the wash; both measurement bands avoid the text.
let washRect = NSRect(x: 0, y: 180, width: 320, height: 200)
let textRect = NSRect(x: 16, y: 240, width: 288, height: 128)
let washedBand = NSRect(x: 12, y: 190, width: 296, height: 44)   // wash + glass, below the glyphs
let bareBand = NSRect(x: 12, y: 16, width: 296, height: 150)     // glass alone

// MARK: - Build the window

guard #available(macOS 26.0, *) else {
    print("FAIL: NSGlassEffectView needs macOS 26")
    exit(1)
}

let screen = NSScreen.screens[0]

// MARK: - The wallpaper underlay
//
// The subject is the owner's wallpaper, and it is not reachable directly: the
// desktop is covered edge to edge (this session: the orchestrator's fullscreen
// terminal at layer 0, plus sibling probes' windows), and a probe window ordered
// BELOW layer 0 gets no live glass sampling at all — measured before this was
// written: fully occluded, `occlusionState` not visible, `-l` returns a uniform
// `#141414` at every position, tracking nothing. Glass only samples a backdrop
// the window server actually composites.
//
// So the owner's actual wallpaper file (read off `NSWorkspace.desktopImageURL`,
// never a stand-in) is re-presented at desktop geometry — aspect-fill, the
// default "Fill Screen" scaling — by a probe-owned full-screen underlay ordered
// below the probe window, the same arrangement glass-backdrop's controlled
// backdrop uses. The glass samples the same pixels the desktop shows when it is
// visible; what differs from the true desktop is the absence of desktop icons.
// The README carries this caveat next to the wallpaper one.
guard let wallpaperURL = NSWorkspace.shared.desktopImageURL(for: screen),
      let wallpaperImage = NSImage(contentsOf: wallpaperURL) else {
    print("FAIL: could not read the desktop wallpaper image")
    exit(1)
}
let underlay = NSWindow(
    contentRect: screen.frame,
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
underlay.isOpaque = true
underlay.backgroundColor = .black
// Above .floating on purpose: sibling probes on this machine put their own
// windows at .floating, and one of them slid between this probe's KEY and
// INACTIVE captures and was photographed instead of the glass (measured: a flat
// #b7b7b7 slab where the pair's other half was wallpaper). The underlay and the
// probe sit two and three levels above, and every capture verifies the rect has
// no occluder from another process.
underlay.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
underlay.isReleasedWhenClosed = false
underlay.hidesOnDeactivate = false
let underlayContent = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
underlayContent.wantsLayer = true
underlayContent.layer?.contents = wallpaperImage
underlayContent.layer?.contentsGravity = .resizeAspectFill
underlay.contentView = underlayContent

let origin = NSPoint(x: screen.frame.midX - windowSize.width / 2,
                     y: screen.frame.midY - windowSize.height / 2)

let window = KeyablePanel(
    contentRect: NSRect(origin: origin, size: windowSize),
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
window.isOpaque = false
window.backgroundColor = .clear
window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 3)
window.isReleasedWhenClosed = false
window.hidesOnDeactivate = false
// The 26.2 regression (liquid-glass research §6.8, Apple forums 810314): glass in
// borderless non-movable transparent windows stops re-sampling. Same workaround
// as every glass-backdrop window.
window.isMovable = true

let content = NSView(frame: NSRect(origin: .zero, size: windowSize))
content.wantsLayer = true
window.contentView = content

let terminalText = """
~/Projects/baia % git status
On branch design-v6-native
nothing to commit, working tree clean
~/Projects/baia % make test
Test Suite 'All tests' passed
"""

struct PlaneSpec {
    let name: String
    let caption: String
    let style: NSGlassEffectView.Style
    let tint: NSColor?
}

let specs: [PlaneSpec] = [
    .init(name: "regular", caption: "[regular glass, no tint]", style: .regular, tint: nil),
    .init(name: "clear", caption: "[clear glass, no tint]", style: .clear, tint: nil),
    .init(name: "regular-tinted", caption: "[regular glass, neutral tint]", style: .regular,
          tint: NSColor(srgbRed: 18 / 255, green: 20 / 255, blue: 24 / 255, alpha: 0.5)),
]

var glassViews: [NSGlassEffectView] = []
for (i, spec) in specs.enumerated() {
    let planeOrigin = NSPoint(x: margin + CGFloat(i) * (planeSize.width + planeGap), y: margin)
    let plane = NSView(frame: NSRect(origin: planeOrigin, size: planeSize))
    plane.wantsLayer = true

    // The plane behind the pane: glass at the bottom of the sibling stack, the
    // pane's own layers above it — the constraint-6 arrangement, not contentView.
    let glass = NSGlassEffectView(frame: plane.bounds)
    glass.cornerRadius = 10
    glass.style = spec.style
    if let tint = spec.tint { glass.tintColor = tint }
    plane.addSubview(glass)
    glassViews.append(glass)

    let wash = NSView(frame: washRect)
    wash.wantsLayer = true
    wash.layer?.backgroundColor = NSColor(srgbRed: 18 / 255, green: 20 / 255, blue: 24 / 255,
                                          alpha: 0.42).cgColor
    plane.addSubview(wash)

    let label = NSTextField(wrappingLabelWithString: spec.caption + "\n" + terminalText)
    label.frame = textRect
    label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    label.textColor = NSColor(srgbRed: 187 / 255, green: 187 / 255, blue: 187 / 255, alpha: 1)
    label.backgroundColor = .clear
    label.isSelectable = false
    plane.addSubview(label)

    content.addSubview(plane)
}

// MARK: - Geometry manifest for analyze.py

func fractions(_ rect: NSRect, planeIndex: Int) -> [String: Double] {
    let planeOrigin = NSPoint(x: margin + CGFloat(planeIndex) * (planeSize.width + planeGap), y: margin)
    let inWindow = rect.offsetBy(dx: planeOrigin.x, dy: planeOrigin.y)
    // Image coordinates are top-left origin; AppKit's are bottom-left.
    return [
        "x0": inWindow.minX / windowSize.width,
        "x1": inWindow.maxX / windowSize.width,
        "y0": (windowSize.height - inWindow.maxY) / windowSize.height,
        "y1": (windowSize.height - inWindow.minY) / windowSize.height,
    ]
}

var manifest: [String: Any] = ["width_pt": windowSize.width, "height_pt": windowSize.height]
var planesJSON: [[String: Any]] = []
for (i, spec) in specs.enumerated() {
    planesJSON.append([
        "name": spec.name,
        "plane": fractions(NSRect(origin: .zero, size: planeSize), planeIndex: i),
        "washed": fractions(washedBand, planeIndex: i),
        "bare": fractions(bareBand, planeIndex: i),
    ])
}
manifest["planes"] = planesJSON
let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try manifestData.write(to: URL(fileURLWithPath: outDir + "/geometry.json"))

// MARK: - Capture plumbing

/// The window's frame as a screencapture -R rect (global top-left-origin points).
let frame = window.frame
let cgRect = "\(Int(frame.minX)),\(Int(screen.frame.height - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"

var runTainted = false

/// Any other process's window at or above the underlay's level overlapping the
/// capture rect means the capture photographed that window, not the glass. It
/// happened: a sibling probe's floating window slid over mid-run.
func occluders() -> [String] {
    guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]] else { return [] }
    let target = CGRect(x: frame.minX, y: screen.frame.height - frame.maxY,
                        width: frame.width, height: frame.height)
    var names: [String] = []
    for info in list {
        guard let layer = info[kCGWindowLayer as String] as? Int,
              // Below the Dock's level: the Dock (and NotchNook, and the menu
              // bar) own transparent full-screen windows above it that would
              // always "intersect" while covering nothing in the capture rect.
              layer >= underlay.level.rawValue, layer < Int(CGWindowLevelForKey(.dockWindow)),
              let pid = info[kCGWindowOwnerPID as String] as? Int32,
              pid != ProcessInfo.processInfo.processIdentifier,
              let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        let bounds = CGRect(x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                            width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0)
        if bounds.intersects(target) {
            names.append(info[kCGWindowOwnerName as String] as? String ?? "?")
        }
    }
    return names
}

func capture(_ name: String) {
    settle(0.4)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-R", cgRect, outDir + "/" + name]
    try? task.run()
    task.waitUntilExit()
    let over = occluders()
    if over.isEmpty {
        log("captured \(name) (rect \(cgRect), exit \(task.terminationStatus))")
    } else {
        runTainted = true
        log("captured \(name) TAINTED: occluded by \(over.joined(separator: ", ")) — rerun")
    }
}

func logAllGlass(_ phase: String) {
    for (i, spec) in specs.enumerated() { logGlassState(glassViews[i], plane: spec.name, phase: phase) }
}

// MARK: - The run

log("previous frontmost: \(previousFront?.localizedName ?? "none") (\(previousFront?.bundleIdentifier ?? "?"))")
log("wallpaper: \(wallpaperURL.path)")

// Phase 0: the underlay alone — the wallpaper as the glass will sample it.
underlay.orderFrontRegardless()
settle(0.8)
capture("backdrop-reference.png")

// Phase 1: on screen, never key. orderFrontRegardless takes no focus.
window.orderFrontRegardless()
settle(0.8)
logAllGlass("inactive-before")
capture("pair-INACTIVE-before-key.png")

// Phase 2: KEY. This is the focus steal, held only as long as one capture takes.
// `makeKey()` on the nonactivating panel is the route that works from a CLI
// process (see KeyablePanel); `NSApp.activate()` alone was measured refused.
window.makeKey()
settle(0.6)
if !window.isKeyWindow {
    app.activate()
    window.makeKeyAndOrderFront(nil)
    settle(0.6)
}
guard window.isKeyWindow else {
    log("FAIL: window never became key; no key capture is possible")
    try? stateLog.write(toFile: outDir + "/state-log.txt", atomically: true, encoding: .utf8)
    exit(1)
}
log("window is key; NSApp.isActive=\(app.isActive)")
logAllGlass("key")
capture("pair-KEY.png")
let keySubdued = intGetter(glassViews[0], "_subduedState")

// Phase 3: hand focus straight back to whoever had it.
if let prev = previousFront {
    app.yieldActivation(to: prev)
    prev.activate()
}
app.deactivate()
settle(0.8)
if window.isKeyWindow {
    // Deactivation alone can leave the panel key. Order a second probe-owned
    // panel key instead; the glass window resigns without hiding.
    log("deactivate left the panel key; resigning via a helper panel")
    let helper = KeyablePanel(
        contentRect: NSRect(x: screen.visibleFrame.minX + 4, y: screen.visibleFrame.minY + 4,
                            width: 8, height: 8),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    helper.isReleasedWhenClosed = false
    helper.backgroundColor = .clear
    helper.orderFrontRegardless()
    helper.makeKey()
    settle(0.6)
    if let prev = previousFront {
        app.yieldActivation(to: prev)
        prev.activate()
    }
    app.deactivate()
    settle(0.6)
}
log("after yield: isKeyWindow=\(window.isKeyWindow) NSApp.isActive=\(app.isActive) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
logAllGlass("inactive-after")
capture("pair-INACTIVE.png")
let inactiveSubdued = intGetter(glassViews[0], "_subduedState")

// Phase 4: the pretend-key escape hatch. The window lies about isKeyWindow while
// genuinely inactive, and each glass view is poked through the same hook AppKit
// uses on real key transitions.
window.pretendKey = true
for glass in glassViews {
    let sel = NSSelectorFromString("_windowChangedKeyState")
    if glass.responds(to: sel) {
        let imp = glass.method(for: sel)
        unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector) -> Void).self)(glass, sel)
    }
}
settle(0.6)
log("pretend-key raised; isKeyWindow now reads \(window.isKeyWindow) while NSApp.isActive=\(app.isActive)")
logAllGlass("pretend-key")
capture("override-pretend-key.png")
window.pretendKey = false

// Phase 5: the private-ivar escape hatch. If _subduedState tracked the key
// transition, force it back to the key-phase value while the window stays
// inactive, and capture what that buys.
if let keyValue = keySubdued, let inactiveValue = inactiveSubdued, keyValue != inactiveValue {
    log("override: _subduedState moved \(keyValue) -> \(inactiveValue) on resign; forcing back to \(keyValue) while inactive")
    for glass in glassViews { _ = intSetter(glass, "set_subduedState:", keyValue) }
    settle(0.6)
    logAllGlass("override")
    capture("override-subdued-while-inactive.png")
} else {
    log("override: _subduedState did not change across the key transition (key=\(keySubdued.map(String.init) ?? "?") inactive=\(inactiveSubdued.map(String.init) ?? "?")); no knob arm to run")
}

window.orderOut(nil)
underlay.orderOut(nil)
try? stateLog.write(toFile: outDir + "/state-log.txt", atomically: true, encoding: .utf8)
log("done; focus was returned to \(previousFront?.localizedName ?? "the previous app")")
if runTainted {
    log("FAIL: at least one capture was occluded by another process's window; the pair is not trustworthy")
    exit(1)
}
