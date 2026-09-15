import BaiaSettings
import Foundation

/// The live system state ``resolvedStyle(setting:materialIsDark:appearance:)``
/// needs to turn a ``BaiaSettings/ChromeStyle`` into a ``ResolvedChrome``.
///
/// A value type rather than a live read of `NSApp` or `NSWorkspace`, for the
/// same reason ``SettingsDerivations`` takes a `Settings` value instead of a
/// `SettingsStore`: this package must not import AppKit (see ``RGB``'s own
/// doc comment), and a pure function is what the one-second loop and this
/// package's test suite both need. `AppearanceObserver` in the app target
/// reads the three live values this carries and constructs one of these on
/// every change; nothing in this package ever asks the system directly.
///
/// **This type answers only "how should the chrome render." It must never
/// reach a place that decides what colour theme ink is.** `PaneTheme`'s colour
/// derivations, `PaneGitRuns`, and the attention pipeline resolve every
/// colour from the terminal theme and the `Settings` the owner wrote, and
/// reading system appearance there would let macOS's light/dark switch repaint
/// panes ghostty was never told to change, which is the mismatch `PaneTheme`'s
/// own header warns about. A grep for this type's name inside those files
/// finding nothing is part of Task 3's acceptance, not an incidental fact
/// about it.
public struct ChromeAppearance: Sendable, Equatable {
    /// Whether the *system's* effective appearance is dark:
    /// ``AppearanceObserver``'s `NSApp.effectiveAppearance` read, resolved down
    /// to `.darkAqua` / `.aqua`.
    ///
    /// **No material selection reads this, and none may.** It picked between
    /// ``MaterialSet/dark`` and ``MaterialSet/light`` until the glass materials
    /// were moved onto the theme, and
    /// ``resolvedStyle(setting:materialIsDark:appearance:)`` takes `materialIsDark`
    /// as its own parameter for exactly that reason — its doc comment carries
    /// the argument, and `ChromeAppearanceTests` pins it as an equality across
    /// both values of this field. Nothing else in the app reads it either, so
    /// this is the honest publication of what the system appearance *is* rather
    /// than a value anything currently branches on. `AppearanceObserver` reads
    /// all three fields in one place and republishes them together, and dropping
    /// this one would leave that read partial and the next consumer of the system
    /// appearance rebuilding it somewhere less controlled.
    ///
    /// It must never reach a colour a pane's own theme draws, which is the wider
    /// version of the same rule this type's own header states.
    public var isDark: Bool

    /// `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency`.
    /// Forces ``ResolvedChrome/flat`` regardless of the configured
    /// ``BaiaSettings/ChromeStyle``, the one override this rule makes.
    public var reduceTransparency: Bool

    /// `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`. Carried
    /// here because it arrives on the same observer and the same notification
    /// as the other two, but ``resolvedStyle(setting:materialIsDark:appearance:)``
    /// does not read it: it governs the lift's transition timing (Task 6), not whether
    /// glass renders at all, so this field is inert to *which* `ResolvedChrome`
    /// comes back and `ChromeAppearanceTests` pins that directly.
    public var reduceMotion: Bool

    public init(isDark: Bool, reduceTransparency: Bool, reduceMotion: Bool) {
        self.isDark = isDark
        self.reduceTransparency = reduceTransparency
        self.reduceMotion = reduceMotion
    }
}

