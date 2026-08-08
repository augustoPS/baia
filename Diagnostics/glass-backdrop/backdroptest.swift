import AppKit
import PaneChrome

// The four-arm backdrop spike: what does an `NSGlassEffectView` over a pane's
// bottom 22 pt actually sample, and does any arrangement make it lens?
//
// Design v5 Plans 2-3 shipped glass that renders and cannot refract. The research
// report names two causes at once (§6.1 the colored-slab failure, §6.2 the
// empty-backdrop failure), and the shipped footer commits both: it tints the
// glass toward the theme background *and* sits beside the terminal with nothing
// under it. Two failures stacked means fixing either alone proves nothing, which
// is why the arms below vary tint and backdrop independently rather than
// together.
//
// This binary never becomes key and never activates. `NSApp.setActivationPolicy(
// .accessory)` plus `orderFrontRegardless()` puts a window on screen that the
// window server composites and the user's focus never leaves. That is the
// `SAFE_PROBES` standard (`pane-resize`, `theme-refresh`), and it is also the
// only honest way to run this: a focus steal mid-capture would land keystrokes in
// whatever the owner was typing into.
//
// The consequence for the inactive-state question is stated rather than worked
// around. See `ARMS` below and the README's "what inactive means here".

// MARK: - the controlled backdrop

/// A full-screen window of pure white beside pure black, ordered below the probe
/// window.
///
/// The desktop cannot be the backdrop. Glass adapts to what is behind it, so an
/// arm captured over the owner's wallpaper grades against a photograph that is
/// different on every machine and different again next week. Two flat halves at
/// the extremes make "bright" and "dark" mean the same thing on any machine, and
/// make a lensing edge visible as a *bend in the boundary between them*, which a
/// flat slab cannot produce and a blur can only soften.
///
/// The boundary is the measurement. A material that merely blurs leaves the
/// white/black edge straight and fuzzy; a material that refracts displaces it.
/// That is why the two halves meet at a *vertical seam* the bar crosses
/// left-to-right — one half on the left, the other on the right — rather than
/// being two separate captures over two flat fields.
final class BackdropWindow: NSWindow {
    static func make(covering frame: NSRect) -> BackdropWindow {
        let window = BackdropWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Below the probe window but above the desktop. `.normal - 1` rather than
        // `.desktop`, because a desktop-level window sits under the wallpaper's
        // own icon layer and the point of this window is to *replace* the
        // wallpaper as the thing being sampled.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        let view = BackdropView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = view
        return window
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }
}

final class BackdropView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_: NSRect) {
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height).fill()
        NSColor.black.setFill()
        NSRect(
            x: bounds.width / 2,
            y: 0,
            width: bounds.width - bounds.width / 2,
            height: bounds.height
        ).fill()

        // A mid-grey ruler across the seam. A displaced edge is easier to see
        // against a straight line than against nothing, and this line is what a
        // human compares between arms: glass that lenses bends it where the bar
        // crosses, glass that only blurs leaves it straight.
        NSColor(white: 0.5, alpha: 1).setFill()
        var y = bounds.height * 0.25
        while y < bounds.height {
            NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
            y += 24
        }
    }
}

// MARK: - the pane stand-in

/// The terminal surface stand-in: the theme background at the shipped 0.42 well
/// opacity, over a non-opaque window, so the backdrop shows through exactly as it
/// does under a real pane.
///
/// A plain fill rather than a live ghostty surface, and that substitution is
/// sound for arms 1, 2 and 4 for one reason only: what glass samples is the
/// composited pixels beneath its frame, and 0.42-alpha dark grey over the
/// backdrop composites to the same pixels whether a Metal layer or `NSColor` put
/// them there. It is *not* sound for the grid question, which is why arm 3's
/// measurement lives in a separate binary against a real PTY (`gridtest.swift`).
///
/// The one thing this cannot answer is whether `NSGlassEffectView` samples a
/// `CAMetalLayer` at all. Ghostty never found out: they place glass strictly
/// *below* the terminal view (`addSubview(effectView, positioned: .below,
/// relativeTo: terminalView)`) and clear the renderer's background, so the
/// question never arose upstream. `gridtest.swift` answers it here.
final class SurfaceStandIn: NSView {
    /// The shipped well opacity. `ac22f14` made 0.42 the default; a stand-in at
    /// any other alpha would grade the arms against a pane that does not ship.
    static let wellOpacity: CGFloat = 0.42

    /// This instance's well opacity, defaulting to the shipped value.
    ///
    /// Per-instance rather than the static alone, because the opacity sweep needs
    /// the *same* arm-3 arrangement rendered at several opacities in one run. Every
    /// arm above leaves this at ``wellOpacity``, so nothing that grades the shipped
    /// state can silently drift onto a value that does not ship.
    var opacity: CGFloat = SurfaceStandIn.wellOpacity

    var themeBackground: NSColor = .init(
        srgbRed: 18.0 / 255, green: 20.0 / 255, blue: 24.0 / 255, alpha: 1
    )

    override var isFlipped: Bool { true }

    override func draw(_: NSRect) {
        themeBackground.withAlphaComponent(opacity).setFill()
        bounds.fill()

        // Text at the same scale the terminal draws, because legibility through
        // the bar is half of what the captures are graded on and a blank well
        // cannot show it. Rows are drawn all the way to the bottom edge, so under
        // arm 3 the bar genuinely overlaps live-looking content rather than an
        // empty strip that would make any arrangement look fine.
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(white: 0.86, alpha: 1),
        ]
        var y: CGFloat = 8
        var row = 0
        while y < bounds.height {
            let line = row % 3 == 0
                ? "$ git status --porcelain=v2 --branch  # row \(row)"
                : "  MM Sources/PaneStatusBarView.swift          \(row)"
            line.draw(at: NSPoint(x: 8, y: y), withAttributes: attributes)
            y += font.boundingRectForFont.height + 3
            row += 1
        }
    }
}

