import Foundation

/// A rectangle with no CoreGraphics in it, so the layout model stays free of
/// AppKit and its tests keep running without Metal or a window server.
///
/// The origin is top-left, which is how a split tree reads: the first child of a
/// vertical split is the one on top, and its `y` is the smaller number. `NSView`
/// is bottom-left by default, so the AppKit layer flips `y` once when it turns
/// these into frames. Doing the flip here instead would put a coordinate
/// convention that only one caller cares about into every comparison in
/// ``PaneTree/neighbour(of:direction:in:)``.
public struct LayoutRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The whole of whatever space there is, in fractions. Directional focus
    /// resolves against this rather than a real frame, since the answer is
    /// invariant under independent positive scaling of `x` and `y`, and a menu
    /// action arriving before the first layout pass has no frame to hand it.
    public static let unit = LayoutRect(x: 0, y: 0, width: 1, height: 1)

    /// The right edge. A chain of ratios multiplied in a different order than its
    /// neighbour's can put this a bit away from the neighbour's `x`, which is why
    /// the neighbour search compares edges with a tolerance and not with `==`.
    var maxX: Double { x + width }

    /// The bottom edge, which is the larger `y` under a top-left origin.
    var maxY: Double { y + height }
}
