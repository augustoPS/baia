#!/usr/bin/env swift
//
// Draws baia's app icon and writes an `.icns` per configuration.
//
//   swift Icon/make-icon.swift
//
// The mark is direction C, SEAM, from the 2026-07-25 design pass: one plank and
// the two spaces it makes. A *baia* is a stall, the compartment planks make in a
// stable so each animal gets its own space, which is the product in one word.
// An earlier attempt drew the pane tree literally and read as a bar chart; a
// diagram of a layout is not a mark, so this one is an object.
//
// Everything is drawn rather than rasterised from an SVG, for two reasons. No
// build step needs a converter that is not already on the machine, and every
// number below is the design's own, so the file is checkable against the
// handoff line by line rather than through an export nobody can diff.
//
// The coordinate space is y-down at 1024, matching how the geometry was
// specified. `flip` is what buys that, and removing it silently mirrors the
// whole mark vertically, which on a symmetric squircle looks fine and puts the
// glyph's cursor above its chevron instead of below.

import AppKit
import CoreGraphics
import Foundation

// MARK: - The design's constants

/// The canvas every number below is expressed in.
let canvas: CGFloat = 1024

/// The same lift off pure black the terminal uses. The icon is the app's
/// smallest self-portrait, so it starts from the surface the app is made of.
let field = CGColor(srgbRed: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255, alpha: 1)

/// `foreground.blended(with: background, fraction: 0.46)`. The planks, and the
/// prompt drawn in the empty stall.
let plank = CGColor(srgbRed: 0x6E / 255, green: 0x6E / 255, blue: 0x6E / 255, alpha: 1)

/// One rendered icon: a name (`Icon/<name>.icns`) and the accent that fills the
/// occupied stall. `focusedAccent`. One per icon, never two: the occupied stall
/// is the only thing here with a hue, which is the same rule the footer follows.
struct IconSpec {
    let name: String
    let occupied: CGColor
}

/// The squircle, transcribed. `r = 185.4` with a control offset of 74.16, which
/// is `k = 0.40` of the radius rather than the 0.5523 that approximates a
/// circle: the flatter shoulder is what makes it read as a macOS icon instead of
/// a rounded rectangle.
func squircle() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 285.4, y: 100))
    path.addLine(to: CGPoint(x: 738.6, y: 100))
    path.addCurve(
        to: CGPoint(x: 924, y: 285.4),
        control1: CGPoint(x: 812.76, y: 100),
        control2: CGPoint(x: 924, y: 211.24)
    )
    path.addLine(to: CGPoint(x: 924, y: 738.6))
    path.addCurve(
        to: CGPoint(x: 738.6, y: 924),
        control1: CGPoint(x: 924, y: 812.76),
        control2: CGPoint(x: 812.76, y: 924)
    )
    path.addLine(to: CGPoint(x: 285.4, y: 924))
    path.addCurve(
        to: CGPoint(x: 100, y: 738.6),
        control1: CGPoint(x: 211.24, y: 924),
        control2: CGPoint(x: 100, y: 812.76)
    )
    path.addLine(to: CGPoint(x: 100, y: 285.4))
    path.addCurve(
        to: CGPoint(x: 285.4, y: 100),
        control1: CGPoint(x: 100, y: 211.24),
        control2: CGPoint(x: 211.24, y: 100)
    )
    path.closeSubpath()
    return path
}

// MARK: - Drawing

/// Draws the mark into `ctx`, which is expected to be 1024 units square with y
/// running downwards.
///
/// - Parameter heavy: the small-size treatment. At 32 px and below the glyph is
///   thickened to 72 and its gap shrunk to 48, so the two shapes stay apart at a
///   size where a 56-unit stroke closes up into a smudge. The unit's right edge
///   and its ink baseline both hold, which is what stops the mark from shifting
///   between sizes; the chevron gives up the five units the thicker stroke needs.
/// - Parameter occupied: the accent for this icon's occupied stall.
func drawMark(in ctx: CGContext, heavy: Bool, occupied: CGColor) {
    ctx.saveGState()
    ctx.addPath(squircle())
    ctx.clip()

    ctx.setFillColor(field)
    ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))

    // The occupied stall, and the plank that makes it a stall rather than an
    // edge. Both run the full height of the art box and are cropped by the
    // clip, so the structure reads as continuing past the frame.
    ctx.setFillColor(occupied)
    ctx.fill(CGRect(x: 100, y: 100, width: 206, height: 824))

    ctx.setFillColor(plank)
    ctx.fill(CGRect(x: 306, y: 100, width: 44, height: 824))

    drawPrompt(in: ctx, heavy: heavy)
    ctx.restoreGState()
}