// MARK: - the arms

enum Arm: String, CaseIterable {
    /// Arm 1. The current shipped state, reproduced rather than described, and
    /// reproduced in all three of its layers: `PaneStatusBarView.draw(_:)` fills
    /// the bar with `effectiveFillMaterial` (`fillChrome`, α 0.44),
    /// `PaneStatusGlassBacking` is an `NSGlassEffectView` with `style = .regular`
    /// and `tintColor` from the same `fillChrome` sitting *above* that fill, and
    /// the drawn segments are siblings above the glass rather than its
    /// `contentView`. The whole assembly sits in a 22 pt strip *below* the
    /// terminal view with nothing behind it but the window. Both failures at once,
    /// which is the point: it is the control every other arm is read against.
    ///
    /// Unfocused. `effectiveFillMaterial` steps to `fillThick` on the focused
    /// pane's bar, and this arm does not capture that state.
    case shippedTinted = "1-shipped-tinted"

    /// Arm 2. Resolution (A). The tint comes off; the bar still sits beside the
    /// surface, so its backdrop is the transparent window region and therefore
    /// the desktop. Costs no layout change at all.
    case untintedBesideSurface = "2-untinted-beside"

    /// Arm 3. Resolution (B). The tint comes off *and* the surface stand-in
    /// extends under the bar's full 22 pt, so glass samples well pixels rather
    /// than the desktop. The research report's preferred arrangement (§6.2).
    case untintedOverSurface = "3-untinted-over-surface"

    /// Arm 4. `NSVisualEffectView` at `.underWindowBackground`, the pre-26
    /// material, in the same 22 pt strip with the same absent tint. Not a
    /// candidate: the control that says how much of any difference above is glass
    /// rather than blur. If arms 2 and 3 are indistinguishable from this one,
    /// nothing in Plans 2-6 is buying refraction and the verdict has to say so.
    case visualEffectControl = "4-nsvisualeffect-control"

    var extendsSurfaceUnderBar: Bool { self == .untintedOverSurface }

    var isTinted: Bool { self == .shippedTinted }

    var usesGlass: Bool { self != .visualEffectControl }

    /// True for the one arm that must be built as `PaneStatusBarView` is built
    /// rather than as the report says a bar should be built: drawn `fillChrome`
    /// base, glass above it, content a sibling above the glass. See
    /// ``ProbeWindow/makeBar(arm:frame:)`` for why the other arms differ.
    var reproducesShippedHierarchy: Bool { self == .shippedTinted }
}

/// Arm 1's base layer: the fill `PaneStatusBarView.draw(_:)` paints across the
/// whole bar before any subview renders.
///
/// `effectiveFillMaterial` at the unfocused value, `MaterialSet.dark.fillChrome`
/// — read off `PaneChrome` rather than transcribed, same as the tint. The focused
/// value is `fillThick` (α 0.52 over `rgb(22,24,28)`); this probe captures the
/// unfocused bar only, which the README's arm table states rather than leaving to
/// be assumed.
final class ShippedBarView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func draw(_: NSRect) {
        let fill = MaterialSet.dark.fillChrome
        NSColor(
            srgbRed: CGFloat(fill.rgb.red),
            green: CGFloat(fill.rgb.green),
            blue: CGFloat(fill.rgb.blue),
            alpha: CGFloat(fill.alpha)
        ).setFill()
        bounds.fill()
    }
}

/// One pane-shaped window: a translucent surface stand-in over a non-opaque
/// window, and a 22 pt bar along the bottom rendered per arm.
final class ProbeWindow: NSWindow {
    let arm: Arm
    private let surface = SurfaceStandIn()
    private var bar: NSView?

    /// - Parameter wellOpacity: the surface stand-in's alpha. Defaults to the
    ///   shipped 0.42; the opacity sweep is the only caller that passes anything
    ///   else.
    init(arm: Arm, contentRect: NSRect, wellOpacity: CGFloat = SurfaceStandIn.wellOpacity) {
        self.arm = arm
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // The pane's own arrangement: a non-opaque window with a clear background,
        // which is what lets the 0.42 well composite over the desktop at all.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        // `isMovable = true` deliberately, against the 26.2 regression in §6.8:
        // glass inside a borderless *non-movable* transparent window stops
        // re-sampling as content moves beneath it (forums 810314), and the
        // documented partial workaround is exactly this flag. A probe that left it
        // false would be measuring the bug rather than the material, and would
        // report "glass does not lens" for a reason that has nothing to do with
        // the backdrop question this exists to answer.
        isMovable = true

        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]

        let content = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        content.wantsLayer = true
        contentView = content

        surface.opacity = wellOpacity

        let barHeight = PaneStatusBarMetrics.height

        // The one layout difference between (A) and (B), and the whole reason the
        // grid question exists: under arm 3 the surface view's frame runs to the
        // window's bottom edge and the bar overlaps its last 22 pt. Under every
        // other arm the surface stops where the bar begins.
        surface.frame = NSRect(
            x: 0,
            y: arm.extendsSurfaceUnderBar ? 0 : barHeight,
            width: contentRect.width,
            height: arm.extendsSurfaceUnderBar
                ? contentRect.height
                : contentRect.height - barHeight
        )
        surface.autoresizingMask = [.width, .height]
        content.addSubview(surface)