/// Which native glass material a `glass`-resolved surface asks AppKit for.
///
/// Mirrors `NSGlassEffectView.Style` case for case without importing AppKit,
/// for the reason every other type in this file gives: the package must stay
/// testable with no window, and the app target is the one place the mapping to
/// the platform enum is made (see `SurfaceFill.swift`). The mapping there
/// carries no `default`, so a case added here fails to compile until a
/// platform style is named for it.
///
/// **This field is the whole visible difference between
/// ``BaiaSettings/ChromeStyle/liquidGlass`` and ``BaiaSettings/ChromeStyle/sheer``
/// as shipped.** Every fill role on ``MaterialSet`` is dormant (Design v5 Task
/// 2, untinted glass), so until 2026-09-14 the two styles resolved to material
/// sets that differed only in values no surface read, and every glass view was
/// built at `.regular`. Whole-display captures of the two styles under Dawnfox
/// and Dark Pastel, focused and unfocused, came back byte-identical. The
/// platform's own lighter material is what "sheer" was always meant to be.
public enum NativeGlassStyle: Sendable, Equatable {
    /// `NSGlassEffectView.Style.regular`: the standard material, what
    /// ``MaterialSet/dark`` and ``MaterialSet/light`` ask for.
    case regular

    /// `NSGlassEffectView.Style.clear`: the platform's most transparent
    /// material, what ``MaterialSet/sheerDark`` and ``MaterialSet/sheerLight``
    /// ask for.
    case clear
}

/// The fills, rims, shadows and durations a `glass`-resolved surface draws
/// with, picked for one appearance.
///
/// A struct rather than reaching for ``ChromeMaterials/Dark`` or
/// ``ChromeMaterials/Light`` directly at every call site, so a consumer
/// (Tasks 4-6) takes one value instead of an appearance flag it would have to
/// re-branch on beside the one
/// ``resolvedStyle(setting:materialIsDark:appearance:)`` already
/// resolved. The two static members below are the only two that exist,
/// mirroring ``ChromeMaterials``' own dark/light split, and each is pinned
/// against its source table by ``ChromeAppearanceTests`` rather than
/// recomputed.
public struct MaterialSet: Sendable, Equatable {
    public var fillChrome: RGBA
    public var fillSidebar: RGBA
    public var fillThick: RGBA
    public var fillMenu: RGBA
    public var rimTopAlpha: Double
    public var rimBottomAlpha: Double
    public var shadowWindow: ChromeShadow
    public var shadowPopover: ChromeShadow

    /// The native material a glass view built from this set asks for. The one
    /// field a glass surface reads at HEAD; see ``NativeGlassStyle``.
    public var nativeStyle: NativeGlassStyle

    /// `ChromeMaterials.Dark`, the appearance most of the design was built
    /// against and the one `:root` declares with no `[data-appearance]`
    /// selector.
    public static let dark = MaterialSet(
        fillChrome: ChromeMaterials.Dark.fillChrome,
        fillSidebar: ChromeMaterials.Dark.fillSidebar,
        fillThick: ChromeMaterials.Dark.fillThick,
        fillMenu: ChromeMaterials.Dark.fillMenu,
        rimTopAlpha: ChromeMaterials.Dark.rimTopAlpha,
        rimBottomAlpha: ChromeMaterials.Dark.rimBottomAlpha,
        shadowWindow: ChromeMaterials.Dark.shadowWindow,
        shadowPopover: ChromeMaterials.Dark.shadowPopover,
        nativeStyle: .regular
    )

    /// `ChromeMaterials.Light`, `appearance.css`'s `[data-appearance="light"]` override.
    public static let light = MaterialSet(
        fillChrome: ChromeMaterials.Light.fillChrome,
        fillSidebar: ChromeMaterials.Light.fillSidebar,
        fillThick: ChromeMaterials.Light.fillThick,
        fillMenu: ChromeMaterials.Light.fillMenu,
        rimTopAlpha: ChromeMaterials.Light.rimTopAlpha,
        rimBottomAlpha: ChromeMaterials.Light.rimBottomAlpha,
        shadowWindow: ChromeMaterials.Light.shadowWindow,
        shadowPopover: ChromeMaterials.Light.shadowPopover,
        nativeStyle: .regular
    )