/// A drawn `>_` rather than set type, sitting a third of the way down.
///
/// No font travels with the export, and the spacing becomes a number that can be
/// tuned instead of whatever the face happened to ship. The gap is one stroke
/// weight plus a touch, which is why it holds at both ends of the size ramp: the
/// relationship is proportional to the drawing rather than to the canvas.
///
/// The upper third rather than the middle. A prompt sits at the top of a fresh
/// terminal, so centring the glyph made the mark read as a logo where this reads
/// as a session that has just started. It also leaves the largest empty area at
/// the bottom right, which is where the eye leaves the icon, so the mark exhales
/// rather than filling.
///
/// Both shapes share a stroke weight and an *ink* baseline at 483, which is what
/// makes them one unit rather than two marks. Mind the cap: a butt cap on a 45°
/// segment overshoots its endpoint by `w/2 × √½`, so the path ends at 463 and
/// the drawn edge lands at 483, exactly where the cursor's bottom is. The path
/// numbers are not the baseline, and aligning to them puts the chevron nearly
/// 20 units below the line.
///
/// The ghost plank from the design's base variant is deliberately absent. It is
/// a hint that more stalls sit off-frame, and it reads as a smudge behind the
/// glyph, which is why the handoff notes it comes out on any glyph variant.
func drawPrompt(in ctx: CGContext, heavy: Bool) {
    // Both variants are drawn rather than scaled from one. The heavy weight
    // closes the gap, and the chevron has to give ground for it without the
    // unit changing width, so the two sets of coordinates are not derivable
    // from each other.
    let weight: CGFloat = heavy ? 72 : 56
    let vertex = CGPoint(x: heavy ? 560 : 559, y: 375)
    let armX: CGFloat = heavy ? 477 : 471
    let armTopY: CGFloat = heavy ? 292 : 287
    let armBottomY: CGFloat = heavy ? 458 : 463
    let cursor = heavy
        ? CGRect(x: 608, y: 411, width: 216, height: 72)
        : CGRect(x: 623, y: 427, width: 200, height: 56)

    ctx.setStrokeColor(plank)
    ctx.setLineWidth(weight)
    ctx.setLineCap(.butt)
    ctx.setLineJoin(.miter)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: armX, y: armTopY))
    ctx.addLine(to: vertex)
    ctx.addLine(to: CGPoint(x: armX, y: armBottomY))
    ctx.strokePath()

    ctx.setFillColor(plank)
    ctx.fill(cursor)
}

/// One PNG at `pixels` square.
func render(pixels: Int, occupied: CGColor) -> Data? {
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    let scale = CGFloat(pixels) / canvas
    ctx.scaleBy(x: scale, y: scale)
    // y-down, so every number above is the design's own.
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)

    drawMark(in: ctx, heavy: pixels <= 32, occupied: occupied)

    guard let image = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: pixels, height: pixels)
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Writing the iconset

let root = URL(filePath: FileManager.default.currentDirectoryPath)

/// Every slice `iconutil` expects. The `@2x` entries are genuinely re-rendered
/// rather than upscaled, which is the point of drawing them: the 16 pt slice at
/// 32 px gets the heavy treatment and the 32 pt slice at 64 px does not, so each
/// one is drawn for the size it is actually seen at.
let slices: [(point: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

/// Renders every slice for `spec` and converts them into `Icon/<spec.name>.icns`.
/// The iconset is an intermediate; leaving it behind would put eleven files in
/// the repo that are all derivable from this one.
func writeIcon(_ spec: IconSpec) throws {
    let iconset = root.appending(path: "Icon/\(spec.name).iconset")

    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    for slice in slices {
        let pixels = slice.point * slice.scale
        guard let data = render(pixels: pixels, occupied: spec.occupied) else {
            FileHandle.standardError.write(Data("failed to render \(pixels)px\n".utf8))
            exit(1)
        }
        let suffix = slice.scale == 2 ? "@2x" : ""
        let name = "icon_\(slice.point)x\(slice.point)\(suffix).png"
        try data.write(to: iconset.appending(path: name))
    }

    let iconutil = Process()
    iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
    iconutil.arguments = [
        "--convert", "icns",
        "--output", root.appending(path: "Icon/\(spec.name).icns").path(percentEncoded: false),
        iconset.path(percentEncoded: false),
    ]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        FileHandle.standardError.write(Data("iconutil failed\n".utf8))
        exit(1)
    }

    try? FileManager.default.removeItem(at: iconset)
    print("wrote Icon/\(spec.name).icns")
}

let specs: [IconSpec] = [
    IconSpec(name: "baia", occupied: CGColor(srgbRed: 0xB5 / 255, green: 0xD5 / 255, blue: 0xFF / 255, alpha: 1)),
    // Midnight purple, a starting point rather than a finding: change this one
    // constant if it reads badly at 32 pt in the Dock.
    IconSpec(name: "baia-dev", occupied: CGColor(srgbRed: 0x6B / 255, green: 0x3F / 255, blue: 0xA0 / 255, alpha: 1)),
]

for spec in specs {
    try writeIcon(spec)
}
