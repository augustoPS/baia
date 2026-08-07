import Foundation

/// A colour in sRGB with an alpha channel, on 0...1 for every component.
///
/// ``RGB`` deliberately carries no alpha, because the status bar it was built
/// for is opaque over the terminal's own background. The v5 glass materials
/// are the opposite case by construction (design/vitreous/CLAUDE.md rule 1,
/// "nothing is opaque"): every fill in `materials.css` is a translucent
/// `rgba()`, so the type that carries them needs the fourth channel ``RGB``
/// leaves out rather than bolting alpha onto it and giving every existing
/// opaque-bar call site a component it must ignore.
public struct RGBA: Sendable, Equatable {
    public var rgb: RGB
    public var alpha: Double

    /// `red`/`green`/`blue` on 0...255, the scale `materials.css` spells its
    /// `rgba()` literals in, so a token like `rgba(18, 20, 24, 0.44)` transcribes
    /// to `RGBA(red: 18, green: 20, blue: 24, alpha: 0.44)` with no arithmetic at
    /// the call site to get wrong. `alpha` stays on 0...1, matching the fourth
    /// argument of CSS's own `rgba()`.
    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.rgb = .eightBit(Int(red), Int(green), Int(blue))
        self.alpha = min(max(0, alpha), 1)
    }

    public init(rgb: RGB, alpha: Double) {
        self.rgb = rgb
        self.alpha = min(max(0, alpha), 1)
    }

    /// This colour flattened onto an opaque backdrop, standard alpha-over-opaque
    /// compositing (`RGB.blended(with:fraction:)` already is that formula: linear
    /// interpolation towards `self` by `alpha` is exactly `backdrop * (1-alpha) +
    /// self * alpha`).
    ///
    /// General alpha-over-opaque compositing, kept and tested independently of
    /// any caller. **No call site uses this for glass ink repair any more.**
    ///
    /// Task 4 built this as an approximation for a glass fill's text contrast:
    /// flatten the material onto `theme.background` (the nearest surface the
    /// package can compute without AppKit) and grade ink against the result,
    /// the same way `barBackground` grades ink for the flat bar. Task 2's
    /// glass-backdrop spike (`Diagnostics/glass-backdrop/README.md`) measured
    /// that approximation against the real thing and found it wrong by more
    /// than a factor of four in the direction that matters: ink graded against
    /// a flattened well swatch scored 2.09:1 over a bright desktop, while the
    /// same ink on the actual glass measured 9.49:1. Real vitreous glass
    /// supplies its own legibility through the compositor's own vibrancy and
    /// adaptation, which a flattened swatch cannot see and actively fights.
    /// Owner decision, following that measurement: glass paths take theme ink
    /// ungraded, and the repair chain (`PaneTheme.color(for:focused:on:)`
    /// grading against a fill) now applies to the flat/Reduce-Transparency
    /// rendering only.
    public func composited(over backdrop: RGB) -> RGB {
        backdrop.blended(with: rgb, fraction: alpha)
    }
}

/// One CSS `box-shadow` value with up to two layers, spelled the way
/// `materials.css` pairs a drop shadow with a hairline ring (`--shadow-window`)
/// or a drop shadow with a tighter secondary drop (`--shadow-popover`).
///
/// CSS's `box-shadow` takes an arbitrary list of layers; this type only names
/// the two shapes this package's tokens actually use rather than modelling the
/// general syntax, the same restraint ``PaneStatusBarMetrics`` takes with
/// geometry it will never need to generalise. A shadow this package starts
/// using with a third layer earns its own case rather than a variadic array
/// every existing call site would have to thread `nil` through.
public struct ChromeShadow: Sendable, Equatable {
    /// The primary drop shadow's vertical offset, in points. `--shadow-window`
    /// and `--shadow-popover` both spell a pure vertical offset (no horizontal
    /// component), so there is no `dropOffsetX`.
    public var dropOffsetY: Double
    public var dropBlur: Double
    public var dropAlpha: Double