    /// ``BaiaSettings/ChromeStyle/sheer`` under a dark theme.
    ///
    /// **Four constants rather than a style dimension on this type**, chosen
    /// 2026-08-15 for being the duller change: `dark`/`light` are an
    /// *appearance* pair picked by `materialIsDark`, and sheer is a *style* that
    /// has to work in both, so it is a second axis rather than a third sibling.
    /// Spelling it as four flat constants leaves
    /// ``resolvedStyle(setting:materialIsDark:appearance:)``'s selection shape
    /// untouched; giving `MaterialSet` a style dimension would model it better
    /// and touch every construction site to do it.
    ///
    /// Fills come from ``ChromeMaterials/Sheer``; the rims and shadows are the
    /// unscaled `Dark` values, because they are depth cues rather than tint and
    /// the most transparent style is where a pane edge needs them most.
    ///
    /// ``nativeStyle`` is `.clear`, added 2026-09-14, and it is the one field
    /// here a shipped surface reads: the fills above are dormant, so without it
    /// sheer rendered the same `.regular` glass as `liquidGlass` and the two
    /// styles captured byte-identical. It does not reopen the style-dimension
    /// question above; the selection shape in
    /// ``resolvedStyle(setting:materialIsDark:appearance:)`` is unchanged.
    public static let sheerDark = MaterialSet(
        fillChrome: ChromeMaterials.Sheer.Dark.fillChrome,
        fillSidebar: ChromeMaterials.Sheer.Dark.fillSidebar,
        fillThick: ChromeMaterials.Sheer.Dark.fillThick,
        fillMenu: ChromeMaterials.Sheer.Dark.fillMenu,
        rimTopAlpha: ChromeMaterials.Dark.rimTopAlpha,
        rimBottomAlpha: ChromeMaterials.Dark.rimBottomAlpha,
        shadowWindow: ChromeMaterials.Dark.shadowWindow,
        shadowPopover: ChromeMaterials.Dark.shadowPopover,
        nativeStyle: .clear
    )

    /// ``BaiaSettings/ChromeStyle/sheer`` under a light theme. See
    /// ``sheerDark`` for why these are four constants.
    public static let sheerLight = MaterialSet(
        fillChrome: ChromeMaterials.Sheer.Light.fillChrome,
        fillSidebar: ChromeMaterials.Sheer.Light.fillSidebar,
        fillThick: ChromeMaterials.Sheer.Light.fillThick,
        fillMenu: ChromeMaterials.Sheer.Light.fillMenu,
        rimTopAlpha: ChromeMaterials.Light.rimTopAlpha,
        rimBottomAlpha: ChromeMaterials.Light.rimBottomAlpha,
        shadowWindow: ChromeMaterials.Light.shadowWindow,
        shadowPopover: ChromeMaterials.Light.shadowPopover,
        nativeStyle: .clear
    )
}

/// What a frame draws, after
/// ``resolvedStyle(setting:materialIsDark:appearance:)`` has weighed the
/// configured ``BaiaSettings/ChromeStyle`` against the live
/// ``ChromeAppearance`` and the theme's own darkness.
///
/// An enum with the material set carried on the `glass` case, rather than a
/// `ChromeStyle` plus a `MaterialSet?` pair, so a consumer cannot hold
/// `(.glass, nil)` or `(.flat, someSet)`, states the resolution never
/// produces and a caller would otherwise have to decide what to do with.
public enum ResolvedChrome: Sendable, Equatable {
    /// Solid fills, the drawn hairline and capsule, no backing material
    /// anywhere in the chrome. Byte-identical to what Plan 1 shipped.
    case flat

    /// Translucent backing views under the pane and sidebar, and the focus
    /// lift's ring and shadow, drawn with the carried material set.
    case glass(MaterialSet)
}

