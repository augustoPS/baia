import AppKit
import BaiaSettings
import PaneChrome

/// The one place a ``BaiaSettings/DesignOverrides/Chrome/Material`` becomes a
/// colour a glass surface can be tinted with.
///
/// ## What this re-activates, and what "today" means
///
/// **All four `MaterialSet` fill roles are dormant at HEAD.** Design v5's Task 2
/// (untinted glass) retired every live consumer: the palette's and the popover's
/// backings are left at `tintColor == nil`, the sidebar's old `fillSidebar` swap
/// was dropped, and the titlebar's glass is untinted too. The footer's backing
/// was a fifth site, carrying no tint and painting no fill, until that view was
/// deleted on 2026-08-13. Each of the four that remain still says so in
/// its own doc comment, with the measurement behind it — the glass-backdrop
/// spike found the tint and fill layers were the largest single term in the
/// bar's appearance and pinned it near mid-grey, defeating the material's own
/// adaptation, and untinted `regular` glass is the platform-correct default.
///
/// So pointing a surface at a fill through `DesignOverrides.Chrome.Surfaces` is
/// not a re-selection among live values. It **re-activates a dormant path**, and
/// the semantics are stated here rather than left to be inferred at five call
/// sites:
///
/// - **nil is today's rendering**, exactly: no fill, nothing tinted, the glass
///   left to adapt on its own. Every one of the five surfaces defaults to nil
///   and in Release can hold nothing else, so the whole family is absent from
///   what ships.
/// - **A set material means that surface composites the chosen fill over its
///   glass** — the pre-Task-2 arrangement, resurrected behind the override. The
///   literal it resolves to still follows the live appearance, since
///   `MaterialSet.dark` and `.light` carry different values under the same four
///   names, so a surface dialled to `.thick` stays correct when the theme flips.
///
/// **It is a probe for the owner's eye, not a committed default.** The
/// measurement above says untinted is right; what it cannot say is how each
/// individual surface looks with each fill on a real desktop, which is the
/// question the panel exists to let him answer by looking. Nothing here changes
/// the dormancy verdict — it makes it re-checkable.
///
/// **And on 2026-08-08 the owner re-checked the neighbouring question and came
/// down the same way.** The sidebar and titlebar carried hand-drawn washes over
/// their glass — not `MaterialSet` tints, but this app's own paint above the
/// material, the same category of layer Task 2 retired. He A/B'd the naked
/// material against them on his own desktop and ruled that naked native glass
/// wins, so both washes are gone from the code. Untinted, unwashed glass is now
/// the shipped look on every one of these surfaces rather than only the default
/// nobody had argued with.
enum SurfaceFill {
    /// The colour `material` names in `set`, or nil for the surface's own
    /// untinted glass.
    ///
    /// **The `switch` carries no `default`, deliberately.**
    /// `DesignOverrides.Chrome.Material` names exactly the four roles
    /// `ChromeMaterials` carries, and its own doc comment states the rule that
    /// keeps it to four: a role is added when a task first needs it, never ahead
    /// of one, because a role with no consumer is untested wiring. A `default`
    /// here would let a fifth case be added to that enum and reach a panel with
    /// no drawing-site mapping behind it, silently resolving to whatever the
    /// fallback happened to be. Without one, the same addition fails to compile
    /// at this line, and the four-case pin is enforced from both ends.
    static func colour(_ material: DesignOverrides.Chrome.Material?, in set: MaterialSet) -> NSColor? {
        guard let material else { return nil }
        let fill: RGBA = switch material {
        case .chrome: set.fillChrome
        case .sidebar: set.fillSidebar
        case .thick: set.fillThick
        case .menu: set.fillMenu
        }
        return NSColor(
            srgbRed: CGFloat(fill.rgb.red),
            green: CGFloat(fill.rgb.green),
            blue: CGFloat(fill.rgb.blue),
            alpha: CGFloat(fill.alpha)
        )
    }
}

/// The one place ``PaneChrome/NativeGlassStyle`` becomes the platform enum an
/// `NSGlassEffectView` takes.
///
/// Every glass surface in the app (the pane plane, the sidebar column and its
/// titlebar band, the palette, the approval popover, the sidebar's `git init`
/// pill) writes `style` through this on creation **and on every
/// `applyResolvedChrome` pass**, so a live switch between `liquidGlass` and
/// `sheer` reaches a backing that already exists. Before 2026-09-14 every site
/// hard-coded `.regular`, which is why the two styles rendered byte-identical;
/// see ``PaneChrome/NativeGlassStyle``.
///
/// **No `default`, for the same reason ``SurfaceFill/colour(_:in:)`` has
/// none:** a case added to the package enum must name its platform style here
/// or fail to compile, rather than silently falling back to regular glass.
extension NSGlassEffectView.Style {
    init(_ intent: NativeGlassStyle) {
        switch intent {
        case .regular: self = .regular
        case .clear: self = .clear
        }
    }
}