    /// The second layer. For `--shadow-window` this is a 0.5px hairline ring
    /// (`0 0 0 0.5px rgba(...)`, no offset or blur, spread only); for
    /// `--shadow-popover` it is a second, tighter drop shadow. Only one of the
    /// two pairs is populated per instance; the other stays 0, which a reader
    /// tells apart from "set to zero on purpose" by which accessor the call
    /// site names, the same way ``PaneTheme`` leans on its property names
    /// rather than a discriminated payload.
    public var ringSpread: Double
    public var ringAlpha: Double
    public var secondaryOffsetY: Double
    public var secondaryBlur: Double
    public var secondaryAlpha: Double

    /// `--shadow-window`'s shape: a drop shadow plus a spread-only hairline
    /// ring, no offset or blur on the second layer.
    public static func window(
        dropOffsetY: Double, dropBlur: Double, dropAlpha: Double,
        ringSpread: Double, ringAlpha: Double
    ) -> ChromeShadow {
        ChromeShadow(
            dropOffsetY: dropOffsetY, dropBlur: dropBlur, dropAlpha: dropAlpha,
            ringSpread: ringSpread, ringAlpha: ringAlpha,
            secondaryOffsetY: 0, secondaryBlur: 0, secondaryAlpha: 0
        )
    }

    /// `--shadow-popover`'s shape: two stacked drop shadows, no ring.
    public static func popover(
        dropOffsetY: Double, dropBlur: Double, dropAlpha: Double,
        secondaryOffsetY: Double, secondaryBlur: Double, secondaryAlpha: Double
    ) -> ChromeShadow {
        ChromeShadow(
            dropOffsetY: dropOffsetY, dropBlur: dropBlur, dropAlpha: dropAlpha,
            ringSpread: 0, ringAlpha: 0,
            secondaryOffsetY: secondaryOffsetY, secondaryBlur: secondaryBlur, secondaryAlpha: secondaryAlpha
        )
    }
}

/// The vitreous v5 material tokens this app draws, transcribed as tested
/// constants from `design/vitreous/tokens/materials.css` and `appearance.css`.
///
/// Every literal below carries the CSS custom property it pins in a comment,
/// and ``ChromeMaterialsTests`` asserts each one against the value the token
/// file spells. That pairing is the same argument the ghostty unbind table
/// makes for its own literal transcription: the numbers only ever move as a
/// reviewed diff against a failing test, never as a silent hand-edit that
/// drifts from the CSS the design system actually ships.
///
/// This type only carries the roles the app currently draws with (chrome,
/// sidebar, thick, menu; the window and popover shadows; the rim alphas; the
/// two motion durations the lift uses). `materials.css` and `appearance.css`
/// define more roles (`ultraThin`, `thin`, `regular`, `hud`, `--shadow-control`,
/// `--shadow-raised`, `--shadow-sheet`) that nothing in this app resolves to
/// yet; adding a role here without a consumer is the same untested-wiring
/// hazard `focusAccent` sat in for a week (see `ChromeStyle.swift`), so a role
/// is added when a task first needs it, not ahead of one.
public enum ChromeMaterials {
    /// `materials.css`'s `:root` scope, which is the dark appearance (base,
    /// undeclared `[data-appearance]` defaults to dark per `color.css`).
    public enum Dark {
        /// `--mat-fill-chrome: rgba(18, 20, 24, 0.44)`. Titlebar, toolbar,
        /// status bar in `materials.css`, the vitreous spec of record.
        ///
        /// **Retired from every live draw path as of Task 2 (untinted glass).**
        /// The footer's `NSGlassEffectView` draws no tint and its own
        /// `draw(_:)` draws no fill on the glass path; nothing in `Sources/`
        /// reads this constant for a live fill or tint any more. Kept as the
        /// tested transcription of the CSS token and as the source for any
        /// future flat/Reduce-Transparency vitreous rendering — it is not
        /// itself that rendering, since flat's own fill is `theme.barBackground`,
        /// not this token.
        public static let fillChrome = RGBA(red: 18, green: 20, blue: 24, alpha: 0.44)

