import AppKit

/// The pane-wide glass plane behind one terminal surface.
///
/// Arrangement per the pane-as-glass spec (2026-08-08): subview index 0 of the
/// pane container, below the surface, full pane bounds. Under ABSORB (spec
/// fork 1) this one plane also serves the footer: `PaneStatusBarView` no
/// longer owns a glass view, so the pane never stacks glass on glass, which is
/// the HIG ban `Diagnostics/pane-glass-stacking` measured as a +19..21/255
/// seam over dark content.
///
/// The same three refusals as every other glass backing in this app: anything
/// in a pane that takes first responder kills every ghostty binding in it,
/// and a hit-testable view here would swallow the click that focuses the pane.
final class PaneGlassPlaneView: NSGlassEffectView {
    override var acceptsFirstResponder: Bool { false }

    override var canBecomeKeyView: Bool { false }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// The pane wash: `theme.background` over the plane, under the surface, so
/// terminal ink keeps its 4.5:1 floor whatever the wallpaper composites the
/// glass to (raw ink measured 1.19:1 over bright glass; the bound and the
/// sweep are `Diagnostics/pane-glass-legibility`).
///
/// The construction is the retired `SidebarGlassWash`'s (2b92ef4), revived at
/// pane level: a sibling above the glass, never its `contentView`, because the
/// glass view composites its content before its own material, so a fill handed
/// over that way would be blurred and vibrancy-shifted rather than laid over
/// the result. Colour and opacity are decided by the controller
/// (`ChromeMaterials.PaneWash.opacity`); this view only paints.
final class PaneGlassWashView: NSView {
    var colour: NSColor = .clear {
        didSet {
            guard colour != oldValue else { return }
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { false }

    override var canBecomeKeyView: Bool { false }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func draw(_: NSRect) {
        colour.setFill()
        bounds.fill()
    }
}
