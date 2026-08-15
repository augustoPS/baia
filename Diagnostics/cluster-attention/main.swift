// Probe for the capsule's attention levels: does the pill draw a different mark
// for `asking`, `acknowledged` and `done`, and is the mark legible on the fill
// it sits on?
//
// The defect this exists for is not a wrong colour. It is a view ignoring a
// value it is handed: `PaneClusterView` drew one 6 pt oval in one colour for all
// three levels, while `PaneStatus.Attention` resolved four cases that nothing on
// the capsule read. Spec:
// `vault/projects/baia/specs/2026-08-15-what-the-capsule-says-about-attention.md`.
//
// Three arms, each with a `break` variant that damages the drawing rather than
// the resolution:
//
//   levels    the three drawn levels differ from each other in pixels
//   anchor    the attention segment's rect is the same at every level
//   ink       the glyph on the fill is `theme.ink(on: fill)`, which is the
//             measured legibility guarantee rather than a colour chosen here
//
// Why pixels rather than a unit test over the enum. The package tests already
// assert that `PaneStatus.Attention` resolves correctly, and every one of them
// passed for the whole time the capsule was ignoring the result. A test over the
// value cannot see a view that never reads it; only a rendered pixel can.
//
// `run.sh` compiles `Sources/PaneClusterView.swift` and
// `Sources/PaneOverlayView.swift` verbatim, so the pixels measured are the ones
// the app draws. No screenshots: every reading comes from a bitmap this process
// rasterizes through `cacheDisplay(in:to:)`, so no screen-recording grant is
// needed and no window is made key.

import AppKit
import BaiaSettings
import PaneChrome
import WorkspaceLayout

let scale = 2

struct Pixel: Hashable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8
}

struct Render {
    var pixels: [UInt8]
    var bytesPerRow: Int
    var width: Int
    var height: Int

    /// In the view's own points, top-left origin: `PaneOverlayView.isFlipped` is
    /// `true` and row 0 of the bitmap is also the top, so a point read here is
    /// the point the drawing code computed.
    func pixel(x: Int, y: Int) -> Pixel {
        let px = x * scale
        let py = y * scale
        let offset = py * bytesPerRow + px * 4
        guard offset + 3 < pixels.count else { return Pixel(red: 0, green: 0, blue: 0, alpha: 0) }
        return Pixel(
            red: pixels[offset], green: pixels[offset + 1],
            blue: pixels[offset + 2], alpha: pixels[offset + 3]
        )
    }
}

func rasterize(_ view: NSView) -> Render? {
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    // Retagged into sRGB before anything is read, for `attention-colour`'s
    // reason: the colours going in were built with `NSColor(srgbRed:)` and a
    // bitmap in a wider space reports different numbers than the theme holds.
    let sRGB = rep.colorSpace == .sRGB
        ? rep
        : (rep.converting(to: .sRGB, renderingIntent: .default) ?? rep)
    guard let data = sRGB.bitmapData else { return nil }
    return Render(
        pixels: Array(UnsafeBufferPointer(start: data, count: sRGB.bytesPerRow * sRGB.pixelsHigh)),
        bytesPerRow: sRGB.bytesPerRow,
        width: sRGB.pixelsWide,
        height: sRGB.pixelsHigh
    )
}

func matches(_ pixel: Pixel, _ target: RGB, tolerance: Int = 3) -> Bool {
    let t = (
        red: UInt8(max(0, min(255, Int((target.red * 255).rounded())))),
        green: UInt8(max(0, min(255, Int((target.green * 255).rounded())))),
        blue: UInt8(max(0, min(255, Int((target.blue * 255).rounded()))))
    )
    return abs(Int(pixel.red) - Int(t.red)) <= tolerance
        && abs(Int(pixel.green) - Int(t.green)) <= tolerance
        && abs(Int(pixel.blue) - Int(t.blue)) <= tolerance
}

var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ok    \(label)")
    } else {
        print("  FAIL  \(label)")
        failures += 1
    }
}

// MARK: - The fixture

