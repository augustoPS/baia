// Probe for the footer's rounded bottom corners.
//
// Six questions, one arm each, and a `break` variant of every arm that damages
// the thing under test and expects the check to catch it. A check that has never
// failed proves nothing.
//
//   radius      the constant `WindowCorner.radius` still is the window's radius
//   match       the footer's drawn corner is the window's corner
//   concentric  the focus frame stays 1 pt inside that corner all the way round
//   height      rounding a corner moved neither the bar's height nor its text
//   clip        the bar a real `PaneStatusBarView` renders has that corner in it
//   fullscreen  a full-screen window is square, and the shipped test says so
//
// Nothing here is part of the app build. `run.sh` compiles `Sources/WindowCorner.swift`
// and `Sources/PaneStatusBarView.swift` verbatim, so the shapes measured are the
// ones that ship rather than a copy that has drifted.
//
// No screenshots. Every reading is taken from geometry AppKit hands over or from
// a bitmap this process rasterizes itself.

import AppKit
import BaiaSettings
import ObjectiveC.runtime
import PaneChrome
import QuartzCore
import SwiftUI
import WorkspaceLayout

// MARK: - Private introspection
//
// `_cornerRadius` and `_getCachedWindowCornerPath` are private AppKit. They are
// used HERE ONLY, to make the shipped constant checkable: there is no public API
// that reports a window's corner radius, so the alternative to reading it is
// believing it. None of this may appear in `Sources/`.

func msgDouble(_ object: AnyObject, _ name: String) -> CGFloat? {
    let selector = NSSelectorFromString(name)
    guard object.responds(to: selector),
          let method = class_getInstanceMethod(object_getClass(object), selector),
          let encoding = method_getTypeEncoding(method),
          String(cString: encoding).hasPrefix("d")
    else { return nil }
    let implementation = unsafeBitCast(
        method_getImplementation(method),
        to: (@convention(c) (AnyObject, Selector) -> CGFloat).self
    )
    return implementation(object, selector)
}

func msgPath(_ object: AnyObject, _ name: String) -> CGPath? {
    let selector = NSSelectorFromString(name)
    guard object.responds(to: selector),
          let method = class_getInstanceMethod(object_getClass(object), selector)
    else { return nil }
    let implementation = unsafeBitCast(
        method_getImplementation(method),
        to: (@convention(c) (AnyObject, Selector) -> CGPath?).self
    )
    return implementation(object, selector)
}

// MARK: - Rasterizing and measuring

/// Points per pixel. Two, because that is what the owner's display is and what
/// the phase-one measurement was taken at. The readings are in points either way.
let scale: CGFloat = 2