        /// `--mat-fill-sidebar: rgba(18, 20, 24, 0.34)`. Source lists in
        /// `materials.css`, the vitreous spec of record.
        ///
        /// **Retired from every live draw path as of Task 2 (untinted glass).**
        /// The sidebar was never backed by an `NSGlassEffectView`; its glass
        /// case in `FilesSurface`/`ChangesSurface` used to swap this in as the
        /// scroll view's flat `backgroundColor`, and Task 2 dropped that swap
        /// (both cases now paint `theme.background`). Kept as the tested
        /// transcription of the CSS token, not as anything a live path draws.
        public static let fillSidebar = RGBA(red: 18, green: 20, blue: 24, alpha: 0.34)

        /// `--mat-fill-thick: rgba(22, 24, 28, 0.52)`. Sheets, alerts in
        /// `materials.css`, the vitreous spec of record.
        ///
        /// **Retired from every live draw path as of Task 2 (untinted glass).**
        /// This was the footer's focused-pane step, read through
        /// `PaneStatusBarView.effectiveFillMaterial`; Task 2 deleted that
        /// property along with the tint and fill it fed, since an untinted
        /// glass backing has no fill to step. Kept as the tested transcription
        /// of the CSS token and as the source for any future flat/
        /// Reduce-Transparency vitreous rendering that wants a "thick" tier.
        public static let fillThick = RGBA(red: 22, green: 24, blue: 28, alpha: 0.52)

        /// `--mat-fill-menu: rgba(30, 32, 37, 0.58)`. Menus, popovers in
        /// `materials.css`, the vitreous spec of record.
        ///
        /// **Retired from every live draw path as of Task 2 (untinted glass).**
        /// This tinted the palette's and the popover's `NSGlassEffectView`
        /// backings and was drawn a second time as each palette band's own
        /// fill; Task 2 dropped both uses. Kept as the tested transcription of
        /// the CSS token and as the source for any future flat/
        /// Reduce-Transparency vitreous rendering — it is not itself that
        /// rendering, since flat's own fill is `theme.panelBackground`.
        public static let fillMenu = RGBA(red: 30, green: 32, blue: 37, alpha: 0.58)

        /// `--lens-rim`'s bright leading edge, `var(--rim-top)`. `color.css`
        /// declares the dark `--rim-top` at 42% white per README.md's lensing
        /// section ("a bright top rim (`inset 0 0.5px 0` at 42% white)").
        public static let rimTopAlpha: Double = 0.42

        /// `--lens-rim`'s dark trailing edge, `var(--rim-bottom)`, 38% black
        /// per the same README passage.
        public static let rimBottomAlpha: Double = 0.38

        /// `--shadow-window: 0 26px 70px rgba(0,0,0,.62), 0 0 0 0.5px rgba(255,255,255,.14)`
        public static let shadowWindow = ChromeShadow.window(
            dropOffsetY: 26, dropBlur: 70, dropAlpha: 0.62,
            ringSpread: 0.5, ringAlpha: 0.14
        )

        /// `--shadow-popover: 0 12px 38px rgba(0,0,0,.48), 0 2px 6px rgba(0,0,0,.30)`
        public static let shadowPopover = ChromeShadow.popover(
            dropOffsetY: 12, dropBlur: 38, dropAlpha: 0.48,
            secondaryOffsetY: 2, secondaryBlur: 6, secondaryAlpha: 0.30
        )
    }

    /// `[data-appearance="light"]` in `appearance.css`, which overrides the
    /// dark base for every token it redeclares.
    public enum Light {
        /// `--mat-fill-chrome: rgba(252, 252, 254, 0.74)`
        public static let fillChrome = RGBA(red: 252, green: 252, blue: 254, alpha: 0.74)

        /// `--mat-fill-sidebar: rgba(250, 250, 252, 0.60)`
        public static let fillSidebar = RGBA(red: 250, green: 250, blue: 252, alpha: 0.60)

        /// `--mat-fill-thick: rgba(255, 255, 255, 0.88)`
        public static let fillThick = RGBA(red: 255, green: 255, blue: 255, alpha: 0.88)