/// The one place ``BaiaSettings/ChromeStyle`` and ``ChromeAppearance`` meet.
///
/// Pure and free of any live read, which is the whole property Task 3 exists
/// to buy: ``AppearanceObserver`` in the app target is the only place that
/// asks the system anything, and everything downstream of it — this
/// function, the material tables it draws from, the views that consume its
/// result — is exercised by `make test` with no window, no Metal, no signing.
///
/// **`materialIsDark` is an input rather than `appearance.isDark`, and that is
/// the same rule ``windowIsDark(paneTheme:)`` below already carries reaching
/// the glass materials.** The material set decides what the pane's glass, the
/// sidebar column, the palette and the popover are *filled* with, and those are
/// chrome; the standing rule (`PaneTheme`'s own header) is that chrome matches
/// the theme and never the system. Reading `ChromeAppearance.isDark` here wired
/// them to `NSApp.effectiveAppearance` instead, so a dark theme under a light
/// system appearance drew light glass over dark panes — the identical mismatch
/// the titlebar had until `windowIsDark` was added, one surface over. Making it
/// a parameter rather than reading a theme here keeps this function's purity and
/// keeps the caller naming where darkness comes from:
/// `ConfigurationCenter.resolvedChrome` passes `windowIsDark(paneTheme:)`, so
/// the window's own chrome and the glass inside it cannot disagree about which
/// appearance the app is in.
///
/// **Reduce Transparency still forces `flat` for any setting, and
/// `materialIsDark` cannot reach past it.** That override lives on
/// ``ChromeAppearance`` and stays there: the guard is above the material branch,
/// so an accessibility answer is never traded for a theme one. It is the one
/// override this rule makes; Reduce Motion is carried on ``ChromeAppearance``
/// for ``AppearanceObserver`` to publish in one place, but this function does
/// not read it; see the field's own doc comment.
///
/// The `appearance` parameter therefore reaches this function for
/// `reduceTransparency` alone. It stays a whole ``ChromeAppearance`` rather than
/// a bare `Bool` because that type is what ``AppearanceObserver`` publishes and
/// what the two window gates below take, and three gates that take the same
/// value are three gates a caller cannot feed inconsistently.
public func resolvedStyle(
    setting: ChromeStyle,
    materialIsDark: Bool,
    appearance: ChromeAppearance
) -> ResolvedChrome {
    switch setting {
    case .solid:
        return .flat
    case .liquidGlass:
        guard !appearance.reduceTransparency else { return .flat }
        return .glass(materialIsDark ? .dark : .light)
    case .sheer:
        // Reduce Transparency outranks this the same way it outranks
        // `liquidGlass`, and it matters more here: sheer is the style that lets
        // the most desktop through, so the accessibility setting that exists to
        // stop exactly that cannot be the one style it fails to reach.
        guard !appearance.reduceTransparency else { return .flat }
        return .glass(materialIsDark ? .sheerDark : .sheerLight)
    }
}

