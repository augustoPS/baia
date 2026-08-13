import AppKit
import BaiaSettings
import PaneChrome

// Do the pane capsule's draw wires carry, and does an undialled cluster group
// leave the rendering exactly where it was?
//
// `override-wires` is the pattern, applied to `PaneClusterView`: the package
// tests answer everything decidable without a view (`PaneClusterLayoutTests`,
// `PaneClusterSegmentsTests`: placement, widths, hit resolution, segment
// assembly), and what they cannot reach is the capsule's `draw(_:)` — the pill
// fill, the `chrome.cluster.opacity` multiplier, the focus step from
// `fillChrome` to `fillThick`, the window-active gate. This probe is that half.
//
// **No window server, no capture, no wallpaper.** Every arm renders the
// shipped `PaneClusterView`, compiled verbatim, into an offscreen
// `NSBitmapImageRep` through `cacheDisplay(in:to:)` and reads the bytes back.
// The focus gate matters here: on screen `isWindowActive` is fed by a real
// window's key state, but it is a plain stored property, so the offscreen
// render can hold it at either value and the conjunction in `framesForFocus`
// is measured directly.
//
// Every arm has a negative control, the same discipline `override-wires` runs
// under: `run.sh` inverts each control, so a control that stops failing fails
// the run as loudly as an arm that stops passing.

// MARK: - offscreen rendering

/// `view` rendered into a bitmap, as bytes. `override-wires`' own helper,
/// verbatim, and for its reasons: `cacheDisplay(in:to:)` runs the view's real
/// `draw(_:)` with no window in the path, and the rep comes from
/// `bitmapImageRepForCachingDisplay(in:)` so its format is AppKit's own.
func render(_ view: NSView, size: NSSize) -> NSBitmapImageRep {
    view.frame = NSRect(origin: .zero, size: size)
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        fatalError("no bitmap rep for \(type(of: view))")
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

/// Whether two renderings are the same bytes. Byte equality rather than a
/// tolerance, because the claim under test is "renders byte-identically", and
/// a tolerance would let a default pinned to the wrong constant pass.
func identical(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
    guard let left = a.representation(using: .png, properties: [:]),
          let right = b.representation(using: .png, properties: [:])
    else { fatalError("a rep would not encode") }
    return left == right
}

/// How many of the two renderings' pixels differ, which is what separates
/// "this knob moved something" from "this knob moved the thing it names".
func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
    var count = 0
    for y in 0 ..< a.pixelsHigh {
        for x in 0 ..< a.pixelsWide {
            if a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { count += 1 }
        }
    }
    return count
}

// MARK: - fixtures

/// The capsule wearing all four segments, so every drawing site is on the
/// canvas: text (place, changes, agent), the attention dot, and the fill and
/// stroke under them.
let segments: [PaneClusterSegment] = [
    PaneClusterSegment(role: .place, text: "main"),
    PaneClusterSegment(role: .changes, text: "↑1*?3"),
    PaneClusterSegment(role: .agent, text: "working"),
    PaneClusterSegment(role: .attention, text: ""),
]

/// A capsule in the state the pane feeds it. Defaults are the view's own
/// defaults, so a fixture built with no arguments is the untouched view plus
/// only the segments it needs to draw at all.
func makeCapsule(
    chrome: ResolvedChrome = .flat,
    focused: Bool = false,
    active: Bool = true
) -> PaneClusterView {
    let view = PaneClusterView(frame: .zero)
    view.segments = segments
    view.resolvedChrome = chrome
    view.isPaneFocused = focused
    view.isWindowActive = active
    return view
}

/// Rendered at the size the capsule solves for itself: the pill sizes itself
/// and the controller only pins its corner, so the honest canvas is the
/// intrinsic one.
func renderCapsule(_ view: PaneClusterView) -> NSBitmapImageRep {
    render(view, size: view.intrinsicContentSize)
}

/// The solved placement, recomputed here with the same font and the same
/// arithmetic the view uses, because the view's own cache is private. Used to
/// find single pixels (the dot's centre, a fill-only gap) rather than to
/// re-test the layout — `PaneClusterLayoutTests` owns that.
let placed: [PaneClusterLayout.Placed] = {
    let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    var widths: [PaneClusterSegmentRole: Double] = [:]
    for segment in segments {
        widths[segment.role] = segment.role == .attention
            ? PaneClusterMetrics.dotDiameter
            : Double(NSAttributedString(
                string: segment.text, attributes: [.font: font]
            ).size().width)
    }
    return PaneClusterLayout.solve(segments: segments, widths: widths)
}()

// MARK: - arms

/// The arms' shared state, on an enum for `override-wires`' reason: the whole
/// file compiles under the app target's own `-default-isolation MainActor`.
@MainActor enum State {
    static var failures: [String] = []
    static var broken = false
}

@MainActor func check(_ passed: Bool, _ what: String) {
    print("  \(passed ? "ok  " : "FAIL") \(what)")
    if !passed { State.failures.append(what) }
}

@MainActor var broken: Bool { State.broken }

/// The pixel at a point given in the view's own points, whatever scale the rep
/// rendered at.
func colour(at point: NSPoint, in rep: NSBitmapImageRep, size: NSSize) -> NSColor? {
    let scale = Double(rep.pixelsWide) / Double(size.width)
    return rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))
}