/// A square patch of alpha, row 0 at the bottom, in a `side`-pixel buffer.
///
/// - Parameter at: pixels per point. Defaults to the probe's own 2x. The `clip`
///   arm passes whatever `cacheDisplay(in:to:)` gave it instead, so a rendered bar
///   and the reference it is compared against are profiled in the same units.
func raster(side: Int, at rasterScale: CGFloat = scale, _ draw: (CGContext) -> Void) -> [Double] {
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    pixels.withUnsafeMutableBytes { raw in
        let context = CGContext(
            data: raw.baseAddress,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setShouldAntialias(true)
        context.scaleBy(x: rasterScale, y: rasterScale)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        draw(context)
    }
    // Row 0 is the bottom one here and everywhere below, which is the corner's
    // end of the patch. A `CGBitmapContext` stores its first row at the top while
    // drawing with the origin at the bottom, so reading it in memory order profiles
    // the far side of the patch and reports an inset of zero on every row.
    return (0 ..< side * side).map { index in
        let row = index / side
        let column = index % side
        return Double(pixels[((side - 1 - row) * side + column) * 4 + 3]) / 255
    }
}

/// How far in from the left edge the shape starts, per pixel row, in points.
///
/// The integral of the uncovered fraction rather than the first pixel over a
/// threshold. An alpha cutoff throws the antialiasing ramp away and reads a
/// squircle 0.6 pt short at the row nearest the corner, which is the mistake that
/// made the first measurement of this corner look like it was not a circle *or* a
/// squircle. Integrating keeps the ramp, and the answer is subpixel.
///
/// `nil` for a row the shape never reaches, so an empty row cannot read as an
/// inset of zero.
func insets(_ coverage: [Double], side: Int, rows: Int, at rasterScale: CGFloat = scale) -> [Double?] {
    (0 ..< rows).map { row in
        var accumulated = 0.0
        for column in 0 ..< side {
            let value = coverage[row * side + column]
            accumulated += 1 - value
            if value > 0.999 { return accumulated / Double(rasterScale) }
        }
        return nil
    }
}

/// Compares two edge profiles with a tolerance per direction.
///
/// Two directions rather than one because the two errors are not worth the same.
/// A shape that stops *short* of the window's outline leaves a sliver of window
/// with no footer painted on it, which is visible; one that runs *past* it is cut
/// off by the window's own mask and cannot be seen at all. So `inward` is held to
/// a hundredth of a point and `outward` is allowed the little that SwiftUI's
/// truncation of the corner costs.
func compare(
    _ measured: [Double?],
    _ reference: [Double?],
    label: String,
    inward: Double,
    outward: Double,
    at rasterScale: CGFloat = scale
) -> Bool {
    var worstInward = (delta: 0.0, row: 0)
    var worstOutward = (delta: 0.0, row: 0)
    var compared = 0
    for row in 0 ..< min(measured.count, reference.count) {
        guard let a = measured[row], let b = reference[row] else { continue }
        compared += 1
        // A larger inset is a shape that starts further from the edge, which is
        // the shape pulling inside the window's outline.
        if a - b > worstInward.delta { worstInward = (a - b, row) }
        if b - a > worstOutward.delta { worstOutward = (b - a, row) }
    }
    func at(_ row: Int) -> Double { (Double(row) + 0.5) / Double(rasterScale) }
    print(String(
        format: "  %@: %d rows compared",
        label, compared
    ))
    print(String(
        format: "    inside the window's outline by at most %.4f pt (at %.2f pt up), allowed %.4f",
        worstInward.delta, at(worstInward.row), inward
    ))
    print(String(
        format: "    outside it by at most %.4f pt (at %.2f pt up), allowed %.4f",
        worstOutward.delta, at(worstOutward.row), outward
    ))
    guard compared > 8 else {
        print("  FAIL \(label): only \(compared) rows had a reading, which is not a measurement")
        return false
    }
    guard worstInward.delta <= inward else {
        print("  FAIL \(label): it stops \(worstInward.delta) pt short of the window, which shows as a gap")
        return false
    }
    guard worstOutward.delta <= outward else {
        print("  FAIL \(label): it overhangs the window by \(worstOutward.delta) pt, so it is the wrong shape")
        return false
    }
    return true
}

/// Both profiles side by side, so a failure can be read rather than guessed at.
func table(_ columns: [(String, [Double?])], rows: Int, at rasterScale: CGFloat = scale) {
    print("  dy(pt)  " + columns.map { name in
        String(repeating: " ", count: max(1, 14 - name.0.count)) + name.0
    }.joined())
    for row in stride(from: 0, to: rows, by: 2) {
        var line = String(format: "  %6.2f  ", (Double(row) + 0.5) / Double(rasterScale))
        for column in columns {
            line += column.1[row].map { String(format: "%14.4f", $0) } ?? "             -"
        }
        print(line)
    }
}

// MARK: - Shapes

let patch = 120

/// The bottom-left corner of a window, as AppKit's own mask path.
func systemCorner(_ path: CGPath, at rasterScale: CGFloat = scale) -> [Double] {
    raster(side: patch, at: rasterScale) { context in
        context.addPath(path)
        context.fillPath()
    }
}

/// The bottom-left corner of the footer, drawn by the shipped code.
///
/// Flipped on the way in, because ``WindowCorner/path(in:corners:inset:)`` is
/// authored for the flipped view it is drawn in. Getting this wrong puts the
/// curve at the top and the comparison fails loudly rather than quietly.
func footerCorner(corners: BottomCorners, inset: Double, radiusOverride: Double? = nil) -> [Double] {
    let height = PaneStatusBarMetrics.height
    let width = 300.0
    return raster(side: patch) { context in
        context.saveGState()
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        let path: NSBezierPath
        if let radiusOverride {
            // The negative control: a circular arc of the same radius, which is
            // what `NSBezierPath(roundedRect:xRadius:yRadius:)` and
            // `CGPath(roundedRect:)` both draw.
            path = NSBezierPath(
                roundedRect: rect.insetBy(dx: inset, dy: inset),
                xRadius: radiusOverride - inset,
                yRadius: radiusOverride - inset
            )
        } else {
            path = WindowCorner.path(in: rect, corners: corners, inset: inset)
        }
        context.addPath(path.cgPath)
        context.fillPath()
        context.restoreGState()
    }
}

// MARK: - Arms

func probeWindow() -> (window: NSWindow, frame: NSView) {
    let window = NSWindow(
        contentRect: NSRect(x: 200, y: 200, width: 400, height: 300),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.makeKeyAndOrderFront(nil)
    return (window, window.contentView!.superview!)
}

/// Does the shipped constant still describe the window?
///
/// Three readings of the same corner, all of which have to agree with
/// `WindowCorner.radius`: the scalar AppKit stores, the length of the corner in
/// the mask path it builds, and that path's control points against the ones
/// SwiftUI produces for a continuous corner of that radius. The last is what
/// rejects a circle: an OS that kept the radius and changed the curve family
/// passes the first two.
func radiusArm(claimed: Double) -> Bool {
    var ok = true
    let (window, frame) = probeWindow()

    print("claimed radius (WindowCorner.radius) = \(claimed)")

    guard let stored = msgDouble(window, "_cornerRadius") else {
        print("  FAIL: NSWindow._cornerRadius is gone; this probe needs rewriting before it can pass")
        return false
    }
    print(String(format: "  NSWindow._cornerRadius = %.5f", stored))
    if abs(Double(stored) - claimed) > 1e-9 {
        print("  FAIL: the window's radius is \(stored) and the app is drawing \(claimed)")
        ok = false
    }

    guard let system = msgPath(frame, "_getCachedWindowCornerPath") else {
        print("  FAIL: NSThemeFrame._getCachedWindowCornerPath is gone; rewrite the probe")
        return false
    }

    // Where the curve leaves the straight edge, which for a continuous corner is
    // 1.5287 radii from the vertex rather than one.
    var firstMove: CGPoint?
    system.applyWithBlock { element in
        if firstMove == nil, element.pointee.type == .moveToPoint {
            firstMove = element.pointee.points[0]
        }
    }
    let expected = claimed * Double(CALayer.cornerCurveExpansionFactor(.continuous))
    print(String(
        format: "  corner extent: path says %.5f pt, radius x expansion factor says %.5f pt",
        firstMove?.y ?? -1, expected
    ))
    if abs(Double(firstMove?.y ?? -1) - expected) > 1e-4 {
        print("  FAIL: the corner is not \(expected) pt long, so it is not a \(claimed) pt continuous corner")
        ok = false
    }

    // Against the public shapes, rasterized, which is the check that says
    // "continuous at this radius" rather than merely "some corner". The two paths
    // are not comparable element by element: AppKit starts its outline at the
    // bottom-left corner and SwiftUI at the middle of the right edge, so the same
    // curve arrives as a different list.
    //
    // The whole corner is read here, all 24.46 pt of it, unlike the `match` arm
    // which can only see the 22 pt the bar covers.
    let box = CGRect(origin: .zero, size: frame.bounds.size)
    let rows = Int((WindowCorner.extent + 3) * Double(scale))
    let measured = insets(systemCorner(system), side: patch, rows: rows)
    let continuous = insets(
        systemCorner(RoundedRectangle(cornerRadius: claimed, style: .continuous).path(in: box).cgPath),
        side: patch,
        rows: rows
    )
    let circular = insets(
        systemCorner(RoundedRectangle(cornerRadius: claimed, style: .circular).path(in: box).cgPath),
        side: patch,
        rows: rows
    )
    table([("window", measured), ("continuous", continuous), ("circular", circular)], rows: rows)
    ok = compare(
        measured,
        continuous,
        label: "the window against RoundedRectangle(\(claimed), .continuous)",
        inward: 0.01,
        outward: 0.01
    ) && ok

    // Stated rather than assumed: a circle of the same radius is a different
    // shape, and by how much. If this ever stops being true the corner has become
    // a circle and the drawing code, which goes out of its way not to use one,
    // is solving a problem that no longer exists.
    var circularGap = 0.0
    for row in 0 ..< rows {
        guard let a = measured[row], let b = circular[row] else { continue }
        circularGap = max(circularGap, abs(a - b))
    }
    print(String(format: "  a circular arc of the same radius is off by up to %.4f pt", circularGap))
    if circularGap < 0.5 {
        print("  FAIL: the window's corner is now indistinguishable from a circle; re-derive WindowCorner")
        ok = false
    }

    window.orderOut(nil)
    return ok
}

/// Does what the footer draws land on what the window cuts?
///
/// Two shapes rasterized at 2x and read row by row: AppKit's own corner path, and
/// the path the shipped `PaneStatusBarView` fills, clips its hairline to, and
/// strokes its focus frame on. Compared over the bar's own 22 pt, because that is
/// all of the corner the footer can show: the corner is 24.46 pt long, so its top
/// 2.46 pt is above the bar entirely.
func matchArm(circularControl: Bool) -> Bool {
    var ok = true
    guard let system = windowCornerPath() else { return false }

    let rows = Int(PaneStatusBarMetrics.height * Double(scale)) - 2
    let reference = insets(systemCorner(system), side: patch, rows: rows)
    let drawn = insets(
        footerCorner(corners: .left, inset: 0, radiusOverride: circularControl ? WindowCorner.radius : nil),
        side: patch,
        rows: rows
    )

    print(circularControl
        ? "footer fill drawn as a CIRCULAR arc of the same radius (negative control)"
        : "footer fill, as shipped")
    table([("window", reference), ("footer", drawn)], rows: rows)
    // Inward: a hundredth of a point, which is a fiftieth of a pixel at 2x.
    // Outward: 0.06 pt, spent on one thing only. The corner is 24.46 pt long and
    // the bar is 22 pt tall, so SwiftUI cuts the curve short, and its truncation
    // leans a fraction outward over the last third of the arc. That is on the far
    // side of the window's own mask, which removes it before it reaches a pixel.
    ok = compare(
        drawn,
        reference,
        label: "fill against the window's own mask",
        inward: 0.01,
        outward: 0.06
    ) && ok

    // The right-hand corner too, so a shape built with leading and trailing the
    // wrong way round cannot pass on symmetry.
    let mirrored = insets(mirroredRightCorner(), side: patch, rows: rows)
    ok = compare(
        mirrored,
        reference,
        label: "the other corner, mirrored",
        inward: 0.01,
        outward: 0.06
    ) && ok

    // And a pane in no corner keeps a square bar.
    let square = insets(footerCorner(corners: [], inset: 0), side: patch, rows: rows)
    let squareWorst = square.compactMap { $0 }.map { abs($0) }.max() ?? -1
    print(String(format: "  a pane away from the window's edge: worst inset = %.4f pt (want 0)", squareWorst))
    if squareWorst > 0.001 {
        print("  FAIL: a pane with no window corner is being rounded anyway")
        ok = false
    }

    return ok
}

/// AppKit's own corner path for an ordinary titled window.
func windowCornerPath() -> CGPath? {
    let (window, frame) = probeWindow()
    defer { window.orderOut(nil) }
    guard let system = msgPath(frame, "_getCachedWindowCornerPath") else {
        print("  FAIL: NSThemeFrame._getCachedWindowCornerPath is gone; rewrite the probe")
        return nil
    }
    return system
}

/// The bottom-right corner of the footer, read from the right-hand edge and
/// mirrored, so it can be compared against the same left-hand reference.
///
/// Drawn at the bar's full width rather than in a 120 px patch, because the right
/// corner is at the far end of the bar and a patch anchored at the origin never
/// reaches it. Sampling it mirrored is the point: a shape built with leading and
/// trailing the wrong way round would pass a left-corner check on its own.
func mirroredRightCorner() -> [Double] {
    let height = PaneStatusBarMetrics.height
    let width = 300.0
    let pixelsWide = Int(width * Double(scale))
    var pixels = [UInt8](repeating: 0, count: pixelsWide * patch * 4)
    pixels.withUnsafeMutableBytes { raw in
        let context = CGContext(
            data: raw.baseAddress,
            width: pixelsWide,
            height: patch,
            bitsPerComponent: 8,
            bytesPerRow: pixelsWide * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setShouldAntialias(true)
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        context.addPath(
            WindowCorner.path(
                in: NSRect(x: 0, y: 0, width: width, height: height),
                corners: .right
            ).cgPath
        )
        context.fillPath()
    }
    var out = [Double](repeating: 0, count: patch * patch)
    for row in 0 ..< patch {
        for column in 0 ..< patch {
            let source = ((patch - 1 - row) * pixelsWide + (pixelsWide - 1 - column)) * 4 + 3
            out[row * patch + column] = Double(pixels[source]) / 255
        }
    }
    return out
}

/// Is the focus frame everywhere 1 pt inside the window's outline?
///
/// The frame is a 2 pt stroke whose centreline sits 1 pt inside the bar, so its
/// radius has to come down to 15 with it. Two curves are only parallel when they
/// are concentric; reuse the window's 16 for an inset path and the gap widens
/// through the corner and closes again on the straight edges, which reads as the
/// frame sagging away from the window and coming back.
///
/// Measured as a perpendicular distance rather than a row-wise one, because a
/// row-wise gap grows to 1.41 pt at the diagonal for a frame that is exactly
/// right, and there would be nothing to compare it against.
func concentricArm(wrongRadius: Bool) -> Bool {
    guard let system = windowCornerPath() else { return false }
    let inset = PaneStatusBarMetrics.focusFrameWidth / 2
    let rect = NSRect(x: 0, y: 0, width: 300, height: PaneStatusBarMetrics.height)

    let frame: CGPath
    if wrongRadius {
        // The control insets the rectangle and keeps the window's radius, which
        // is the mistake this arm exists to catch and the one the shipped path
        // avoids by shrinking the radius with the inset.
        frame = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: WindowCorner.radius,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
        ).path(in: rect.insetBy(dx: inset, dy: inset)).cgPath
        print("focus frame drawn at the window's own radius on an inset rect (negative control)")
    } else {
        frame = WindowCorner.path(in: rect, corners: .left, inset: inset).cgPath
        print("focus frame, as shipped: inset \(inset) pt, radius \(WindowCorner.radius - inset) pt")
    }

    // Back into the window's y-up space, so the two curves sit on the same corner.
    var flip = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -PaneStatusBarMetrics.height)
    let frameInWindowSpace = frame.copy(using: &flip)!

    let outline = flatten(system)
    let inner = flatten(frameInWindowSpace)
    var worst = 0.0
    var samples = 0
    // The corner itself, as a diagonal band from the vertex. Anything further out
    // than this is the bar's top edge, which is 21 pt from the window's bottom and
    // parallel to nothing.
    for point in inner where point.x + point.y < 20 && point.x > 0.3 && point.y > 0.3 {
        let distance = outline.map { hypot($0.x - point.x, $0.y - point.y) }.min() ?? .infinity
        worst = max(worst, abs(distance - inset))
        samples += 1
    }
    print(String(
        format: "  %d samples through the corner, worst deviation from %.1f pt inside = %.4f pt",
        samples, inset, worst
    ))
    guard samples > 40 else {
        print("  FAIL: the corner was not sampled, so nothing was measured")
        return false
    }
    // A tenth of a point, which is a fifth of a pixel at 2x. It is not zero and
    // cannot be: a continuous corner of radius r-d is the platform's idea of
    // concentric, not the exact offset curve of the radius-r one, and the two part
    // company by 0.071 pt at the tightest part of the arc. Keeping the outer
    // radius instead misses by 0.414 pt, six times as far and the wrong side of
    // this line.
    guard worst <= 0.1 else {
        print("  FAIL: the focus frame is not concentric with the window; it wanders by \(worst) pt")
        return false
    }
    return true
}

/// A path as a dense polyline. Enough steps that the sampling error is well under
/// the tolerances above.
func flatten(_ path: CGPath, steps: Int = 512) -> [CGPoint] {
    var points: [CGPoint] = []
    var current = CGPoint.zero
    var start = CGPoint.zero
    path.applyWithBlock { element in
        let raw = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint:
            current = raw[0]
            start = current
            points.append(current)
        case .addLineToPoint:
            for step in 1 ... steps {
                let t = Double(step) / Double(steps)
                points.append(CGPoint(
                    x: current.x + (raw[0].x - current.x) * t,
                    y: current.y + (raw[0].y - current.y) * t
                ))
            }
            current = raw[0]
        case .addCurveToPoint:
            let p0 = current
            for step in 1 ... steps {
                let t = Double(step) / Double(steps)
                let u = 1 - t
                points.append(CGPoint(
                    x: u * u * u * p0.x + 3 * u * u * t * raw[0].x + 3 * u * t * t * raw[1].x + t * t * t * raw[2].x,
                    y: u * u * u * p0.y + 3 * u * u * t * raw[0].y + 3 * u * t * t * raw[1].y + t * t * t * raw[2].y
                ))
            }
            current = raw[2]
        case .addQuadCurveToPoint:
            let p0 = current
            for step in 1 ... steps {
                let t = Double(step) / Double(steps)
                let u = 1 - t
                points.append(CGPoint(
                    x: u * u * p0.x + 2 * u * t * raw[0].x + t * t * raw[1].x,
                    y: u * u * p0.y + 2 * u * t * raw[0].y + t * t * raw[1].y
                ))
            }
            current = raw[1]
        case .closeSubpath:
            current = start
        @unknown default:
            break
        }
    }
    return points
}

