import AppKit
import PaneChrome

// Plan 5's accessory-controller probe: a hand-managed footer beside an
// `NSSplitViewItemAccessoryViewController` footer, with
// `preferredScrollEdgeEffectStyle` enumerated as arms. The README carries the
// question and the arm table; this file carries the arrangement.
//
// This binary never becomes key and never activates. `.accessory` activation
// policy plus `orderFrontRegardless()` is the `SAFE_PROBES` standard
// (`glass-backdrop`, `pane-resize`, `theme-refresh`), and the same reasoning
// applies: a focus steal mid-capture would land keystrokes in whatever the
// owner was typing into.
//
// The content scrolls. That is not decoration: the scroll edge effect is a
// function of content passing under the bar, so a static capture of an
// unscrolled document photographs the one state where the effect has nothing
// to do. Captures are taken mid-document, and the live phase runs the scroll
// down, back to the very top (where the effect should disengage), and back to
// the middle, so the owner sees the transition and not only the steady state.

// MARK: - shared drawing

let barHeight = CGFloat(PaneChromeMetrics.paneBarHeight)

let themeBackground = NSColor(srgbRed: 18.0 / 255, green: 20.0 / 255, blue: 24.0 / 255, alpha: 1)

func nsColor(_ rgba: RGBA) -> NSColor {
    NSColor(
        srgbRed: rgba.rgb.red,
        green: rgba.rgb.green,
        blue: rgba.rgb.blue,
        alpha: rgba.alpha
    )
}

/// The bar's segments, drawn the way `PaneStatusBarView` grouped them until it
/// was deleted on 2026-08-13: the repository group, the agent, the working
/// directory, each gap read off `PaneChromeMetrics` rather than transcribed.
/// The baseline is that view's `baselineFromTop`, converted for an unflipped
/// view.
///
/// Reading the package rather than transcribing it is why this probe outlived
/// the view. `PaneChromeMetrics` keeps the bar's geometry as a measured record
/// (its `paneBarHeight` still derives the live `glassWindowPaddingBump`), so
/// the reconstruction below is still the real numbers rather than a guess at
/// what they were.
///
/// What is deliberately not reproduced: the PIN, the capsule, the focus frame
/// and the attention line. Every arm draws the same segments, so anything
/// elided is elided from all four equally and cannot enter the comparison.
func drawSegments(in bounds: NSRect) {
    let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    let ink: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(white: 0.82, alpha: 1),
    ]
    let dimInk: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(white: 0.55, alpha: 1),
    ]
    // `baselineFromTop` is measured down from the bar's top edge; `draw(at:)`
    // in an unflipped view takes the glyph origin up from the bottom, and the
    // origin sits `font.descender` below the baseline.
    let y = bounds.height - CGFloat(PaneChromeMetrics.paneBarBaselineFromTop) + font.descender

    var x = CGFloat(PaneChromeMetrics.paneBarHorizontalInset)
    let groups: [(String, [NSAttributedString.Key: Any])] = [
        ("baia", ink),
        ("main \u{2191}1*?3", ink),
        ("claude", ink),
        ("~/Projects/baia", dimInk),
    ]
    for (index, group) in groups.enumerated() {
        let text = group.0 as NSString
        text.draw(at: NSPoint(x: x, y: y), withAttributes: group.1)
        x += text.size(withAttributes: group.1).width
        if index < groups.count - 1 {
            x += CGFloat(PaneChromeMetrics.paneBarSpacingBetweenGroups)
        }
    }
}

/// The 22 pt bar, in both constructions.
///
/// `drawsFill: true` is the hand-managed control: the base layer baia shipped
/// (`MaterialSet.dark.fillChrome`, the unfocused value — `fillThick` steps on
/// focus and no arm here is focused) plus the hairline on the outer edge.
///
/// `drawsFill: false` is the accessory arms: segments only, because the
/// research's adoption note says custom backgrounds under system bars "might
/// overlay or interfere with Liquid Glass or other effects that the system
/// provides". An accessory arm that kept the fill would measure the
/// interference, not the offer.
final class BarContentView: NSView {
    let drawsFill: Bool