        let barFrame = NSRect(x: 0, y: 0, width: contentRect.width, height: barHeight)
        let bar = Self.makeBar(arm: arm, frame: barFrame)
        // Above the surface in every arm. Under arms 1, 2 and 4 they do not
        // overlap so the ordering is inert; under arm 3 it is load-bearing, and it
        // is the opposite of Ghostty's arrangement, which puts glass *below* the
        // terminal view. Theirs cannot lens in-window content by construction.
        content.addSubview(bar, positioned: .above, relativeTo: surface)
        self.bar = bar
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }

    /// The bar for one arm.
    ///
    /// The glass path mirrors `PaneStatusBarView.applyResolvedChrome()` and
    /// `updateGlassTint()` rather than paraphrasing them: `.regular` style,
    /// `cornerRadius = 0`, `tintColor` from `MaterialSet.fillChrome` when tinted.
    /// The values are read off `PaneChrome` at run time, not transcribed, so an
    /// arm cannot grade the shipped state against numbers that have moved.
    ///
    /// **Arm 1 and arms 2-4 are deliberately built differently, and the difference
    /// is the point.** Arm 1 has to be the *shipped* view hierarchy, warts
    /// included, or it is not a control. Arms 2-4 are the *future* arrangement the
    /// research report asks for. Reproducing the shipped one costs two things the
    /// first version of this probe got wrong:
    ///
    /// 1. **The drawn fill.** `PaneStatusBarView.draw(_:)` fills the entire bar
    ///    with `effectiveFillMaterial` — `fillChrome`, `rgb(18,20,24)` at α 0.44 —
    ///    as the view's own base layer, and `glassBacking` is a *subview* that
    ///    renders above it. The shipped bar therefore carries the tint **and** a
    ///    44%-alpha fill under the glass. Modelling only the tint made arm 1 a
    ///    lighter bar than the one that ships.
    /// 2. **Content above, not inside.** Shipped adds the glass
    ///    `positioned: .below, relativeTo: attentionWash`, so every drawn segment
    ///    is a *sibling above* the glass rather than its `contentView`. Assigning
    ///    `contentView` is what invites AppKit's legibility treatments, and the
    ///    shipped path never gets them. Arms 2-3 keep `contentView` because that
    ///    is what the report says the future arrangement should use; arm 1 must
    ///    not, or it grades the shipped bar against a treatment it does not have.
    static func makeBar(arm: Arm, frame: NSRect) -> NSView {
        let label = BarContentView(frame: NSRect(origin: .zero, size: frame.size))
        label.autoresizingMask = [.width, .height]

        guard arm.usesGlass else {
            let effect = NSVisualEffectView(frame: frame)
            effect.material = .underWindowBackground
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.autoresizingMask = [.width]
            effect.addSubview(label)
            return effect
        }

        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: frame.size))
        glass.style = .regular
        glass.cornerRadius = 0
        if arm.isTinted {
            // `MaterialSet.dark.fillChrome`, the exact value the shipped footer
            // writes onto its backing for an unfocused pane. Read from the package
            // rather than spelled here.
            // The identical conversion `PaneStatusBarView.nsColor(_:alpha:)`
            // performs: `RGB`'s components are already 0...1, so they go into
            // `srgbRed:` unscaled. Dividing by 255 here would have tinted the bar
            // with near-black at the shipped alpha and made arm 1 look like a
            // problem the shipped code does not have.
            let fill = MaterialSet.dark.fillChrome
            glass.tintColor = NSColor(
                srgbRed: CGFloat(fill.rgb.red),
                green: CGFloat(fill.rgb.green),
                blue: CGFloat(fill.rgb.blue),
                alpha: CGFloat(fill.alpha)
            )
        }
        glass.autoresizingMask = [.width]

        guard arm.reproducesShippedHierarchy else {
            // The future arrangement (arms 2 and 3): the label *is* the glass's
            // content, no fill underneath. Per the research report, this is what
            // Plan 4 should adopt.
            glass.contentView = label
            return glass
        }

        // The shipped arrangement (arm 1), rebuilt as three layers in the order
        // `PaneStatusBarView` renders them: the drawn `fillChrome` base, the glass
        // above it, the content above the glass.
        let shipped = ShippedBarView(frame: frame)
        shipped.autoresizingMask = [.width]
        shipped.addSubview(glass)
        shipped.addSubview(label, positioned: .above, relativeTo: glass)
        return shipped
    }
}

/// What the bar draws: the segments a real footer carries, at the real sizes, so
/// the captures grade legibility rather than an empty band.
final class BarContentView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func draw(_: NSRect) {
        let inset = PaneStatusBarMetrics.horizontalInset
        let baseline = PaneStatusBarMetrics.baselineFromTop

        // The attention capsule, drawn rather than glassed. Which of the two it
        // should be is the second question this probe carries (glass-in-container
        // versus drawn-on-glass), and drawing it here is the *baseline*: the
        // captures show what a drawn capsule on a bar's glass looks like, and the
        // container arm below shows the alternative in the same window.
        let capsule = PaneStatusBarMetrics.attentionCapsuleFrame(glyphWidth: 7)
        let capsuleRect = NSRect(
            x: capsule.x, y: capsule.y, width: capsule.width, height: capsule.height
        )
        NSColor(srgbRed: 0.92, green: 0.55, blue: 0.15, alpha: 0.9).setFill()
        NSBezierPath(
            roundedRect: capsuleRect,
            xRadius: capsuleRect.height / 2,
            yRadius: capsuleRect.height / 2
        ).fill()

        let glyph: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        "!".draw(at: NSPoint(x: capsuleRect.midX - 2.5, y: capsuleRect.minY + 2), withAttributes: glyph)