// MARK: - The height arm

func renderBar(
    corners: BottomCorners,
    height: Double,
    anchorName: String = "baia",
    focused: Bool = true,
    attention: PaneStatus.Attention = .none
) -> (pixels: [UInt8], width: Int, height: Int)? {
    let width = 300.0
    let bar = PaneStatusBarView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    bar.theme = .darkPastel
    bar.isWindowActive = true
    bar.isFocused = focused
    bar.bottomCorners = corners
    bar.status = PaneStatus(
        anchorName: anchorName,
        anchorIsRepository: true,
        isPinned: true,
        workingDirectory: nil,
        git: PaneStatus.Git(
            head: "main",
            hasUpstream: true,
            ahead: 1,
            behind: 0,
            dirty: true,
            untracked: 3,
            conflicted: 0,
            operation: nil,
            isLinkedWorktree: false
        ),
        agent: PaneStatus.Agent(
            label: "claude",
            wantsAttention: attention != .none,
            isAcknowledged: attention == .acknowledged
        )
    )
    bar.layoutSubtreeIfNeeded()
    bar.displayIfNeeded()
    guard let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) else { return nil }
    bar.cacheDisplay(in: bar.bounds, to: rep)
    guard let data = rep.bitmapData else { return nil }
    let count = rep.bytesPerRow * rep.pixelsHigh
    return (
        pixels: Array(UnsafeBufferPointer(start: data, count: count)),
        width: rep.pixelsWide,
        height: rep.pixelsHigh
    )
}