/// Whether the workspace window itself should be non-opaque, so what it draws
/// composites against the desktop rather than against a fill of its own.
///
/// **Driven by ``BaiaSettings/Settings/backgroundOpacity`` for the two
/// see-through styles, and by ``BaiaSettings/ChromeStyle`` for
/// ``BaiaSettings/ChromeStyle/solid``.**
///
/// The 2026-08-07 decision was that opacity alone drove this and the chrome
/// style never did, on ghostty parity: a translucent background is a *terminal*
/// setting, so someone running flat chrome at `backgroundOpacity: 0.42` got the
/// translucent wells they asked for. **Half of that is retired (owner,
/// 2026-08-15) and the half that survives is the reason it was right.**
///
/// What broke it: `flat` had no material to diffuse the desktop, so it inherited
/// the window's transparency with nothing standing between the wallpaper and the
/// text. Captured at opacity 0 and 0.5 over a bright wallpaper on 2026-08-15, the
/// terminal body was see-through enough to swallow whole lines of the
/// transcript. "Flat chrome over translucent wells is the vitreous look" holds
/// only where something diffuses the well, and flat was the one style where
/// nothing did.
///
/// So ``BaiaSettings/ChromeStyle/solid`` is opaque at every opacity, and the
/// slider is hidden under it rather than ignored quietly. The parity argument
/// keeps its force for ``BaiaSettings/ChromeStyle/liquidGlass`` and
/// ``BaiaSettings/ChromeStyle/sheer``, where the material is what makes a
/// translucent well readable and the slider is the tint control.
///
/// This still decides no drawing. It sets two window compositing flags the
/// drawing code never reads; which fills, rims and backing views a surface
/// creates is ``resolvedStyle(setting:materialIsDark:appearance:)``'s business.
///
/// **Reduce Transparency forces opaque, and that is deliberately the same
/// override ``resolvedStyle(setting:materialIsDark:appearance:)`` makes one
/// function above.**
/// Both gates read `appearance.reduceTransparency` and both resolve toward the
/// solid answer, so someone who turns the accessibility setting on gets a
/// window with nothing showing through it *and* solid chrome, rather than one
/// of the two. They are kept adjacent, and pinned together by
/// `ChromeAppearanceTests`, precisely so a change to one is not made without
/// seeing the other.
///
/// At `backgroundOpacity == 1` the window stays opaque, which is what it has
/// always been: there is nothing to see through, and a non-opaque window is a
/// compositing cost with no visible effect.
public func windowIsTransparent(
    style: ChromeStyle,
    backgroundOpacity: Double,
    appearance: ChromeAppearance
) -> Bool {
    guard !appearance.reduceTransparency else { return false }
    guard style != .solid else { return false }
    return backgroundOpacity < 1
}

/// Whether the workspace window's own chrome — the titlebar material, the tab
/// bar, and anything else AppKit draws from `NSWindow.appearance` rather than
/// from a view this app owns — should render dark.
///
/// **Reads the pane theme's background, never ``ChromeAppearance/isDark``.**
/// `ChromeAppearance.isDark` is `AppearanceObserver`'s read of
/// `NSApp.effectiveAppearance` — the *system* appearance — which is exactly the
/// signal the standing rule (`Settings.swift`'s own doc, and every derivation in
/// ``PaneTheme``) says chrome must never follow. `PaneTheme`'s own header states
/// the rule for ink: "the standing rule in this workspace is to match chrome to
/// the theme and never the reverse." The titlebar is chrome, so the owner's
/// request is that same rule reaching one more surface, and reading
/// `ChromeAppearance.isDark` here would be wiring it to the one signal the rule
/// forbids.
///
/// **This is now the source for the glass materials too, not only for the
/// window's own chrome.** It was written as the lone exception among the three
/// window gates while ``resolvedStyle(setting:materialIsDark:appearance:)``
/// still branched on `ChromeAppearance.isDark`, which meant a dark theme under a
/// light system appearance produced a correctly-dark titlebar over
/// light-material glass. `ConfigurationCenter.resolvedChrome` passes this
/// function's answer as `materialIsDark`, so the two cannot disagree: one read
/// of the theme's background decides the window's appearance and the material
/// set together. That is why the *system* appearance changing while the theme
/// stays put moves nothing a person can see, and a theme change moves both in
/// the same frame.
///
/// ``RGB/isDark`` rather than a second luminance formula: that property's own
/// doc comment is the reason — it "mirrors libghostty's own dark test... so
/// baia agrees with the terminal about which theme it is in," which is
/// precisely what deciding the titlebar's own light/dark needs, and
/// `PaneTheme.readable(_:on:minimumRatio:)` warns in its own comment about a
/// second luminance measure disagreeing with this one across a band of mid
/// greys. Not ``RGB/relativeLuminance`` (the WCAG measure `readable` uses to
/// grade contrast): that is answering a different question, whether an ink
/// clears a contrast floor against a specific fill, and grading the *window's*
/// appearance against a fill it is not drawn on would be the second mapping
/// this function exists to avoid needing.
///
/// Takes the resolved ``BaiaSettings/PaneTheme`` (via
/// `SettingsDerivations.paneTheme`) rather than a raw `RGB`, so the call site
/// reads the same theme value every other chrome derivation reads and this
/// cannot silently drift onto a different background than what the panes
/// actually render.
public func windowIsDark(paneTheme: PaneTheme) -> Bool {
    paneTheme.background.isDark
}