    init(drawsFill: Bool) {
        self.drawsFill = drawsFill
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func draw(_: NSRect) {
        if drawsFill {
            nsColor(MaterialSet.dark.fillChrome).setFill()
            bounds.fill()
            // The separator on the outer edge, away from the terminal. The bar
            // sits at the window's bottom and this view is unflipped, so the
            // outer edge is y = 0.
            NSColor(white: 0, alpha: 0.4).setFill()
            NSRect(
                x: 0, y: 0,
                width: bounds.width,
                height: CGFloat(PaneChromeMetrics.paneBarHairlineHeight)
            ).fill()
        }
        drawSegments(in: bounds)
    }
}

/// The scrolled document: the theme background at full opacity under monospaced
/// rows at the terminal's scale, rows drawn to the very bottom so the bar
/// genuinely overlaps live-looking content. Full opacity rather than
/// `glass-backdrop`'s 0.42 well, because this probe's question is the bar over
/// its own content, not the desktop through the window; an opaque document
/// removes the wallpaper as a variable the same way that probe's backdrop
/// window did.
final class DocumentView: NSView {
    static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

    static let rowStep = font.boundingRectForFont.height + 3

    /// A whole number of rows, so the document's last row ends exactly at its
    /// bottom edge. With a fractional row there, the resting position at the
    /// end of the scroll left that row's tail under the bar, and the
    /// disengaged-state capture showed a bar with content under it while
    /// claiming there was none.
    static func height(rows: Int) -> CGFloat {
        (8 + rowStep * CGFloat(rows)).rounded(.up)
    }

    override var isFlipped: Bool { true }

    override func draw(_: NSRect) {
        themeBackground.setFill()
        bounds.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: NSColor(white: 0.86, alpha: 1),
        ]
        var y: CGFloat = 8
        var row = 0
        while y + Self.rowStep <= bounds.height {
            let line = row % 3 == 0
                ? "$ git status --porcelain=v2 --branch  # row \(row)"
                : "  MM Sources/PaneClusterView.swift             \(row)"
            line.draw(at: NSPoint(x: 8, y: y), withAttributes: attributes)
            y += Self.rowStep
            row += 1
        }
    }
}

// MARK: - the arms

enum Arm: String, CaseIterable {
    /// The control: the construction baia shipped until 2026-08-13. A custom view with the
    /// `fillChrome` fill overlaid on the scroll view, content sliding under
    /// it, and no way to receive the scroll edge effect (DTS, forums 815816).
    case handManaged = "1-hand-managed"

    /// The accessory footer with the style left alone. This is what 26.0
    /// gives: the effect is automatic-only there (FB19629432).
    case accessoryAutomatic = "2-accessory-automatic"

    /// `preferredScrollEdgeEffectStyle = .soft`, 26.1+.
    case accessorySoft = "3-accessory-soft"

    /// `preferredScrollEdgeEffectStyle = .hard`, 26.1+.
    case accessoryHard = "4-accessory-hard"

    var usesAccessory: Bool { self != .handManaged }
}

final class ProbeWindow: NSWindow {
    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }
}

func makeScroll(frame: NSRect) -> NSScrollView {
    let scroll = NSScrollView(frame: frame)
    scroll.autoresizingMask = [.width, .height]
    scroll.drawsBackground = true
    scroll.backgroundColor = themeBackground
    // The safe-area path: the accessory insets the content safe area, and the
    // scroll view has to honor it for content to slide under the bar rather
    // than stop above it.
    scroll.automaticallyAdjustsContentInsets = true
    let document = DocumentView(
        frame: NSRect(x: 0, y: 0, width: frame.width, height: DocumentView.height(rows: 115))
    )
    document.autoresizingMask = [.width]
    scroll.documentView = document
    return scroll
}

