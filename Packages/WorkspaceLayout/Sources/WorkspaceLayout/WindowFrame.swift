import Foundation

/// The window's frame in screen points, as the session file carries it.
///
/// Separate from ``LayoutRect`` despite the identical four fields. This one is
/// `Codable` and lives in AppKit's bottom-left screen coordinates, while
/// `LayoutRect` is a top-left fraction of a window and is never persisted. One type
/// for both would need a note at every use saying which convention it meant, and
/// the flip would eventually be applied twice.
///
/// The caller has to intersect a restored frame with the current screens: a frame
/// saved on a monitor that is no longer attached puts the window out of reach.
public struct WindowFrame: Sendable, Equatable, Codable {
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
}