        let text: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(white: 0.92, alpha: 1),
        ]
        let x = inset + capsule.width + PaneStatusBarMetrics.capsuleGap
        let line = "baia · main ↑1↓2*3 · claude · ~/Projects/baia"
        line.draw(
            at: NSPoint(x: x, y: baseline - 11),
            withAttributes: text
        )
    }
}

// MARK: - the capsule question

/// A second window per arm-2/arm-3 arrangement that renders the capsule the other
/// way: a tinted `NSGlassEffectView` capsule inside an `NSGlassEffectContainerView`
/// with the bar's own glass.
///
/// This is the arrangement the HIG permits and hand-stacking does not. Session 219
/// forbids glass on glass, but a container's managed merge is one sampling pass
/// over both shapes rather than one sampling the other, which is why
/// `NSGlassEffectContainerView` exists at all. The captures are what say whether
/// the merge reads as a distinct capsule or dissolves into the bar.
final class CapsuleWindow: NSWindow {
    static func make(contentRect: NSRect, extendsUnderBar: Bool) -> CapsuleWindow {
        let window = CapsuleWindow(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]

        let content = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        content.wantsLayer = true
        window.contentView = content

        let barHeight = PaneStatusBarMetrics.height
        let surface = SurfaceStandIn()
        surface.frame = NSRect(
            x: 0,
            y: extendsUnderBar ? 0 : barHeight,
            width: contentRect.width,
            height: extendsUnderBar ? contentRect.height : contentRect.height - barHeight
        )
        content.addSubview(surface)

        // The bar's own untinted glass, and the capsule's tinted glass, as two
        // sibling `NSGlassEffectView`s inside one container. `spacing` is what
        // decides whether they meld; 0 keeps them as distinct shapes sharing one
        // sampling pass, which is the arrangement design v5 §3 wants (one
        // prominent element *on* the bar, not fused into it).
        let container = NSGlassEffectContainerView(
            frame: NSRect(x: 0, y: 0, width: contentRect.width, height: barHeight)
        )
        container.spacing = 0

        let row = NSView(frame: NSRect(x: 0, y: 0, width: contentRect.width, height: barHeight))
        row.autoresizingMask = [.width]

        let barGlass = NSGlassEffectView(
            frame: NSRect(x: 0, y: 0, width: contentRect.width, height: barHeight)
        )
        barGlass.style = .regular
        barGlass.cornerRadius = 0
        let barLabel = BarContentView(
            frame: NSRect(x: 0, y: 0, width: contentRect.width, height: barHeight)
        )
        barLabel.autoresizingMask = [.width]
        barGlass.contentView = barLabel
        barGlass.autoresizingMask = [.width]
        row.addSubview(barGlass)

        // The capsule, tinted, as the one prominent element. `cornerRadius = 999`
        // is Apple's own sample's spelling for a capsule.
        let capsuleFrame = PaneStatusBarMetrics.attentionCapsuleFrame(glyphWidth: 7)
        let capsuleGlass = NSGlassEffectView(frame: NSRect(
            x: capsuleFrame.x,
            y: capsuleFrame.y,
            width: capsuleFrame.width,
            height: capsuleFrame.height
        ))
        capsuleGlass.style = .regular
        capsuleGlass.cornerRadius = 999
        capsuleGlass.tintColor = NSColor(
            srgbRed: 0.92, green: 0.55, blue: 0.15, alpha: 0.9
        )
        let glyphView = CapsuleGlyphView(frame: NSRect(
            origin: .zero,
            size: NSSize(width: capsuleFrame.width, height: capsuleFrame.height)
        ))
        capsuleGlass.contentView = glyphView
        row.addSubview(capsuleGlass, positioned: .above, relativeTo: barGlass)

        container.contentView = row
        content.addSubview(container, positioned: .above, relativeTo: surface)
        return window
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }
}

final class CapsuleGlyphView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_: NSRect) {
        let glyph: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        "!".draw(at: NSPoint(x: bounds.midX - 2.5, y: bounds.midY - 6), withAttributes: glyph)
    }
}

// MARK: - the sidebar question

/// A sidebar-shaped window: a 220 pt column of untinted glass over the
/// transparent window region, beside a pane stand-in.
///
/// The third question. The plan wants to avoid the
/// `NSSplitViewItemAccessoryViewController` restructure (session restore and
/// focus rules both hang off the current controller shape), and the restructure
/// is only worth its blast radius if a sidebar with its own untinted glass over
/// the transparent region fails to read. This window is that arrangement, so the
/// verdict can name a capture rather than an intuition.
///
/// **The column straddles the seam, and the first version did not.** The window
/// was centred on the backdrop's white/black boundary, but the *column* is only
/// its leftmost 220 pt, so the glass being graded sat entirely over one half and
/// the capture measured a uniform `#141414`. Finding 3 says glass over the
/// desktop is exactly the arrangement that fails over a bright backdrop, and a
/// 220 pt column has far more area to go white than a 22 pt strip: a sidebar
/// verdict read off the dark half alone is the one number the question could not
/// use. The caller therefore positions the window so the *column's* midpoint
/// lands on the seam.
final class SidebarWindow: NSWindow {
    /// The column's width, exposed so the caller can place the window such that
    /// the column, not the window, straddles the backdrop seam.
    static let columnWidth: CGFloat = 220