typealias Render = (pixels: [UInt8], width: Int, height: Int)

/// Everything more than the focus frame's own width inside the bar's outline has
/// to be pixel for pixel what it was.
///
/// Two gates, because there are two ways the footer can move. The first is the
/// size: a bar a point taller shrinks the terminal above it, which resizes the
/// ghostty grid and sends `SIGWINCH` to whatever is running in the pane. The
/// second is the contents: the anchor name and the branch are drawn from a fixed
/// baseline and a fixed inset, and neither may shift because the bar grew a
/// curve.
///
/// The allowance is the band along the bar's own edge, two points thick, which is
/// where the fill's curve, the hairline and the focus frame all live. Anything
/// deeper than that is text.
func sameEverywhereItMatters(_ square: Render, _ candidate: Render, label: String) -> Bool {
    print("  \(label):")
    guard square.width == candidate.width, square.height == candidate.height else {
        print("    FAIL: the two bars are different sizes, \(square.height) px tall against \(candidate.height)")
        print("          which is the SIGWINCH hazard itself, not a drawing difference")
        return false
    }

    // The interior: the shipped outline pulled in by the width of the focus
    // frame. A pixel outside this is on the bar's edge, where the curve, the
    // hairline and the frame are all entitled to change.
    let interior = raster(side: patch) { context in
        context.translateBy(x: 0, y: PaneStatusBarMetrics.height)
        context.scaleBy(x: 1, y: -1)
        context.addPath(WindowCorner.path(
            in: NSRect(x: 0, y: 0, width: 300, height: PaneStatusBarMetrics.height),
            corners: .left,
            inset: PaneStatusBarMetrics.focusFrameWidth + 1 / Double(scale)
        ).cgPath)
        context.fillPath()
    }

    var differing = 0
    var illegal = 0
    var firstIllegal = ""
    let bytesPerRow = square.pixels.count / square.height
    for row in 0 ..< square.height {
        for column in 0 ..< square.width {
            let offset = row * bytesPerRow + column * 4
            var same = true
            for channel in 0 ..< 4 where square.pixels[offset + channel] != candidate.pixels[offset + channel] {
                same = false
            }
            guard !same else { continue }
            differing += 1
            // Row 0 of an `NSBitmapImageRep` is the top one; the patch is measured
            // from the bottom, and the corner is read from whichever end is nearer.
            let fromBottom = square.height - 1 - row
            let fromNearestEnd = min(column, square.width - 1 - column)
            let reachable = fromNearestEnd < patch && fromBottom < patch
            let coverage = reachable ? interior[fromBottom * patch + fromNearestEnd] : 1
            if coverage > 0.999 {
                illegal += 1
                if firstIllegal.isEmpty {
                    firstIllegal = "px (\(column), \(fromBottom) up from the bottom)"
                }
            }
        }
    }
    print("    \(differing) pixels differ, \(illegal) of them inside the bar rather than on its edge")
    guard differing > 100 else {
        print("    FAIL: nothing changed at all, so this comparison proves nothing")
        return false
    }
    guard illegal == 0 else {
        print("    FAIL: \(illegal) pixels moved inside the bar, first at \(firstIllegal)")
        print("          the corner is meant to take a bite out of the edge, not move the bar's contents")
        return false
    }
    return true
}

