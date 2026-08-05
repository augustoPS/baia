import AppKit
import QuartzCore
import SwiftUI
import WorkspaceLayout

/// The window's own rounded corner, for the chrome that has to meet it.
///
/// macOS masks a window's content to a rounded shape, so anything a pane draws
/// in a bottom corner is already being cut by a curve it knows nothing about.
/// That is fine for a flat fill and wrong for anything with an edge: the footer's
/// focus frame used to run square into a fill that curved away from it, with the
/// stroke's own corner sliced off by the mask.
///
/// Always on, with nothing to configure. Matching the window is a fact about
/// where the pane is, not a taste.
enum WindowCorner {
    /// The macOS 26 (Tahoe) window corner radius, in points.
    ///
    /// A constant because there is no public API that reports it. It was measured
    /// three independent ways rather than guessed, and `Diagnostics/footer-corners`
    /// re-measures it against `NSWindow`'s own mask path on every run so that an
    /// OS that changes it fails a check instead of quietly leaving the footer a
    /// point and a half off the window. Earlier macOS releases used a smaller
    /// radius, so a version bump means re-measuring.
    ///
    /// Do not fit this number from a screenshot. The compositor draws the corner a
    /// uniform 0.11 pt inside the geometric path, and a shape fit absorbs that
    /// inset as roughly +0.46 pt of radius.
    static let radius: Double = 16

    /// How far from the corner vertex the curve leaves the straight edge.
    ///
    /// Not the radius. A continuous corner runs 1.5287 times its radius along each
    /// edge, so the corner is 24.46 pt long, and that is the number to compare
    /// against when anything asks "is this near enough to the corner to care".
    /// Read from `CALayer` rather than written out, so the two cannot drift.
    static var extent: Double {
        radius * Double(CALayer.cornerCurveExpansionFactor(.continuous))
    }

    /// Is `window` masked to the corner this type draws?
    ///
    /// No for a window in full screen, which is where this matters. AppKit adds
    /// `.fullScreen` to the style mask and the window's radius goes to zero, so
    /// the system stops cutting the corner and a footer that kept curving to 16 pt
    /// carves a wedge out of itself instead: 24.46 pt wide at the window's bottom
    /// edge, tapering out 22 pt up, taking the fill, the hairline, the focus frame
    /// and the attention wash with it. Nothing paints under the footer, so what
    /// shows through is the window's own `backgroundColor`, a system-appearance
    /// colour on chrome that is otherwise strictly the terminal's.
    ///
    /// Measured rather than reasoned about, by `Diagnostics/footer-corners`'s
    /// `fullscreen` arm: the same window reads a radius of 16 windowed, 0 in full
    /// screen, and 16 again on the way out, and a style mask built with
    /// `.fullScreen` in it reads 0 without any transition at all.
    ///
    /// - Parameter window: nil for a pane whose view is not in a window yet, which
    ///   answers no. There is nothing to match, and a square footer is what a pane
    ///   has always drawn; ``PaneTreeController`` pushes again from
    ///   `viewWillAppear()`, before the first draw.
    static func isRounded(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return !window.styleMask.contains(.fullScreen)
    }

    /// The outline of `rect` with the named bottom corners curved to the window's.
    ///
    /// - Parameter inset: how far inside `rect` the path runs. The radius shrinks
    ///   with it, because two curves are only parallel when they are concentric:
    ///   a 2 pt stroke whose centreline sits 1 pt in needs radius 15, and reusing
    ///   16 would open a gap that widens through the corner and closes again on
    ///   the straight edges.
    ///
    /// Built through SwiftUI rather than `NSBezierPath(roundedRect:xRadius:yRadius:)`,
    /// which draws a circular arc. The system corner is a squircle, and beside one
    /// a circular arc of the same radius is visibly the wrong shape: it reaches the
    /// straight edge 8 pt sooner and sits 2.7 pt off the window's outline at the
    /// row nearest the corner. `RoundedRectangle(style: .continuous)` produces the
    /// system curve exactly, control point for control point, and
    /// `UnevenRoundedRectangle` produces the same corner for one end at a time.
    ///
    /// The bar is 22 pt tall and the corner is 24.46 pt long, so the curve is cut
    /// off by the top of the bar. SwiftUI subdivides the cubic rather than
    /// shrinking the radius to fit, which is what makes this correct at this
    /// height: the curve that is drawn is the window's curve, ending 0.002 pt away
    /// from the straight edge instead of reaching it.
    ///
    /// Leading and trailing are left and right here. `path(in:)` is called with no
    /// environment, so SwiftUI resolves them left-to-right, and the app is not
    /// localized.
    static func path(in rect: NSRect, corners: BottomCorners, inset: Double = 0) -> NSBezierPath {
        NSBezierPath(cgPath: cgPath(in: rect, corners: corners, inset: inset))
    }

    /// The same outline as ``path(in:corners:inset:)``, as a `CGPath` rather
    /// than an `NSBezierPath`.
    ///
    /// A `CAShapeLayer` mask (the glass backing's own corner clip, Task 4) takes
    /// a `CGPath` directly, and `NSBezierPath` has a one-way conversion out of
    /// `CGPath` (`init(cgPath:)`, macOS 14+) but none back in: there is no
    /// `NSBezierPath.cgPath` to call on the result of the other overload. Both
    /// overloads exist so a `draw(_:)` caller keeps using the `NSBezierPath` API
    /// its `NSGraphicsContext` clip already speaks, while a layer-mask caller
    /// gets there without a conversion that does not exist.
    static func cgPath(in rect: NSRect, corners: BottomCorners, inset: Double = 0) -> CGPath {
        let box = rect.insetBy(dx: inset, dy: inset)
        // A pane away from the window's edge is the common case, and a rectangle
        // is what it has always been drawn as. Going through SwiftUI for it would
        // spend a path conversion per draw on four straight lines.
        guard !corners.isEmpty else { return CGPath(rect: box, transform: nil) }

        let curve = max(0, radius - inset)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: corners.contains(.left) ? curve : 0,
            bottomTrailingRadius: corners.contains(.right) ? curve : 0,
            topTrailingRadius: 0,
            style: .continuous
        )
        // The view this is drawn into is flipped, which is also SwiftUI's
        // convention, so the shape's bottom is the visual bottom and no transform
        // is needed. In an unflipped view it would be upside down.
        return shape.path(in: box).cgPath
    }
}