/// A cluster view carrying one attention level, at the width the pill wants.
///
/// Built through `segments` and `theme`, the view's own inputs, rather than by
/// reaching past them: a fixture that set private state would prove the drawing
/// works when driven a way the app never drives it.
@MainActor func makeView(_ attention: PaneStatus.Attention, theme: PaneTheme = .darkPastel)
    -> PaneClusterView
{
    let view = PaneClusterView(frame: NSRect(x: 0, y: 0, width: 200, height: PaneClusterMetrics.height))
    view.theme = theme
    let status = PaneStatus(
        anchorName: "baia",
        anchorIsRepository: true,
        isPinned: false,
        workingDirectory: nil,
        git: nil,
        agent: PaneStatus.Agent(
            label: "claude",
            wantsAttention: attention == .asking || attention == .acknowledged,
            isAcknowledged: attention == .acknowledged,
            isBusy: false,
            hasFinishedUnseen: attention == .done
        )
    )
    view.segments = PaneClusterSegments.build(from: status)
    view.needsDisplay = true
    return view
}

/// Where the attention segment sits, from the view's own placement rather than
/// from arithmetic repeated here.
@MainActor func attentionRect(_ view: PaneClusterView) -> NSRect? {
    view.layoutSubtreeIfNeeded()
    return view.segmentRect(for: .attention)
}

// MARK: - levels

/// Do the three drawn levels differ from one another in pixels?
///
/// Asserted as a difference between renders rather than against a named colour,
/// which is what makes it survive a change of treatment: whatever the levels are
/// drawn as, `asking` may not render identically to `acknowledged`, and neither
/// may render identically to `done`. A test naming the fill would have to be
/// rewritten by the next design pass and would go on passing meanwhile.
///
/// The control renders all three at `.asking`, which is exactly what the shipped
/// view did before this work: one mark regardless of level.
@MainActor func levelsArm(breakIt: Bool) {
    print("=== the three levels draw differently ===")
    let levels: [PaneStatus.Attention] = [.asking, .acknowledged, .done]
    var renders: [PaneStatus.Attention: Render] = [:]
    for level in levels {
        let view = makeView(breakIt ? .asking : level)
        guard let render = rasterize(view) else {
            check(false, "\(level) rasterized")
            return
        }
        renders[level] = render
    }
    guard let rect = attentionRect(makeView(.asking)) else {
        check(false, "the attention segment is placed")
        return
    }

    /// Every pixel of the segment's own box, so the comparison cannot miss a
    /// difference by sampling one unlucky point.
    func differs(_ a: Render, _ b: Render) -> Bool {
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) where a.pixel(x: x, y: y) != b.pixel(x: x, y: y) {
                return true
            }
        }
        return false
    }

    check(differs(renders[.asking]!, renders[.acknowledged]!), "asking differs from acknowledged")
    check(differs(renders[.acknowledged]!, renders[.done]!), "acknowledged differs from done")
    check(differs(renders[.asking]!, renders[.done]!), "asking differs from done")
}

// MARK: - anchor

/// Is the attention segment's rect the same at every level?
///
/// The spec's criterion 2, and the half of the first ruling's geometry argument
/// that survived its reversal. `approvalAnchorRect()` anchors the approval
/// popover to this segment, so a width that varied by level would move a popover
/// as a side effect of an agent being seen. The mark may change; the box it
/// occupies may not.
///
/// The control widens the `done` segment's text, which is the cheapest way to
/// make a level's box differ and is exactly the mistake the criterion guards.
@MainActor func anchorArm(breakIt: Bool) {
    print("=== the anchor does not move between levels ===")
    var rects: [NSRect] = []
    for level in [PaneStatus.Attention.asking, .acknowledged, .done] {
        let view = makeView(level)
        if breakIt, level == .done {
            var segments = view.segments
            if let index = segments.firstIndex(where: { $0.role == .attention }) {
                segments[index] = PaneClusterSegment(role: .attention, text: "WIDER")
                view.segments = segments
            }
        }
        guard let rect = attentionRect(view) else {
            check(false, "\(level) places its attention segment")
            return
        }
        rects.append(rect)
    }
    check(rects[0] == rects[1], "asking and acknowledged occupy the same rect")
    check(rects[1] == rects[2], "acknowledged and done occupy the same rect")

    // And the anchor the popover reads agrees with the placement, rather than
    // being computed a second way that could drift from it.
    let view = makeView(.asking)
    view.layoutSubtreeIfNeeded()
    check(view.approvalAnchorRect() == attentionRect(view), "the popover anchor is that rect")
}

// MARK: - ink

