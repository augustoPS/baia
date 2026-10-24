#!/usr/bin/env swift
// Draws both Obsidian angular-b app icons with native AppKit and iconutil.
// Run from the repository root: swift Icon/make-icon.swift
//
// The divider and lowered prompt retain the geometry approved on 2026-10-20.
// Baia comes from Kimbundu ribaia, a compartment made by dividers, as supplied
// by the owner. Release uses lavender on illuminated ink; Debug inverts them.

import AppKit
import CoreGraphics
import Foundation

let canvas: CGFloat = 1024

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255,
        alpha: alpha
    )
}

let ink = color(0x0F0D15)
let lavender = color(0xC2A0F0)

struct IconSpec {
    let name: String
    let development: Bool
}

/// Angular b with separately drawn 16px and 32px optical slices.
func render(pixels: Int, development: Bool) -> Data? {
    func points(_ values: [(CGFloat, CGFloat)]) -> [CGPoint] {
        values.map { CGPoint(x: $0.0, y: $0.1) }
    }
    let tile: CGRect
    let radius: CGFloat
    let outer: [CGPoint]
    let inner: [CGPoint]
    if pixels == 16 {
        tile = CGRect(x: 1.5, y: 1.5, width: 13, height: 13)
        radius = 2.9
        outer = points([(6,5),(7,5),(7,8),(10,9.65),(10,10.35),(7,12),(6,12)])
        inner = points([(7,9),(7,11),(9,10)])
    } else if pixels == 32 {
        tile = CGRect(x: 3, y: 3, width: 26, height: 26)
        radius = 5.7
        outer = points([(12,10),(13.5,10),(13.5,17),(20,19.75),(20,20.75),(13.5,23.5),(12,23.5)])
        inner = points([(13.5,18.8),(13.5,21.7),(16.4,20.25)])
    } else {
        let scale = CGFloat(pixels) / canvas
        func convert(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (100 + p.x * 0.824) * scale, y: (100 + p.y * 0.824) * scale)
        }
        tile = CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
        radius = 181 * scale
        outer = points([(360,260),(404,260),(404,540),(644,642),(644,678),(404,780),(360,780)]).map(convert)
        inner = points([(404,600),(404,720),(524,660)]).map(convert)
    }
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: 1, y: -1)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.setFillColor(development ? lavender : ink)
    ctx.fill(tile)
    // A broad, low-energy light from the upper left. Keep optical slices flat.
    if !development, pixels > 32 {
        let light = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [lavender.copy(alpha: 0.10)!, lavender.copy(alpha: 0)!] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawRadialGradient(
            light,
            startCenter: CGPoint(x: tile.minX, y: tile.minY), startRadius: 0,
            endCenter: CGPoint(x: tile.minX, y: tile.minY), endRadius: tile.width * 1.25,
            options: [.drawsAfterEndLocation]
        )
    }
    ctx.restoreGState()
    let mark = CGMutablePath()
    for contour in [outer, inner] {
        mark.move(to: contour[0])
        for point in contour.dropFirst() { mark.addLine(to: point) }
        mark.closeSubpath()
    }
    ctx.setFillColor(development ? ink : lavender)
    ctx.addPath(mark)
    ctx.drawPath(using: .eoFill)
    if !development, pixels > 32 {
        // Illuminate inside the original silhouette, including its open counter.
        ctx.saveGState()
        ctx.addPath(mark)
        ctx.clip(using: .evenOdd)
        let highlight = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [color(0xEEEADF, alpha: 0.20), color(0xEEEADF, alpha: 0)] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawLinearGradient(
            highlight,
            start: CGPoint(x: tile.midX, y: tile.minY),
            end: CGPoint(x: tile.midX, y: tile.maxY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        ctx.restoreGState()
    }
    guard let image = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
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
        let rendered = render(pixels: pixels, development: spec.development)
        guard let data = rendered else {
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
    IconSpec(name: "baia", development: false),
    IconSpec(name: "baia-dev", development: true),
]

for spec in specs {
    try writeIcon(spec)
}