/// Did rounding a corner move anything it must not move?
func heightArm(breakIt: Bool) -> Bool {
    var ok = true

    print(String(format: "  PaneStatusBarMetrics.height = %.2f", PaneStatusBarMetrics.height))
    print(String(format: "  reservedHeight(focused: false) = %.2f", PaneStatusBarMetrics.reservedHeight(focused: false)))
    print(String(format: "  reservedHeight(focused: true)  = %.2f", PaneStatusBarMetrics.reservedHeight(focused: true)))
    print(String(format: "  baselineFromTop = %.2f", PaneStatusBarMetrics.baselineFromTop))
    if PaneStatusBarMetrics.height != 22
        || PaneStatusBarMetrics.reservedHeight(focused: true) != PaneStatusBarMetrics.height
        || PaneStatusBarMetrics.reservedHeight(focused: false) != PaneStatusBarMetrics.height
        || PaneStatusBarMetrics.baselineFromTop != 15
    {
        print("  FAIL: the bar's geometry moved")
        ok = false
    }

    let squareBar = PaneStatusBarView(frame: .zero)
    let roundedBar = PaneStatusBarView(frame: .zero)
    roundedBar.bottomCorners = .both
    print(String(
        format: "  intrinsicContentSize.height: square %.2f, rounded %.2f",
        squareBar.intrinsicContentSize.height, roundedBar.intrinsicContentSize.height
    ))
    if squareBar.intrinsicContentSize.height != roundedBar.intrinsicContentSize.height {
        print("  FAIL: the corner changed the height the bar claims")
        ok = false
    }

    guard let square = renderBar(corners: [], height: PaneStatusBarMetrics.height) else {
        print("  FAIL: the bar rendered nothing, so nothing was compared")
        return false
    }
    let lit = square.pixels.enumerated().filter { $0.offset % 4 == 3 && $0.element > 0 }.count
    print("  rendered \(square.width)x\(square.height) px, \(lit) opaque pixels")
    guard lit > 1000 else {
        print("  FAIL: the render is empty; cacheDisplay did not draw the bar")
        return false
    }

    guard !breakIt else {
        // Both gates are damaged, one each, so neither can pass untested: a bar a
        // point taller, and a bar whose contents sit somewhere else.
        guard let taller = renderBar(corners: .both, height: PaneStatusBarMetrics.height + 1),
              let shifted = renderBar(corners: .both, height: PaneStatusBarMetrics.height, anchorName: "baia-moved-along")
        else { return false }
        let sizeGate = sameEverywhereItMatters(square, taller, label: "against a footer one point taller")
        let textGate = sameEverywhereItMatters(square, shifted, label: "against a footer whose text moved")
        return sizeGate && textGate
    }

    guard let rounded = renderBar(corners: .both, height: PaneStatusBarMetrics.height) else { return false }
    return sameEverywhereItMatters(square, rounded, label: "square bar against rounded bar") && ok
}

// MARK: - The clip arm

/// The owner's real arrangement: three columns of two rows each.
///
/// Here so the `clip` arm can ask ``PaneTree/bottomCorners(in:)`` for the corners
/// it renders rather than writing `.left` and calling it the layout's answer. The
/// query has its own unit tests in `WorkspaceLayout`; what this adds is that the
/// pixels below were shaped by the same call the app makes.
struct Grid2x3 {
    let topLeft = PaneID()
    let bottomLeft = PaneID()
    let topMiddle = PaneID()
    let bottomMiddle = PaneID()
    let topRight = PaneID()
    let bottomRight = PaneID()

    private func column(_ top: PaneID, _ bottom: PaneID) -> PaneTree {
        .split(axis: .vertical, ratio: 0.5, first: .leaf(top), second: .leaf(bottom))
    }

    var tree: PaneTree {
        .split(
            axis: .horizontal,
            ratio: 1.0 / 3.0,
            first: column(topLeft, bottomLeft),
            second: .split(
                axis: .horizontal,
                ratio: 0.5,
                first: column(topMiddle, bottomMiddle),
                second: column(topRight, bottomRight)
            )
        )
    }
}

func name(_ corners: BottomCorners) -> String {
    switch corners {
    case .both: "left and right"
    case .left: "left"
    case .right: "right"
    default: "neither"
    }
}

/// The bottom-left corner of a rendered bar as a coverage patch, row 0 at the
/// bottom, to match everything else measured here.
///
/// Alpha only, which is what makes the reading independent of the text: the anchor
/// name is drawn over an opaque fill, so it moves colour and not coverage. A pixel
/// past the end of the bar reads as covered, since the profile is only ever asked
/// for rows the bar has.
func renderedCorner(_ render: Render) -> [Double] {
    let bytesPerRow = render.pixels.count / render.height
    var out = [Double](repeating: 1, count: patch * patch)
    for row in 0 ..< min(patch, render.height) {
        // Row 0 of an `NSBitmapImageRep` is the top one.
        let source = (render.height - 1 - row) * bytesPerRow
        for column in 0 ..< min(patch, render.width) {
            out[row * patch + column] = Double(render.pixels[source + column * 4 + 3]) / 255
        }
    }
    return out
}