/// Is the glyph drawn in `theme.ink(on: fill)`?
///
/// That function is the measured guarantee: `readable(_:on:minimumRatio:)` walks
/// toward the pale or dark end and returns the best it finds, so the glyph is
/// bounded against the fill it sits on for every theme in the catalog. A glyph
/// ink chosen at the call site would be a second derivation and could fall below
/// the floor on a theme nobody sampled, which is the failure `PaneTheme`'s own
/// doc warns about.
///
/// Read at the glyph's darkest point rather than by coverage: the fill occupies
/// most of the capsule, so a fraction would answer about the fill.
///
/// The control is a `sed` in `run.sh` rather than a flag on the view, following
/// `pane-resize`: a seam added to production for a probe to poke is a second way
/// the code can be wrong, and the damage belongs in the drawing. `run.sh`
/// rewrites the `ink(on:)` call to `theme.foreground`, an ink legible on the
/// *pane* and unbounded against this fill, which is the plausible wrong answer
/// rather than an absurd one.
@MainActor func inkArm(breakIt _: Bool) {
    print("=== the glyph is the ink the fill guarantees ===")
    let theme = PaneTheme.darkPastel
    let view = makeView(.asking, theme: theme)
    guard let render = rasterize(view), let rect = attentionRect(view) else {
        check(false, "the asking level rasterized")
        return
    }
    let fill = theme.attentionColour(view.attentionAccent, behavior: view.alertBehavior)
    let expected = theme.ink(on: fill)

    // The glyph's own pixels: those inside the capsule that are not the fill.
    // Collected rather than sampled at one point, for the reason
    // `footer-corners` gives: a single point can land on an antialiased edge and
    // answer about nothing.
    //
    // **Inset before reading, because the segment's box is not the capsule.**
    // The rect `segmentRect(for:)` returns spans the full pill height, and the
    // capsule is `capsuleHeight` concentric inside it with rounded ends, so the
    // corners of the box are pill rather than capsule. Read whole, the
    // commonest non-fill colour came back `barBackground` (#212121 on Dark
    // Pastel) and the arm failed against a drawing that was correct. Measured
    // rather than reasoned: the tally named the pill, and the pill is what the
    // inset removes.
    let capsuleTop = (rect.height - PaneChromeMetrics.capsuleHeight) / 2
    let interior = NSRect(
        x: rect.minX + PaneChromeMetrics.capsuleHeight / 2,
        y: rect.minY + capsuleTop + 1,
        width: rect.width - PaneChromeMetrics.capsuleHeight,
        height: PaneChromeMetrics.capsuleHeight - 2
    )
    var glyphPixels: [Pixel] = []
    for y in Int(interior.minY)..<Int(interior.maxY) {
        for x in Int(interior.minX)..<Int(interior.maxX) {
            let pixel = render.pixel(x: x, y: y)
            if !matches(pixel, fill, tolerance: 6) { glyphPixels.append(pixel) }
        }
    }
    check(!glyphPixels.isEmpty, "the capsule carries a glyph at all")

    // The glyph's *core*, not any single matching pixel. A `!` at 10 pt heavy
    // is a few solid pixels inside a wide skirt of antialiasing between the ink
    // and the fill, so most non-fill pixels are blends and `hits > 0` would pass
    // on one lucky blend. The commonest non-fill colour is the ink itself if the
    // glyph is drawn in it, which is a claim about the drawing rather than about
    // one pixel; asserted that way after `hits > 0` was found to be satisfiable
    // by noise.
    var tally: [Pixel: Int] = [:]
    for pixel in glyphPixels { tally[pixel, default: 0] += 1 }
    guard let commonest = tally.max(by: { $0.value < $1.value })?.key else {
        check(false, "the glyph has a commonest colour")
        return
    }
    check(
        matches(commonest, expected, tolerance: 12),
        "the glyph's commonest ink is ink(on: fill) \(expected.hexString), got "
            + String(format: "#%02x%02x%02x", commonest.red, commonest.green, commonest.blue)
    )
}

// MARK: - main

let arm = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let breakIt = CommandLine.arguments.contains("break")

MainActor.assumeIsolated {
    switch arm {
    case "levels": levelsArm(breakIt: breakIt)
    case "anchor": anchorArm(breakIt: breakIt)
    case "ink": inkArm(breakIt: breakIt)
    default:
        print("usage: clusterattentiontest <levels|anchor|ink> [break]")
        exit(2)
    }
}

func report() -> Never {
    print(failures == 0 ? "PASS" : "FAILED \(failures)")
    exit(failures == 0 ? 0 : 1)
}

report()