        /// `--mat-fill-menu: rgba(255, 255, 255, 0.86)`
        public static let fillMenu = RGBA(red: 255, green: 255, blue: 255, alpha: 0.86)

        /// `--rim-top: rgba(255, 255, 255, 0.86)`
        public static let rimTopAlpha: Double = 0.86

        /// `--rim-bottom: rgba(0, 0, 0, 0.10)`
        public static let rimBottomAlpha: Double = 0.10

        /// `--shadow-window: 0 24px 64px rgba(0,0,0,.42), 0 0 0 0.5px rgba(255,255,255,.30)`
        public static let shadowWindow = ChromeShadow.window(
            dropOffsetY: 24, dropBlur: 64, dropAlpha: 0.42,
            ringSpread: 0.5, ringAlpha: 0.30
        )

        /// `--shadow-popover: 0 12px 34px rgba(0,0,0,.20), 0 1px 3px rgba(0,0,0,.12)`
        public static let shadowPopover = ChromeShadow.popover(
            dropOffsetY: 12, dropBlur: 34, dropAlpha: 0.20,
            secondaryOffsetY: 1, secondaryBlur: 3, secondaryAlpha: 0.12
        )
    }

    /// The focused pane's lift, under glass: `PaneLiftView`'s ring, inner
    /// highlight and shadow (Task 6).
    ///
    /// Unlike every other role in this file, these numbers are not
    /// transcribed from `materials.css` or `appearance.css` — no lift role
    /// exists in the vitreous token files (checked: neither file names
    /// "lift" or a matching ring/shadow pair). The plan's Task 6 text is the
    /// source of record instead: `0 0 0 0.5px rgba(255,255,255,0.22)` for the
    /// ring, `inset 0 1px 0 rgba(255,255,255,0.30)` for the inner highlight,
    /// `0 12px 34px rgba(0,0,0,0.6)` for the drop shadow. One appearance
    /// only, because the ring and shadow read as depth cues rather than as a
    /// material fill, and the plan's numbers do not carry a light variant the
    /// way `materials.css`'s fills do.
    public enum Lift {
        /// The ring's spread, in points: a hairline the same shape
        /// ``ChromeShadow/window(dropOffsetY:dropBlur:dropAlpha:ringSpread:ringAlpha:)``
        /// already draws for `--shadow-window`.
        public static let ringSpread: Double = 0.5

        public static let ringAlpha: Double = 0.22

        /// The inner highlight's vertical offset, in points: `inset 0 1px 0`,
        /// no blur or spread.
        public static let innerHighlightOffsetY: Double = 1

        public static let innerHighlightAlpha: Double = 0.30

        /// The lift's drop shadow. Carried as a ``ChromeShadow`` for the same
        /// reason ``Dark/shadowWindow`` is: a consumer that already knows how
        /// to draw a `ChromeShadow`'s drop layer draws this one the same way,
        /// with the ring left at 0 because the lift draws its ring as its own
        /// stroke (``ringSpread``/``ringAlpha`` above) rather than folding it
        /// into this shadow.
        public static let shadow = ChromeShadow.window(
            dropOffsetY: 12, dropBlur: 34, dropAlpha: 0.6,
            ringSpread: 0, ringAlpha: 0
        )
    }

    /// `motion.css`'s `:root` scope: the curve and the two durations the lift
    /// transition (Task 6) uses. Only the two durations that band names are
    /// carried here, not all five `--dur-*` steps, for the same
    /// added-when-needed reason the fill roles above stop short of the full
    /// eight materials.
    public enum Motion {
        /// `--ease-standard: cubic-bezier(0.32, 0.72, 0, 1)`, as the curve's
        /// four control points in declaration order.
        public static let standardEase: (Double, Double, Double, Double) = (0.32, 0.72, 0, 1)

        /// `--dur-2: 140ms`, the short end of the 140-220ms band the plan
        /// names for the lift transition, in seconds (Foundation's animation
        /// APIs take `TimeInterval`).
        public static let liftDurationShort: Double = 0.140

        /// `--dur-3: 220ms`, the long end of the same band, in seconds.
        public static let liftDurationLong: Double = 0.220
    }
}