/// Does the bar a real ``PaneStatusBarView`` renders have the corner in it?
///
/// Every arm above measures a path. This one measures pixels the shipped
/// `draw(_:)` produced, which is the only thing that says its clip is doing
/// anything: delete the `addClip()` and the fill goes back to a rectangle while a
/// probe that reads `WindowCorner.path` on its own stays green.
///
/// Rendered unfocused on purpose. The focus frame is stroked on its own copy of
/// the path by `drawBarFrame(in:)` and would keep the corner visible in the
/// bitmap by itself, so a focused bar cannot answer for the fill. Unfocused, the
/// only things in the bitmap are the fill and the hairline, and both are inside
/// the clip.
///
/// The control renders the same bar with no corners, which is pixel for pixel what
/// a `draw(_:)` with its clip removed produces for a pane in the corner.
/// Is one pixel different between two renders of the same bar?
///
/// Indexed from the bottom because that is the edge under test, while row 0 of an
/// `NSBitmapImageRep` is the top one.
func differs(_ one: Render, _ other: Render, column: Int, fromBottom: Int) -> Bool {
    let bytesPerRow = one.pixels.count / one.height
    let offset = (one.height - 1 - fromBottom) * bytesPerRow + column * 4
    for channel in 0 ..< 4 where one.pixels[offset + channel] != other.pixels[offset + channel] {
        return true
    }
    return false
}

/// Does an acknowledged pane draw a line along the bottom edge, inside the corner
/// and inside the focus frame?
///
/// The level's whole justification is being findable across a window while
/// staying quiet enough to work beside, and until this line the only thing
/// carrying it was a 6 pt square at the far left of one footer, which a live look
/// on 2026-07-31 could not pick out from a pane that was asking nothing.
///
/// Measured as a difference against the same bar rendered at `.none`, so the arm
/// answers "these pixels are here because the pane is acknowledged" rather than
/// "something is coloured down there", which the hairline satisfies on every bar
/// in the app.
///
/// Three claims, because three separate things silently take the line away. It
/// has to be drawn at all. It has to be clipped to the corner, or a pane in the
/// window's corner grows a square one. And it has to sit inside the focus frame,
/// which is stroked over this view by `drawBarFrame(in:)` and would otherwise
/// swallow the line on the focused pane, which is the pane most likely to be
/// acknowledged.
///
/// The control renders the acknowledged bar as an ordinary one, which is pixel for
/// pixel what deleting the draw produces.
func ackLineArm(breakIt: Bool) -> Bool {
    let corners: BottomCorners = .left
    let height = PaneStatusBarMetrics.height
    guard
        let plain = renderBar(corners: corners, height: height, focused: false, attention: .none),
        let acked = renderBar(
            corners: corners,
            height: height,
            focused: false,
            attention: breakIt ? .none : .acknowledged
        ),
        let plainFocused = renderBar(corners: corners, height: height, focused: true, attention: .none),
        let ackedFocused = renderBar(
            corners: corners,
            height: height,
            focused: true,
            attention: breakIt ? .none : .acknowledged
        )
    else {
        print("  FAIL: the bar rendered nothing, so nothing was measured")
        return false
    }

    let renderScale = Double(plain.width) / 300
    let rows = max(1, Int((PaneStatusBarMetrics.attentionLine * renderScale).rounded()))
    let inset = Int((PaneStatusBarMetrics.focusFrameWidth * renderScale).rounded())
    let middle = plain.width / 2
    print(breakIt
        ? "bar rendered NOT acknowledged (negative control: the level's draw removed)"
        : "bar rendered acknowledged by PaneStatusBarView, as shipped")
    print(String(format: "  %dx%d px, %.1f px per point, line is %d row(s)",
                 plain.width, plain.height, renderScale, rows))

    var ok = true

    // 1. Drawn at all, across the flat middle where no curve can be blamed.
    let drawnRows = (0 ..< rows).filter { differs(plain, acked, column: middle, fromBottom: $0) }
    if drawnRows.count == rows {
        print("  the unfocused bar differs on all \(rows) bottom row(s) at mid-width")
    } else {
        print("  FAIL: only \(drawnRows.count) of \(rows) bottom row(s) differ at mid-width,")
        print("        so an acknowledged pane is drawing no line along its bottom edge")
        ok = false
    }

    // 2. Clipped to the corner. An unclipped rect paints the outermost column of
    //    the bottom row, which is outside the curve and outside the window's mask.
    if differs(plain, acked, column: 0, fromBottom: 0) {
        print("  FAIL: the bottom-left pixel changed, so the line is a full-width rect")
        print("        rather than a fill clipped to the corner it shares with the window")
        ok = false
    } else {
        print("  the bottom-left pixel is untouched, so the line is inside the corner")
    }

    // 3. Inside the focus frame, which is stroked over this view.
    let focusedRows = (0 ..< rows).filter {
        differs(plainFocused, ackedFocused, column: middle, fromBottom: inset + $0)
    }
    if focusedRows.count == rows {
        print("  the focused bar differs on all \(rows) row(s) just inside the frame")
    } else {
        print("  FAIL: only \(focusedRows.count) of \(rows) row(s) differ inside the focus frame,")
        print("        so the frame is swallowing the line on the focused pane")
        ok = false
    }

    return ok
}