    static func make(contentRect: NSRect) -> SidebarWindow {
        let window = SidebarWindow(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]

        let content = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        content.wantsLayer = true
        window.contentView = content

        let sidebarWidth = Self.columnWidth

        // The pane beside it, at the shipped well opacity, so the capture shows
        // the sidebar's glass against both the desktop (its own backdrop) and the
        // well (its neighbour) in one frame.
        let surface = SurfaceStandIn()
        surface.frame = NSRect(
            x: sidebarWidth,
            y: 0,
            width: contentRect.width - sidebarWidth,
            height: contentRect.height
        )
        content.addSubview(surface)

        let glass = NSGlassEffectView(frame: NSRect(
            x: 0, y: 0, width: sidebarWidth, height: contentRect.height
        ))
        glass.style = .regular
        glass.cornerRadius = 0
        glass.contentView = SidebarContentView(frame: NSRect(
            x: 0, y: 0, width: sidebarWidth, height: contentRect.height
        ))
        content.addSubview(glass, positioned: .above, relativeTo: surface)
        return window
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }
}

final class SidebarContentView: NSView {
    override var isFlipped: Bool { true }

    /// The theme the shipping sidebar draws with, read off the package rather
    /// than transcribed.
    ///
    /// **Finding 6 originally graded a stand-in and this is the correction.**
    /// The header was drawn `NSColor(white: 0.62)` — `#9e9e9e` — and the README
    /// reported that as "the CHANGED header `#9e9e9e`". The shipping header
    /// never drew that colour: it draws `theme.inkFaint`, which on
    /// `.darkPastel` is `#898989`, darker than the stand-in and therefore
    /// *worse* than the number the finding published. The verdict the finding
    /// reached (the header fails over the bright half and needs lightening)
    /// survives that correction and is strengthened by it; the absolute did
    /// not. Reading the ink off `PaneChrome` is what stops the arm claiming to
    /// reproduce a surface it was only approximating — the same rule the four
    /// render arms already follow for `PaneStatusBarMetrics.height`.
    private let theme = PaneTheme.darkPastel

    /// The backdrop the shipping header grades itself against under glass,
    /// spelled the same way `SurfaceTitleView` spells it: finding 6's brightest
    /// measured bright-half sample.
    private static let measuredBrightGlass = RGB.eightBit(0x4B, 0x4B, 0x4B)

    private func nsColor(_ rgb: RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green),
                blue: CGFloat(rgb.blue), alpha: 1)
    }

    override func draw(_: NSRect) {
        // What the header draws today: `sectionHeaderInk` repaired against the
        // glass above. The unrepaired tier is drawn beside it as the control,
        // so one capture carries both the bug and the fix and the comparison
        // cannot drift between runs.
        let header: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: nsColor(theme.sectionHeaderInk(on: Self.measuredBrightGlass)),
        ]
        let headerBefore: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: nsColor(theme.inkFaint),
        ]
        let row: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: NSColor(white: 0.90, alpha: 1),
        ]
        "CHANGED".draw(at: NSPoint(x: 12, y: 16), withAttributes: header)
        "CHANGED".draw(at: NSPoint(x: 96, y: 16), withAttributes: headerBefore)
        var y: CGFloat = 40
        for name in [
            "Sources/PaneStatusBarView.swift",
            "Sources/PaneTreeController.swift",
            "Packages/PaneChrome/ChromeMaterials.swift",
            "Diagnostics/glass-backdrop/run.sh",
            "project.yml",
        ] {
            name.draw(at: NSPoint(x: 12, y: y), withAttributes: row)
            y += 22
        }
    }
}

// MARK: - capture

/// Runs `screencapture` and reports whether it wrote the file.
func runScreencapture(_ arguments: [String], to path: String) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x"] + arguments + [path]
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        FileHandle.standardError.write("capture failed to launch: \(error)\n".data(using: .utf8)!)
        return false
    }
    return task.terminationStatus == 0 && FileManager.default.fileExists(atPath: path)
}

/// Captures one window twice: `-l` as the measured file, `-R` beside it as the
/// composite cross-check.
///
/// **Both, because neither alone is trustworthy, and finding that out cost this
/// probe its arm-3 number.**
///
/// `-l <windowid>` returns the window's *own backing store*: the pixels that
/// window drew, alpha intact, before the window server composited anything under
/// it. For an opaque window that is the same picture as the screen and the
/// distinction never surfaces. These windows are `isOpaque = false` over a 0.42
/// well, so the surface band came back `(19, 19, 24, α=107)` on *both* halves of a
/// white-against-black backdrop: the unpremultiplied theme colour at the well's
/// own alpha, carrying no trace of what it sits over. Anything read through the
/// well was the stand-in's paint rather than the composite an owner sees. The
/// glass views were unaffected — their bands are α=255 and do carry the split,
/// which is why the adaptation findings survived — but arm 3's whole claim is
/// about what sits *under* glass, so arm 3 was the casualty.
///
/// `-R <rect>` grabs the screen and does composite correctly. It also applies the
/// **display's current brightness and EDR tone response**, which `-l` does not.
/// Measured on this machine at the same instant, over the same borderless
/// full-screen window painted pure `NSColor.white` beside pure `NSColor.black`:
///
/// ```
/// -l   white half #ffffff   black half #000000
/// -R   white half #373737   black half #111111
/// ```
///
/// `-R` crushes a pure-white backdrop to 21% luminance. Every absolute number
/// read off an `-R` file is therefore a function of the panel's brightness slider
/// and the ambient-light sensor at capture time, and is neither reproducible
/// tomorrow nor comparable across machines. A probe whose verdict moves with the
/// brightness key is not a measurement.
///
/// So: `-l` is the file the README's numbers come from, and the well is flattened
/// in *analysis* — see ``flatten(rgba:over:)`` for the arithmetic and
/// ``selfTestFlatten()`` for the case that pins it — against the backdrop this
/// probe controls and therefore knows exactly. `-R` is written to
/// `<name>-screen.png` as the cross-check that the two methods agree on hue and
/// ordering, never as a source of absolute values.
///
/// `-o` stays absent from the `-R` arm: it suppresses the windows behind, and the
/// backdrop behind is the thing being sampled.
func capture(window: NSWindow, to path: String) -> Bool {
    guard runScreencapture(["-l", String(window.windowNumber)], to: path) else {
        return false
    }

    // `screencapture -R` takes *global display* coordinates: origin at the
    // top-left of the main display, y growing downward. AppKit hands out
    // bottom-left origins. Flipping against the main screen's frame (not the
    // visible frame, which excludes the menu bar and would shift every capture
    // down by its height) is the conversion. The rect is the window's exact
    // frame, so no shadow margin enters the crop.
    //
    // **Each edge is rounded, and the size derived from the rounded edges**, so
    // the `-R` files are at least consistent with each other (all 642 px tall for
    // a 320 pt window at 2x). Rounding origin and size independently let that
    // drift per-window.
    //
    // It does **not** make `-R` agree with `-l`, and it cannot. `screencapture -l`
    // sizes its output to the window's *rendered* bounds, which include whatever
    // the window's own layers overdraw: arms 1 and both capsule windows come back
    // 642 px tall while arms 2-4 come back 640, from the same 320 pt frame. The
    // rect passed here has no influence on that. The two routes therefore land on
    // different pixel grids for some arms, and the README documents a separate
    // sample band per route rather than pretending one band fits both.
    if let main = NSScreen.screens.first {
        let frame = window.frame
        let left = frame.minX.rounded()
        let right = frame.maxX.rounded()
        let top = (main.frame.maxY - frame.maxY).rounded()
        let bottom = (main.frame.maxY - frame.minY).rounded()
        let rect = "\(Int(left)),\(Int(top)),\(Int(right - left)),\(Int(bottom - top))"
        let screenPath = path.replacingOccurrences(of: ".png", with: "-screen.png")
        // Best-effort: the cross-check is diagnostic, and losing it must not fail
        // a run whose measured `-l` file was written.
        _ = runScreencapture(["-R", rect], to: screenPath)
    }
    return true
}

