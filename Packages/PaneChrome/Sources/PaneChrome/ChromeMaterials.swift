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
        /// status bar — the footer's glass fill.
        public static let fillChrome = RGBA(red: 18, green: 20, blue: 24, alpha: 0.44)

        /// `--mat-fill-sidebar: rgba(18, 20, 24, 0.34)`. Source lists.
        public static let fillSidebar = RGBA(red: 18, green: 20, blue: 24, alpha: 0.34)

        /// `--mat-fill-thick: rgba(22, 24, 28, 0.52)`. Sheets, alerts, the
        /// footer's focused-pane step (Task 6).
        public static let fillThick = RGBA(red: 22, green: 24, blue: 28, alpha: 0.52)

        /// `--mat-fill-menu: rgba(30, 32, 37, 0.58)`. Menus, popovers, the
        /// command palette.
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