func clipArm(breakIt: Bool) -> Bool {
    guard let system = windowCornerPath() else { return false }

    let grid = Grid2x3()
    let corners = grid.tree.bottomCorners()[grid.bottomLeft] ?? []
    print("PaneTree.bottomCorners gives the bottom-left pane of a 2x3 grid: \(name(corners))")
    guard corners == .left else {
        print("  FAIL: the layout is not naming the bottom-left pane's left corner, so nothing below means anything")
        return false
    }

    guard let render = renderBar(
        corners: breakIt ? [] : corners,
        height: PaneStatusBarMetrics.height,
        focused: false
    ) else {
        print("  FAIL: the bar rendered nothing, so nothing was measured")
        return false
    }

    // Whatever `cacheDisplay(in:to:)` gave, so the reference is rasterized in the
    // same units rather than the probe's own 2x being assumed of it.
    let renderScale = CGFloat(render.width) / 300
    let rows = Int(PaneStatusBarMetrics.height * Double(renderScale)) - 2
    print(breakIt
        ? "bar rendered with NO corners (negative control: the clip in draw(_:) removed)"
        : "bar rendered by PaneStatusBarView, as shipped")
    print(String(format: "  %dx%d px, %.1f px per point", render.width, render.height, renderScale))

    var drawn = insets(renderedCorner(render), side: patch, rows: rows, at: renderScale)
    var reference = insets(systemCorner(system, at: renderScale), side: patch, rows: rows, at: renderScale)
    table([("window", reference), ("rendered", drawn)], rows: rows, at: renderScale)

    // The hairline's own rows are dropped, and nothing else. They are the rows
    // where two draws composite through the same clip, the fill and then the
    // hairline on top of it, and two antialiased passes over the same partial
    // coverage add up to more than one: the row saturates sooner and reads further
    // out than the path it was clipped to. It is worst in the bottom row, 1.04 pt,
    // because the curve is nearly horizontal there and a row of coverage spans 5 pt
    // of shape; the row above it is 0.22 pt and the first row with a single draw in
    // it is 0.02. The `match` arm fills the same path once and reads the bottom row
    // exactly, to four decimals, which is what says this is compositing at a
    // shallow angle and not the bar being the wrong shape. It is a fraction of a
    // pixel of alpha, on the far side of the window's own mask.
    for row in 0 ..< Int(PaneStatusBarMetrics.hairlineHeight * Double(renderScale)) {
        drawn[row] = nil
        reference[row] = nil
    }

    // Looser than the `match` arm, which compares two paths and holds 0.01. This
    // compares a rasterized, doubly composited edge against a path, and the
    // measured spread over the other 41 rows is 0.022 pt inward and 0.047 pt
    // outward. Loose enough to be a shape check rather than a rasterizer check,
    // and nowhere near loose enough to pass a square bar: the control misses by
    // 10 pt on the second row.
    return compare(
        drawn,
        reference,
        label: "the rendered bar against the window's own mask",
        inward: 0.04,
        outward: 0.07,
        at: renderScale
    )
}

// MARK: - The frame arm

/// A real ``PaneEdgeFrameView`` at pane size, rendered the way the `clip` arm
/// renders a real bar.
///
/// Taller than the corner is long, so the whole 24.46 pt of it is in the bitmap
/// rather than the 22 pt the footer can show. The frame is the one surface that
/// gets all of it.
func renderFrame(corners: BottomCorners) -> Render? {
    let frame = PaneEdgeFrameView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    frame.colour = PaneTheme.darkPastel.alert
    frame.bottomCorners = corners
    frame.isVisible = true
    frame.layoutSubtreeIfNeeded()
    frame.displayIfNeeded()
    guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
    frame.cacheDisplay(in: frame.bounds, to: rep)
    guard let data = rep.bitmapData else { return nil }
    let count = rep.bytesPerRow * rep.pixelsHigh
    return (
        pixels: Array(UnsafeBufferPointer(start: data, count: count)),
        width: rep.pixelsWide,
        height: rep.pixelsHigh
    )
}

/// Does the attention frame turn the corner with the footer, or run square into it?
///
/// The bug this arm exists for, found on a screenshot on 2026-07-29 and fixed on
/// 2026-07-30: every surface on the footer went through ``WindowCorner`` and the
/// frame around the whole pane did not, so at a corner the pane shares with the
/// window the frame's edge carried straight on past the point where the fill
/// curved away, and the window's mask cut the overhang off into a spur. The two
/// shapes are visible at the same time and in the same colour, which is what made
/// a 2 pt disagreement read as damage rather than as a detail.
///
/// Measured as pixels rather than as a path, for the reason the `clip` arm gives:
/// a path that is right proves nothing about a `draw(_:)` that does not use it.
/// What is profiled is the *outer* edge of the stroke, which is where the
/// concentric rule lands it: a 2 pt stroke whose centreline sits 1 pt in at radius
/// 15 has its outer edge on the window's own 16, so the reference is the mask
/// itself with no allowance for the inset.
///
/// The control is the shape that shipped until 2026-07-30, a square rectangle,
/// which is the regression this is here to catch.
func frameArm(breakIt: Bool) -> Bool {
    guard let system = windowCornerPath() else { return false }

    let grid = Grid2x3()
    let corners = grid.tree.bottomCorners()[grid.bottomLeft] ?? []
    print("PaneTree.bottomCorners gives the bottom-left pane of a 2x3 grid: \(name(corners))")
    guard corners == .left else {
        print("  FAIL: the layout is not naming the bottom-left pane's left corner, so nothing below means anything")
        return false
    }

    guard let render = renderFrame(corners: breakIt ? [] : corners) else {
        print("  FAIL: the frame rendered nothing, so nothing was measured")
        return false
    }

    let renderScale = CGFloat(render.width) / 300
    // Two points short of the corner's full 24.46 pt. The last of it is where the
    // curve is nearly vertical and a row spans several points of shape, which is a
    // rasterizer reading rather than a shape one.
    let rows = Int(22 * Double(renderScale))
    print(breakIt
        ? "frame rendered with NO corners (negative control: the square path that shipped before)"
        : "frame rendered by PaneEdgeFrameView, as shipped")
    print(String(format: "  %dx%d px, %.1f px per point", render.width, render.height, renderScale))

    var drawn = insets(renderedCorner(render), side: patch, rows: rows, at: renderScale)
    var reference = insets(systemCorner(system, at: renderScale), side: patch, rows: rows, at: renderScale)
    table([("window", reference), ("frame", drawn)], rows: rows, at: renderScale)

    // The bottom stroke's own rows, dropped for the reason the `clip` arm drops the
    // hairline's: down there the curve is nearly horizontal, so a single pixel row
    // spans several points of shape and the coverage saturates well outside the
    // path it came from. Everything above them is a stroke crossed at an angle the
    // reading can resolve.
    for row in 0 ..< Int(2 * Double(renderScale)) {
        drawn[row] = nil
        reference[row] = nil
    }

    // The `clip` arm's tolerances, for the same reasons: a rasterized, antialiased
    // edge against a path. Nowhere near loose enough to pass the control, which is
    // a square corner and misses by more than 10 pt.
    return compare(
        drawn,
        reference,
        label: "the rendered attention frame against the window's own mask",
        inward: 0.04,
        outward: 0.07,
        at: renderScale
    )
}

