import AppKit
import PaneChrome

/// Something a host can put on screen.
///
/// The whole point of the split: a surface knows how to draw itself into a rect and
/// nothing about where the rect is, and the host knows how to produce a rect and
/// nothing about what goes in it. That is what lets the sidebar stack two of them,
/// swap them, or show neither, without either surface knowing which of those is
/// happening.
@MainActor
protocol WorkspaceSurface: AnyObject {
    /// What the host installs. Never added to a pane's view hierarchy: a view
    /// inside a pane that takes first responder disables every ghostty binding in
    /// that pane, silently.
    var view: NSView { get }

    /// Drawn by the host's own chrome, so a surface does not each draw its own
    /// heading in its own way.
    var title: String { get }

    var theme: PaneTheme { get set }
}

/// The heading a host draws above whatever surface it is holding.
///
/// Drawn by the host and not by the surface, so two surfaces cannot each invent a
/// heading in their own weight and inset. ``WorkspaceSurface/title`` promises this
/// exists; a promise with nothing drawing it is the design prose running ahead of
/// the code, which this project has already been bitten by once.
@MainActor
final class SurfaceTitleView: NSView {
    var title: String = "" { didSet { needsDisplay = true } }
    var theme: PaneTheme = .darkPastel { didSet { needsDisplay = true } }

    override func draw(_: NSRect) {
        nsColor(theme.barBackground).setFill()
        bounds.fill()

        // A hairline along the bottom, the same one the tree draws between panes,
        // so the heading is separated by the divider vocabulary already in use
        // rather than by a rule of its own.
        nsColor(theme.hairline).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        let text = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: nsColor(theme.inkContext),
            ]
        )
        let size = text.size()
        text.draw(at: NSPoint(x: 12, y: (bounds.height - size.height) / 2 + 1))
    }

    private func nsColor(_ rgb: RGB) -> NSColor {
        NSColor(
            srgbRed: CGFloat(rgb.red),
            green: CGFloat(rgb.green),
            blue: CGFloat(rgb.blue),
            alpha: 1
        )
    }

    /// Fixed, and deliberately not a function of anything. A heading whose height
    /// depended on state would resize the surface under it, and in the sidebar that
    /// would resize the panes beside it.
    static let height: Double = 28
}