/// Builds one arm's window and returns it with its scroll view, which the
/// timeline below drives.
func makeWindow(arm: Arm, frame: NSRect) -> (ProbeWindow, NSScrollView) {
    let window = ProbeWindow(
        contentRect: frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isOpaque = true
    window.hasShadow = false
    window.ignoresMouseEvents = true

    let scroll: NSScrollView
    if arm.usesAccessory {
        let holder = NSView(frame: NSRect(origin: .zero, size: frame.size))
        scroll = makeScroll(frame: holder.bounds)
        holder.addSubview(scroll)

        let contentController = NSViewController()
        contentController.view = holder

        let split = NSSplitViewController()
        let item = NSSplitViewItem(viewController: contentController)
        split.addSplitViewItem(item)

        let accessory = NSSplitViewItemAccessoryViewController()
        accessory.view = BarContentView(drawsFill: false)
        // Explicit, not assumed: the inset is what gives the scroll view a
        // resting position with the last rows above the bar, and the
        // disengaged-state capture depends on it existing. The run prints the
        // clip view's actual insets per arm so the assumption is checked
        // rather than carried.
        accessory.automaticallyAppliesContentInsets = true
        item.addBottomAlignedAccessoryViewController(accessory)

        // The one knob under test. On a pre-26.1 system the arm still runs,
        // but says so: a capture from such a machine must not be mistaken for
        // a styled arm.
        if #available(macOS 26.1, *) {
            switch arm {
            case .accessorySoft: accessory.preferredScrollEdgeEffectStyle = .soft
            case .accessoryHard: accessory.preferredScrollEdgeEffectStyle = .hard
            case .accessoryAutomatic, .handManaged: break
            }
        } else if arm != .accessoryAutomatic {
            print("NOTE \(arm.rawValue): preferredScrollEdgeEffectStyle needs 26.1+; arm ran unstyled")
        }

        // `contentViewController` resizes the window to the controller's
        // preferred size, so the frame is reasserted after.
        window.contentViewController = split
        window.setFrame(frame, display: true)
    } else {
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        scroll = makeScroll(frame: container.bounds)
        container.addSubview(scroll)

        let bar = BarContentView(drawsFill: true)
        bar.frame = NSRect(x: 0, y: 0, width: frame.width, height: barHeight)
        bar.autoresizingMask = [.width, .maxYMargin]
        container.addSubview(bar)
        window.contentView = container
    }

    // The arm's name, pinned to the window's top-left, above the scrolled
    // content and outside the bar it grades.
    if let content = window.contentView {
        let label = NSTextField(labelWithString: arm.rawValue)
        label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = NSColor(white: 1, alpha: 0.8)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 8, y: content.bounds.height - label.frame.height - 6)
        label.autoresizingMask = [.minYMargin]
        content.addSubview(label)
    }

    return (window, scroll)
}

// MARK: - scroll driving

/// The clip origin for a fraction of the scrollable range. The document is
/// flipped, so y grows downward and 0 is the very top.
///
/// The bottom content inset is part of the range. The accessory insets the
/// safe area, the clip view turns that into `contentInsets.bottom`, and the
/// scrollable range grows by exactly that much: the resting position at
/// fraction 1 has the last rows sitting *above* the bar. The first version of
/// this function stopped at `document - visible` and photographed rows still
/// passing under the bar at what it called the end.
func offset(_ scroll: NSScrollView, fraction: CGFloat) -> NSPoint {
    let clip = scroll.contentView
    let document = scroll.documentView?.frame.height ?? 0
    let range = max(0, document - clip.bounds.height + clip.contentInsets.bottom)
    return NSPoint(x: 0, y: range * fraction)
}

func jump(_ scroll: NSScrollView, to fraction: CGFloat) {
    scroll.contentView.setBoundsOrigin(offset(scroll, fraction: fraction))
    scroll.reflectScrolledClipView(scroll.contentView)
}

func glide(_ scroll: NSScrollView, to fraction: CGFloat, over duration: TimeInterval) {
    NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        scroll.contentView.animator().setBoundsOrigin(offset(scroll, fraction: fraction))
    }
}

// MARK: - capture

/// `screencapture -l` (the window's own backing store) plus `-R` beside it as
/// the composite cross-check. The full reasoning, including why `-R`'s absolute
/// values are not graded, is in `glass-backdrop/backdroptest.swift`'s capture
/// section; these windows are opaque, so the well-alpha trap documented there
/// cannot recur here, and the pair is kept for the ordering cross-check alone.
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