// MARK: - The full-screen arm

/// Runs the main run loop until `done` or the deadline, dispatching AppKit events
/// as well as run-loop sources.
///
/// A full-screen transition is asynchronous and driven by the window server, so it
/// needs both: pumping `RunLoop` alone leaves `toggleFullScreen(_:)` hanging and
/// the notifications never arrive.
@MainActor
func pump(_ seconds: Double, until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if done() { return }
        while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

/// Does the footer stop curving when the window stops being round?
///
/// A window in full screen is masked to the display, not to a 16 pt corner. A
/// footer that keeps its curve there carves a wedge out of itself, 24.46 pt wide at
/// the window's bottom edge, and since nothing paints under the bar what shows
/// through is the window's own `backgroundColor`: a system-appearance colour on
/// chrome that is otherwise strictly the terminal's.
///
/// A real window is driven through both transitions rather than a style mask being
/// built with `.fullScreen` in it, because the answer this arm exists to give is
/// *when* the mask flips. `PaneTreeController` observes `didEnterFullScreen` and
/// `didExitFullScreen`, and that is only correct because at `willEnterFullScreen`
/// the window still reports itself windowed, so a push there would read the old
/// answer and do nothing. This asserts that ordering, so an OS that moved the flip
/// fails here instead of leaving the wedge on screen.
///
/// The control is the predicate as it was before this was fixed: every window is
/// round. It is the bug itself, and it has to fail.
func fullscreenArm(breakIt: Bool) -> Bool {
    var ok = true
    let isRounded: (NSWindow) -> Bool = breakIt
        ? { _ in true }
        : { WindowCorner.isRounded($0) }

    let window = NSWindow(
        contentRect: NSRect(x: 200, y: 200, width: 700, height: 500),
        // The workspace window's own mask, from `WorkspaceWindowController`.
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)

    var seen: [(name: String, fullScreenBit: Bool)] = []
    var observers: [any NSObjectProtocol] = []
    for notification: NSNotification.Name in [
        NSWindow.willEnterFullScreenNotification,
        NSWindow.didEnterFullScreenNotification,
        NSWindow.willExitFullScreenNotification,
        NSWindow.didExitFullScreenNotification,
    ] {
        let label = notification.rawValue
            .replacingOccurrences(of: "NSWindow", with: "")
            .replacingOccurrences(of: "Notification", with: "")
        observers.append(
            NotificationCenter.default.addObserver(
                forName: notification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    seen.append((label, window.styleMask.contains(.fullScreen)))
                }
            }
        )
    }
    defer {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        window.orderOut(nil)
    }

    /// The window's radius alongside what the shipped predicate says about it.
    /// Both, because either one alone can agree with the app by accident: the
    /// radius says what the system is doing and the predicate says what the footer
    /// will do about it.
    func check(_ label: String, wantRounded: Bool) -> Bool {
        let radius = Double(msgDouble(window, "_cornerRadius") ?? -1)
        let rounded = isRounded(window)
        print(String(
            format: "  %@ radius %6.3f   WindowCorner.isRounded %@",
            label.padding(toLength: 16, withPad: " ", startingAt: 0),
            radius,
            rounded ? "true" : "false"
        ))
        let wantRadius = wantRounded ? WindowCorner.radius : 0
        if abs(radius - wantRadius) > 1e-9 {
            print("    FAIL: the window's radius is \(radius) and this state should be \(wantRadius)")
            return false
        }
        if rounded != wantRounded {
            print("    FAIL: isRounded says \(rounded) for a window whose radius is \(radius)")
            return false
        }
        return true
    }

    ok = check("windowed", wantRounded: true) && ok

    window.toggleFullScreen(nil)
    pump(10) { seen.count >= 2 }
    ok = check("full screen", wantRounded: false) && ok

    window.toggleFullScreen(nil)
    pump(10) { seen.count >= 4 }
    ok = check("windowed again", wantRounded: true) && ok

    // The transition happened at all. Without this a machine that refused to go
    // full screen would pass three windowed checks and call the bug fixed.
    print("  notifications: " + seen.map { "\($0.name)=\($0.fullScreenBit ? "full" : "windowed")" }
        .joined(separator: ", "))
    let expected = [
        ("WillEnterFullScreen", false),
        ("DidEnterFullScreen", true),
        ("WillExitFullScreen", true),
        ("DidExitFullScreen", false),
    ]
    guard seen.count == expected.count,
          zip(seen, expected).allSatisfy({ $0.name == $1.0 && $0.fullScreenBit == $1.1 })
    else {
        print("    FAIL: the window did not report the transition the way PaneTreeController assumes.")
        print("          It observes didEnter/didExit because the style mask flips there and not at will*.")
        return false
    }
    return ok
}

// MARK: - Entry

@main
enum Probe {
    @MainActor static func main() {
        let app = NSApplication.shared
        let arm = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
        // `.accessory` everywhere else, so the probe measures without taking the
        // screen. The full-screen arm cannot: an accessory app's window refuses
        // `toggleFullScreen(_:)` outright, with no notification and no change to
        // the style mask, so that arm would pass by never transitioning at all.
        app.setActivationPolicy(arm == "fullscreen" ? .regular : .accessory)

        let breakIt = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "break"
        print("== \(arm)\(breakIt ? " (negative control: the thing under test is damaged)" : "")")

        let ok: Bool
        switch arm {
        case "radius":
            // The control claims a radius the window does not have, which is what
            // a macOS release that changed its corners would look like.
            ok = radiusArm(claimed: breakIt ? WindowCorner.radius + 1 : WindowCorner.radius)
        case "match":
            ok = matchArm(circularControl: breakIt)
        case "concentric":
            ok = concentricArm(wrongRadius: breakIt)
        case "height":
            ok = heightArm(breakIt: breakIt)
        case "clip":
            ok = clipArm(breakIt: breakIt)
        case "ackline":
            ok = ackLineArm(breakIt: breakIt)
        case "frame":
            ok = frameArm(breakIt: breakIt)
        case "fullscreen":
            ok = fullscreenArm(breakIt: breakIt)
        default:
            print("usage: cornertest radius|match|concentric|height|clip|ackline|frame|fullscreen [break]")
            ok = false
        }

        print(ok ? "PASS" : "FAIL")
        fflush(stdout)
        exit(ok ? 0 : 1)
    }
}