func armNilCluster() {
    print("== nil-cluster: an untouched capsule and one handed an explicitly-nil cluster group render the same bytes")
    // The untouched view is never assigned `fillOpacity` at all, so this
    // compares the property's *default* against what `ConfigurationCenter`
    // assigns from a `DesignOverrides()` whose cluster group has nothing
    // dialled. Of the group's two fields, `opacity` is the only one that
    // reaches this view: `cornerInset` moves constraints in
    // `TerminalPaneController`, not a byte here.
    //
    // **The group had a third field, `mode`, and this arm asserted its nil
    // resolution until 2026-08-13.** That check was added with the
    // 2026-08-12 default flip so the arm's framing — undialled means what
    // ships — could not drift from the package arithmetic behind it. The
    // dial has since retired outright, so the framing is now true by
    // construction: there is no mode to resolve, every pane wears the
    // capsule, and the baseline rendered below is the shipped chrome with
    // nothing left that could select another. The assertion is deleted
    // rather than re-pointed, because an arm that cannot fail is not
    // evidence.
    let overrides = DesignOverrides()

    for (name, chrome) in [("flat", ResolvedChrome.flat), ("glass", .glass(.dark))] {
        let untouched = makeCapsule(chrome: chrome)
        let applied = makeCapsule(chrome: chrome)
        applied.fillOpacity = broken ? 0.4 : overrides.chrome.cluster.opacity
        check(
            identical(renderCapsule(untouched), renderCapsule(applied)),
            "a nil cluster group leaves the \(name) capsule byte-identical"
        )
    }
}

func armOpacity() {
    print("== opacity: chrome.cluster.opacity reaches the pill fill, and only the fill")
    let size = makeCapsule().intrinsicContentSize

    for (name, chrome) in [("flat", ResolvedChrome.flat), ("glass", .glass(.dark))] {
        let shipped = renderCapsule(makeCapsule(chrome: chrome))
        let dialled = makeCapsule(chrome: chrome)
        dialled.fillOpacity = broken ? nil : 0.35
        let moved = renderCapsule(dialled)

        check(!identical(shipped, moved), "opacity 1 -> 0.35 changes the \(name) rendering")
        // The fill is the whole pill behind the ornaments, so a multiplier
        // that reached it moves a surface, not a hairline — the same
        // direction-of-the-knob bound `override-wires` puts under its ring.
        let count = differingPixels(shipped, moved)
        check(count > 200, "more than 200 pixels differ under \(name), so it is the fill and not an edge (\(count))")

        // And only the fill: the attention dot is painted opaque over it, so
        // its centre pixel carries the dot's own ink in both renderings. This
        // is the "fill only, the ornaments keep their inks" half of the
        // dial's contract, measured at the one ornament pixel whose coverage
        // is total. (Text edge pixels blend with the fill by antialiasing,
        // so the glyphs are asserted by the dial's doc rather than here.)
        guard let dot = placed.first(where: { $0.segment.role == .attention }) else {
            check(false, "the fixture has an attention dot")
            return
        }
        let centre = NSPoint(
            x: dot.x + PaneClusterMetrics.dotDiameter / 2,
            y: Double(size.height) / 2
        )
        check(
            colour(at: centre, in: shipped, size: size) == colour(at: centre, in: moved, size: size),
            "the dot's centre pixel keeps its ink under \(name): the dial faded the fill, not the facts"
        )
    }
}

func armFocus() {
    print("== focus: the fillThick step exists, and the window-active gate holds")
    let set = MaterialSet.dark
    let size = makeCapsule().intrinsicContentSize

    let focused = renderCapsule(makeCapsule(chrome: .glass(set), focused: true, active: true))
    let unfocused = renderCapsule(makeCapsule(
        chrome: .glass(set), focused: broken ? true : false, active: true
    ))

    check(!identical(focused, unfocused), "focused and unfocused render differently under glass")

    // At a fill-only pixel — vertically centred in the gap between the first
    // two segments, away from the inset stroke at the edges and from every
    // glyph — so the *fill* stepped from fillChrome to fillThick, rather than
    // the stroke alone accounting for the difference above.
    let gap = NSPoint(
        x: placed[0].x + placed[0].width + PaneClusterMetrics.segmentGap / 2,
        y: Double(size.height) / 2
    )
    check(
        colour(at: gap, in: focused, size: size) != colour(at: gap, in: unfocused, size: size),
        "a fill-only pixel moved: the step is the fill, not just the stroke"
    )

    // The footer's second half of the gate, `framesForFocus`: a focused pane
    // in a deactivated window renders what an unfocused pane renders, byte
    // for byte. `isWindowActive` is a plain property here, so the offscreen
    // render measures the conjunction directly.
    let inactive = renderCapsule(makeCapsule(
        chrome: .glass(set), focused: true, active: broken ? true : false
    ))
    check(
        identical(unfocused, inactive),
        "focused-but-deactivated renders what unfocused renders: the window-active gate holds"
    )
}

// MARK: - main

@main
enum Probe {
    @MainActor static func main() {
        // Accessory, and nothing is ever ordered front: this probe opens no
        // window at all. The policy is set anyway so the process does not
        // appear in the Dock for the second it runs.
        NSApplication.shared.setActivationPolicy(.accessory)

        let arms: [String: @MainActor () -> Void] = [
            "nil-cluster": armNilCluster,
            "opacity": armOpacity,
            "focus": armFocus,
        ]

        State.broken = CommandLine.arguments.contains("break")

        guard let name = CommandLine.arguments.dropFirst().first, let arm = arms[name] else {
            print("usage: clustertest <\(arms.keys.sorted().joined(separator: "|"))> [break]")
            exit(2)
        }

        if State.broken { print("(negative control: the thing under test is damaged)") }
        arm()

        if State.failures.isEmpty {
            print("PASS")
            exit(0)
        }
        print("FAIL")
        exit(1)
    }
}