/// The radius the compositor should blur what shows *through* a transparent
/// workspace window, or `0` for no blur at all.
///
/// The companion of
/// ``windowIsTransparent(style:backgroundOpacity:appearance:)``
/// directly above, and deliberately built on top of it rather than beside it:
/// blur is what the desktop looks like *behind* this window, so there is
/// nothing to blur unless the window is letting the desktop through. A blurred
/// backdrop under an opaque window is invisible and still costs the compositor
/// a pass, and calling it with `backgroundOpacity == 1` is the shape of a bug
/// rather than a request. So the gate is both: the setting says yes *and* the
/// window is transparent by the rule one function up. That also means the
/// Reduce Transparency override arrives here for free — it forces the window
/// opaque, which forces this to `0` — and the two accessibility gates stay the
/// single fact they are rather than a rule restated in a second place that can
/// drift from the first.
///
/// `paneGlassActive` is a fourth gate above all of those, and the only one that
/// answers `0` while every other input says yes: pane-as-glass constraint 3.
/// With a real glass plane behind every pane, glass does all the lensing, and
/// the compositor blur under it is a window-server pass per frame for nothing.
/// Measured rather than assumed, in `Diagnostics/pane-glass-blur`: the blur
/// under a plane is invisible (mean +0.3/255 against the same scene with it
/// off), and the plane is the stronger low-pass of the two (1.5% fine-detail
/// retention against the compositor's 3.7%).
///
/// ``parityBlurRadius`` is the value, and its own doc comment carries why 20.
/// **``BaiaSettings/ChromeStyle/solid`` reaches `0` through the same free
/// inheritance the Reduce Transparency override already had** (2026-08-15).
/// Solid forces the window opaque one function up, so there is nothing showing
/// through to blur, and the gate below reads that rather than restating it.
public func windowBlurRadius(
    style: ChromeStyle,
    backgroundBlur: Bool,
    backgroundOpacity: Double,
    appearance: ChromeAppearance,
    paneGlassActive: Bool
) -> Int {
    // Pane-as-glass constraint 3: with a real glass plane behind every pane,
    // glass does all lensing. Diagnostics/pane-glass-blur measured the
    // compositor blur under a plane as invisible (mean +0.3/255) and the
    // plane as the stronger low-pass (1.5% vs 3.7% fine-detail retention),
    // so leaving it on buys a window-server pass per frame for nothing.
    guard !paneGlassActive else { return 0 }
    guard backgroundBlur else { return 0 }
    guard windowIsTransparent(
        style: style,
        backgroundOpacity: backgroundOpacity,
        appearance: appearance
    ) else {
        return 0
    }
    return parityBlurRadius
}

/// The blur radius ghostty's own `background-blur = true` means.
///
/// ``BaiaSettings/Settings/backgroundBlur`` is a `Bool` because the owner's
/// ghostty config writes the boolean, and ghostty resolves that boolean to a
/// radius rather than treating it as an on/off switch over some other default.
/// Confirmed against the shipped Ghostty 1.3.1 on this machine rather than
/// guessed: `ghostty +show-config --default --docs` documents `background-blur`
/// as "true, equivalent to the default blur intensity of 20", the man page in
/// `Ghostty.app/Contents/Resources/man` says the same, and the string is
/// compiled into the shipped binary. `false` is `0` there too, which is what
/// ``windowBlurRadius(backgroundBlur:backgroundOpacity:appearance:paneGlassActive:)``
/// returns for every one of its off cases.
///
/// A named constant rather than a literal at the call site because parity is
/// the entire justification for the number: 20 is not a value baia tuned, and
/// anyone changing it is choosing to stop matching the terminal this app exists
/// to replace.
public let parityBlurRadius = 20