/// Composites an unpremultiplied RGBA sample over a known opaque grey.
///
/// The source-over arithmetic, per channel:
///
/// ```
/// out = rgb * alpha + backdrop * (1 - alpha)
/// ```
///
/// This is what turns a `-l` capture's well band into the pixel an owner sees.
/// `-l` returns the window's own buffer, so the 0.42 well arrives as the theme
/// colour at its own alpha with no trace of what it sits over: `(19, 19, 24,
/// α=107)` on *both* halves of the backdrop. Because this probe *controls* the
/// backdrop — pure white on one side of the seam, pure black on the other — the
/// missing operand is known exactly rather than estimated, and the composite can
/// be finished in analysis.
///
/// Kept as a function the reader can inspect and the binary can check, rather than
/// as arithmetic performed once by hand off-screen: the arm-3 well number is load-
/// bearing for the verdict, and a hand-computed figure in a README is not
/// checkable. `Diagnostics/lib/pixel.py` performs the same operation when it reads
/// the captures; this is the copy that gets exercised on every run.
func flatten(rgba: (Int, Int, Int, Int), over backdrop: Int) -> (Int, Int, Int) {
    let alpha = Double(rgba.3) / 255
    func channel(_ value: Int) -> Int {
        Int((Double(value) * alpha + Double(backdrop) * (1 - alpha)).rounded())
    }
    return (channel(rgba.0), channel(rgba.1), channel(rgba.2))
}

/// Pins ``flatten(rgba:over:)`` to the two values the README quotes.
///
/// The well band this probe measured under `-l` was `(19, 19, 24, α=107)`, and the
/// adversarial review predicted independently that it must composite to `≈#9b9c9e`
/// over the white half and `≈#08080a` over the black half. Both are reproduced
/// here, so a future edit that breaks the arithmetic fails the run rather than
/// quietly moving a number the verdict rests on.
func selfTestFlatten() -> Bool {
    let well = (19, 19, 24, 107)
    let overWhite = flatten(rgba: well, over: 255)
    let overBlack = flatten(rgba: well, over: 0)
    guard overWhite == (156, 156, 158) else {
        FileHandle.standardError.write(
            "flatten self-test failed over white: \(overWhite)\n".data(using: .utf8)!
        )
        return false
    }
    guard overBlack == (8, 8, 10) else {
        FileHandle.standardError.write(
            "flatten self-test failed over black: \(overBlack)\n".data(using: .utf8)!
        )
        return false
    }
    return true
}

/// Reads one pixel out of a capture, as premultiplied-free sRGB bytes.
///
/// `NSImage`/`CGImage` rather than a hand-rolled PNG decoder: this is only ever
/// asked whether two regions of a *freshly written* capture differ, so decoding
/// through the system is both correct and shorter. `Diagnostics/lib/pixel.py`
/// stays the tool the README's numbers come from — it has no dependency on this
/// process being alive, and it is what a reader can re-run against the files.
func samplePixel(_ path: String, fx: Double, fy: Double) -> (Int, Int, Int)? {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return nil }
    let x = min(max(Int(Double(cg.width) * fx), 0), cg.width - 1)
    let y = min(max(Int(Double(cg.height) * fy), 0), cg.height - 1)

    var pixel = [UInt8](repeating: 0, count: 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: &pixel,
              width: 1,
              height: 1,
              bitsPerComponent: 8,
              bytesPerRow: 4,
              space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }
    context.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
    return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
}