/// Runs the run loop for a fixed interval without blocking the window server —
/// `Thread.sleep` would stop the run loop, and both the animator glides above
/// and the edge effect's own compositing need display passes to happen.
func settle(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

// MARK: - main

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSTemporaryDirectory() + "baia-footer-accessory"

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

// Four windows in a 2x2 grid, centred, so all four bars are on screen at once
// and the owner's eye moves between them without a capture in the way.
let armWidth: CGFloat = 460
let armHeight: CGFloat = 300
let gap: CGFloat = 24
let screenFrame = screen.frame
let gridWidth = armWidth * 2 + gap
let gridHeight = armHeight * 2 + gap
let gridOrigin = NSPoint(
    x: screenFrame.midX - gridWidth / 2,
    y: screenFrame.midY - gridHeight / 2
)

var windows: [(arm: Arm, window: ProbeWindow, scroll: NSScrollView)] = []
for (index, arm) in Arm.allCases.enumerated() {
    let column = CGFloat(index % 2)
    let row = CGFloat(index / 2)
    let frame = NSRect(
        x: gridOrigin.x + column * (armWidth + gap),
        // Row 0 on top, which for a bottom-left origin means the higher y.
        y: gridOrigin.y + (1 - row) * (armHeight + gap),
        width: armWidth,
        height: armHeight
    )
    let (window, scroll) = makeWindow(arm: arm, frame: frame)
    window.orderFrontRegardless()
    windows.append((arm, window, scroll))
}

settle(0.8)

// The inset assumption, checked. A bottom inset of zero would mean the
// accessory is not participating in the safe area and the "-end" captures
// photograph an engaged state while claiming a disengaged one.
for entry in windows {
    let insets = entry.scroll.contentView.contentInsets
    print("\(entry.arm.rawValue): clip contentInsets bottom = \(insets.bottom)")
}

// Mid-document before any capture: the state where content is genuinely under
// every bar and the edge effect, where one exists, has something to do.
for entry in windows {
    jump(entry.scroll, to: 0.5)
}
settle(1.2)

var failures = 0
for entry in windows {
    let path = outputDirectory + "/" + entry.arm.rawValue + ".png"
    if capture(window: entry.window, to: path) {
        print("captured \(entry.arm.rawValue).png")
    } else {
        print("CAPTURE FAILED \(entry.arm.rawValue)")
        failures += 1
    }
}

// The same four bars at the document's end. For a bottom-aligned bar that is
// the disengaged state: `automaticallyAppliesContentInsets` gives the scroll
// view a bottom inset of the bar's height, so at maximum scroll the last rows
// rest above the bar and nothing passes under it. Disengaging there is the
// effect's defining behavior — it is what a hand-managed bar cannot do at all
// — so the record needs it as a file, not only as a moment in the live phase.
// (The document's top is not this state: a 2400 pt document in a 300 pt
// viewport has mid-document rows under the bar at scroll position zero, which
// the first version of this capture learned by photographing it.)
for entry in windows {
    jump(entry.scroll, to: 1.0)
}
settle(1.2)
for entry in windows {
    let path = outputDirectory + "/" + entry.arm.rawValue + "-end.png"
    if capture(window: entry.window, to: path) {
        print("captured \(entry.arm.rawValue)-end.png")
    } else {
        print("CAPTURE FAILED \(entry.arm.rawValue)-end")
        failures += 1
    }
}
for entry in windows {
    jump(entry.scroll, to: 0.5)
}
settle(0.5)

// The live phase: to the very end (where the effect disengages with nothing
// left under the bar), back to the top, then to the middle. The glides run
// concurrently across all four windows because `settle` pumps the one run loop
// they all animate on.
print("live look: scrolling for ~14s, windows close on their own")
for entry in windows { glide(entry.scroll, to: 1.0, over: 4) }
settle(4.5)
for entry in windows { glide(entry.scroll, to: 0, over: 4) }
settle(4.5)
for entry in windows { glide(entry.scroll, to: 0.5, over: 3) }
settle(4.0)

for entry in windows {
    entry.window.orderOut(nil)
}

print("")
print("output: \(outputDirectory)")
if failures > 0 {
    print("FAILED \(failures) capture(s)")
    exit(1)
}
print("PASS all captures written")
exit(0)