/// True when two horizontal samples differ enough that the material between them
/// must have sampled a backdrop that differs there.
///
/// The threshold is deliberately loose. It is not measuring anything — the README
/// numbers come from `pixel.py` — it only has to separate "the material rendered a
/// gradient across the seam" from "the material is a flat slab", and those two are
/// tens of units apart, not units apart.
///
/// **Checks the `-R` companion when there is one, and that is not a detail.** The
/// two capture routes see different materials:
///
/// - `NSGlassEffectView` composites its sampled backdrop into *its own window's*
///   backing store, so `-l` sees it. Arms 1-3 and both capsule windows are read
///   correctly from the `-l` file.
/// - `NSVisualEffectView` at `.behindWindow` (arm 4) and the sidebar's glass
///   composite at the *window-server* level. Their `-l` files are flat slabs no
///   matter how long the probe waits — arm 4 and the sidebar both sat out six
///   escalating settles unchanged — and only the screen grab carries their
///   adaptation.
///
/// So a settle check against `-l` alone would loop forever on exactly the two arms
/// that need the screen grab. Preferring the `-R` file where it exists asks each
/// material through the route that can actually see it.
func sampledAcross(_ path: String, left: Double, right: Double, y: Double) -> Bool {
    let screenPath = path.replacingOccurrences(of: ".png", with: "-screen.png")
    let readable = FileManager.default.fileExists(atPath: screenPath) ? screenPath : path
    guard let l = samplePixel(readable, fx: left, fy: y),
          let r = samplePixel(readable, fx: right, fy: y) else { return false }
    let delta = abs(l.0 - r.0) + abs(l.1 - r.1) + abs(l.2 - r.2)
    return delta > 12
}

/// Runs the run loop for a fixed interval without blocking the window server.
///
/// `Thread.sleep` would stop the run loop, and a glass view that has not had a
/// display pass captures as an unsampled slab: two runs during this probe's
/// development produced flat grey bars for exactly that reason. The window has to
/// be composited before it can be photographed.
func settle(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

// MARK: - main

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSTemporaryDirectory() + "baia-glass-backdrop"

try? FileManager.default.createDirectory(
    atPath: outputDirectory, withIntermediateDirectories: true
)

let app = NSApplication.shared
// `.accessory`, never `.regular`. This is the `SAFE_PROBES` standard: an
// accessory app has no Dock tile, no menu bar, and cannot become active, so the
// probe's windows are composited without the owner's focus ever moving. Every
// window below is `orderFrontRegardless()`, never `makeKeyAndOrderFront`.
app.setActivationPolicy(.accessory)

guard let screen = NSScreen.main else {
    FileHandle.standardError.write("no screen\n".data(using: .utf8)!)
    exit(1)
}

let screenFrame = screen.frame
let backdrop = BackdropWindow.make(covering: screenFrame)
backdrop.orderFrontRegardless()

// The pane is centred on the white/black seam, so every capture carries the
// bright half and the dark half of the backdrop in one frame. Two captures over
// two flat fields would answer "is it legible over white" and "is it legible over
// black" separately; one capture across the seam additionally answers "does the
// edge bend", which is the refraction question and the only one the flat-field
// pair cannot reach.
let paneWidth: CGFloat = 720
let paneHeight: CGFloat = 320
let paneFrame = NSRect(
    x: screenFrame.midX - paneWidth / 2,
    y: screenFrame.midY - paneHeight / 2,
    width: paneWidth,
    height: paneHeight
)

settle(0.6)

var failures = 0

// The flatten arithmetic before any capture is taken. It costs nothing, and the
// arm-3 well figure the verdict rests on is derived through it.
if !selfTestFlatten() {
    print("FAILED flatten self-test")
    failures += 1
}

/// How long a window is given to compose before it is photographed.
///
/// **A fixed budget is not enough and the sidebar arm proved it.** `settle(0.8)`
/// was sufficient for the four 720x320 pane arms — their glass sampled the
/// backdrop and the captures carry the white/black split — but the 920x440
/// sidebar window captured as a flat `#141414` slab across the entire column: the
/// glass had rendered its content (the CHANGED header and file rows are in the
/// file) without having sampled anything behind it yet. A larger glass view needs
/// more time, and a probe that hardcodes one budget reports "the sidebar reads
/// dark" when what it measured was an unfinished frame.
///
/// The settle is therefore retried against a *check on the pixels* rather than a
/// clock. See ``recordSampled(_:_:check:)``.
let baseSettle: TimeInterval = 0.8

func record(_ window: NSWindow, _ name: String) {
    window.orderFrontRegardless()
    settle(baseSettle)
    let path = outputDirectory + "/" + name + ".png"
    if capture(window: window, to: path) {
        print("captured \(name).png")
    } else {
        print("CAPTURE FAILED \(name)")
        failures += 1
    }
}

/// Captures a window, re-settling and re-capturing until the written file shows
/// the glass has actually sampled its backdrop.
///
/// `check` reads the capture and answers "did this glass sample?". The two halves
/// of the controlled backdrop are what make that answerable without a tolerance
/// argument: glass that sampled carries a *difference* between its bright-half
/// and dark-half pixels, and glass that did not is flat to within a rounding
/// error. A flat slab is the exact failure mode the run-loop comment at
/// ``settle(_:)`` already documents; this is that check applied to the file
/// rather than to the wall clock.
func recordSampled(
    _ window: NSWindow,
    _ name: String,
    attempts: Int = 6,
    check: (String) -> Bool
) {
    window.orderFrontRegardless()
    let path = outputDirectory + "/" + name + ".png"
    for attempt in 1 ... attempts {
        // Each retry waits longer than the last: the first failure is usually a
        // frame away, and a run that needs the sixth is telling us something a
        // constant would have hidden.
        settle(baseSettle * Double(attempt))
        guard capture(window: window, to: path) else {
            print("CAPTURE FAILED \(name)")
            failures += 1
            return
        }
        if check(path) {
            print("captured \(name).png\(attempt > 1 ? " (settled on attempt \(attempt))" : "")")
            return
        }
    }
    print("CAPTURE UNSAMPLED \(name) — glass did not sample its backdrop in \(attempts) attempts")
    failures += 1
}

// The bar band, as a fraction of the pane window's height: the bottom 22 pt of
// 320. Sampled either side of the seam, which is the window's midline.
let barBandY = 1.0 - Double(PaneStatusBarMetrics.height) / Double(paneHeight) / 2

for arm in Arm.allCases {
    let window = ProbeWindow(arm: arm, contentRect: paneFrame)
    recordSampled(window, "arm-" + arm.rawValue) {
        sampledAcross($0, left: 0.2, right: 0.8, y: barBandY)
    }
    window.orderOut(nil)
}

// The capsule question, in both candidate backdrop arrangements, because the
// answer may depend on which one wins: a container merge over the desktop and a
// container merge over well pixels are not the same sampling problem.
let capsuleBeside = CapsuleWindow.make(contentRect: paneFrame, extendsUnderBar: false)
recordSampled(capsuleBeside, "capsule-container-beside") {
    sampledAcross($0, left: 0.2, right: 0.8, y: barBandY)
}
capsuleBeside.orderOut(nil)

let capsuleOver = CapsuleWindow.make(contentRect: paneFrame, extendsUnderBar: true)
recordSampled(capsuleOver, "capsule-container-over-surface") {
    sampledAcross($0, left: 0.2, right: 0.8, y: barBandY)
}
capsuleOver.orderOut(nil)

// The sidebar question.
//
// Positioned so the *column* straddles the seam rather than the window. The
// column is the window's leftmost `SidebarWindow.columnWidth`, so putting the
// window's left edge half a column-width left of the seam puts the column's
// midpoint on it, and the capture carries the sidebar's glass over the bright
// half and the dark half in one frame. Centring the window instead (the first
// version) left the entire column on one half.
let sidebarWidth: CGFloat = 920
let sidebarHeight: CGFloat = 440
let sidebarFrame = NSRect(
    x: screenFrame.midX - SidebarWindow.columnWidth / 2,
    y: screenFrame.midY - sidebarHeight / 2,
    width: sidebarWidth,
    height: sidebarHeight
)
let sidebar = SidebarWindow.make(contentRect: sidebarFrame)
// The seam sits at `columnWidth / 2` into a `sidebarWidth`-wide window, so these
// two fractions land inside the column on either side of it. This is the arm the
// sampled check was written for: at a flat `settle(0.8)` it captured as an
// unsampled `#141414` slab across the whole column.
let sidebarSeam = Double(SidebarWindow.columnWidth / 2 / sidebarWidth)
recordSampled(sidebar, "sidebar-untinted-glass") {
    sampledAcross($0, left: sidebarSeam * 0.35, right: sidebarSeam * 1.65, y: 0.5)
}
sidebar.orderOut(nil)

// The well-opacity sweep for arm 3.
//
// (B) puts the well between the glass and the desktop, so the well's opacity is
// the knob that decides how much desktop reaches the bar. The shipped 0.42 is one
// point on that curve and the owner has to pick the shipped value from the whole
// curve, which means the curve has to exist as measurement rather than as
// intuition.
//
// Arm 3's arrangement exactly — untinted `regular` glass over the surface's bottom
// 22 pt — rendered at each opacity. Only the stand-in's alpha changes between
// them, so a difference between two captures is the opacity and nothing else.
//
// The cost the numbers do not carry: every step darkens the well over the desktop.
// The pane reads less like a window onto the wallpaper and more like a panel, which
// is a move away from the ghostty-parity look. That is the tradeoff the owner is
// weighing, and the probe can only supply one side of it.
let sweepOpacities: [CGFloat] = [0.42, 0.46, 0.50, 0.55, 0.60]
for opacity in sweepOpacities {
    let name = String(format: "sweep-well-%03d", Int((opacity * 100).rounded()))
    let window = ProbeWindow(
        arm: .untintedOverSurface, contentRect: paneFrame, wellOpacity: opacity
    )
    recordSampled(window, name) {
        sampledAcross($0, left: 0.2, right: 0.8, y: barBandY)
    }
    window.orderOut(nil)
}

// The inactive-state pair for arms 2 and 3.
//
// Read the README before reading these two files. This process is `.accessory`
// and its windows are never key, so *every* capture above is already of a
// non-key window: the "inactive" pair below is not a second state, it is the
// same state captured while a foreign window is additionally frontmost. What
// that pair can prove is narrow and worth having anyway: whether glass in a
// never-key accessory window degrades further when another application is
// active. What it cannot prove is the shipped app's key-to-non-key transition,
// which is the transition Ghostty's discussion 10170 reports as jarring and
// which needs a probe that owns a key window.
for arm in [Arm.untintedBesideSurface, Arm.untintedOverSurface] {
    let window = ProbeWindow(arm: arm, contentRect: paneFrame)
    window.orderFrontRegardless()
    settle(0.5)
    // Nothing is activated and nothing is made key. The wait is what lets any
    // deactivation the window server applies to a non-key window settle.
    settle(1.0)
    let path = outputDirectory + "/inactive-" + arm.rawValue + ".png"
    if capture(window: window, to: path) {
        print("captured inactive-\(arm.rawValue).png")
    } else {
        print("CAPTURE FAILED inactive-\(arm.rawValue)")
        failures += 1
    }
    window.orderOut(nil)
}

backdrop.orderOut(nil)

print("")
print("output: \(outputDirectory)")
if failures > 0 {
    print("FAILED \(failures) capture(s)")
    exit(1)
}
print("PASS all captures written")
