import BaiaSettings
import Foundation

/// The live system state ``resolvedStyle(setting:appearance:)`` needs to turn a
/// ``BaiaSettings/ChromeStyle`` into a ``ResolvedChrome``.
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
/// derivations, `PaneStatusSegments`, and the attention pipeline resolve every
/// colour from the terminal theme and the `Settings` the owner wrote, and
/// reading system appearance there would let macOS's light/dark switch repaint
/// panes ghostty was never told to change, which is the mismatch `PaneTheme`'s
/// own header warns about. A grep for this type's name inside those files
/// finding nothing is part of Task 3's acceptance, not an incidental fact
/// about it.
public struct ChromeAppearance: Sendable, Equatable {
    /// Whether the effective appearance is dark. Picks between
    /// ``MaterialSet/dark`` and ``MaterialSet/light``, and nothing else: it
    /// must never reach a colour a pane's own theme draws.
    public var isDark: Bool

    /// `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency`.
    /// Forces ``ResolvedChrome/flat`` regardless of the configured
    /// ``BaiaSettings/ChromeStyle``, the one override this rule makes.
    public var reduceTransparency: Bool

    /// `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`. Carried
    /// here because it arrives on the same observer and the same notification
    /// as the other two, but ``resolvedStyle(setting:appearance:)`` does not
    /// read it: it governs the lift's transition timing (Task 6), not whether
    /// glass renders at all, so this field is inert to *which* `ResolvedChrome`
    /// comes back and `ChromeAppearanceTests` pins that directly.
    public var reduceMotion: Bool

    public init(isDark: Bool, reduceTransparency: Bool, reduceMotion: Bool) {
        self.isDark = isDark
        self.reduceTransparency = reduceTransparency
        self.reduceMotion = reduceMotion
    }
}

/// The fills, rims, shadows and durations a `glass`-resolved surface draws
/// with, picked for one appearance.
///
/// A struct rather than reaching for ``ChromeMaterials/Dark`` or
/// ``ChromeMaterials/Light`` directly at every call site, so a consumer
/// (Tasks 4-6) takes one value instead of an appearance flag it would have to
/// re-branch on beside the one ``resolvedStyle(setting:appearance:)`` already
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
        shadowPopover: ChromeMaterials.Dark.shadowPopover
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
        shadowPopover: ChromeMaterials.Light.shadowPopover
    )
}

/// What a frame draws, after ``resolvedStyle(setting:appearance:)`` has
/// weighed the configured ``BaiaSettings/ChromeStyle`` against the live
/// ``ChromeAppearance``.
///
/// An enum with the material set carried on the `glass` case, rather than a
/// `ChromeStyle` plus a `MaterialSet?` pair, so a consumer cannot hold
/// `(.glass, nil)` or `(.flat, someSet)`, states the resolution never
/// produces and a caller would otherwise have to decide what to do with.
public enum ResolvedChrome: Sendable, Equatable {
    /// Solid fills, the drawn hairline and capsule, no backing material
    /// anywhere in the chrome. Byte-identical to what Plan 1 shipped.
    case flat

    /// Translucent backing views under the footer and sidebar, and the focus
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
/// **Reduce Transparency forces `flat` for any setting.** That is the one
/// override this rule makes; Reduce Motion is carried on ``ChromeAppearance``
/// for ``AppearanceObserver`` to publish in one place, but this function does
/// not read it; see the field's own doc comment.
public func resolvedStyle(setting: ChromeStyle, appearance: ChromeAppearance) -> ResolvedChrome {
    switch setting {
    case .flat:
        return .flat
    case .glass:
        guard !appearance.reduceTransparency else { return .flat }
        return .glass(appearance.isDark ? .dark : .light)
    }
}

/// Whether the workspace window itself should be non-opaque, so what it draws
/// composites against the desktop rather than against a fill of its own.
///
/// **Driven by ``BaiaSettings/Settings/backgroundOpacity``, not by
/// ``BaiaSettings/ChromeStyle``** (owner decision, 2026-08-07). Ghostty parity
/// is the rationale: a translucent background is a *terminal* setting, and the
/// settings have always promised one, so someone running flat chrome with
/// `backgroundOpacity: 0.42` gets the translucent wells they asked for. Flat
/// chrome over translucent wells is the vitreous look rather than a
/// contradiction. This does not disturb the "flat renders byte-identically"
/// invariant ``ResolvedChrome/flat`` states: that invariant is scoped to the
/// chrome *drawing* paths — which fills, rims and backing views a surface
/// creates — and this decides none of them. It sets two window compositing
/// flags the drawing code never reads.
///
/// **Reduce Transparency forces opaque, and that is deliberately the same
/// override ``resolvedStyle(setting:appearance:)`` makes one function above.**
/// Both gates read `appearance.reduceTransparency` and both resolve toward the
/// solid answer, so someone who turns the accessibility setting on gets a
/// window with nothing showing through it *and* flat chrome, rather than one
/// of the two. They are kept adjacent, and pinned together by
/// `ChromeAppearanceTests`, precisely so a change to one is not made without
/// seeing the other.
///
/// At `backgroundOpacity == 1` the window stays opaque, which is what it has
/// always been: there is nothing to see through, and a non-opaque window is a
/// compositing cost with no visible effect.
public func windowIsTransparent(backgroundOpacity: Double, appearance: ChromeAppearance) -> Bool {
    guard !appearance.reduceTransparency else { return false }
    return backgroundOpacity < 1
}

/// Whether the workspace window's own chrome — the titlebar material, the tab
/// bar, and anything else AppKit draws from `NSWindow.appearance` rather than
/// from a view this app owns — should render dark.
///
/// **Reads the pane theme's background, not ``ChromeAppearance/isDark``, and
/// that is the whole point of this function existing separately from
/// ``resolvedStyle(setting:appearance:)``.** `ChromeAppearance.isDark` is
/// `AppearanceObserver`'s read of `NSApp.effectiveAppearance` — the *system*
/// appearance — which is exactly the signal the standing rule (`Settings.swift`'s
/// own doc, and every derivation in ``PaneTheme``) says chrome must never
/// follow. `PaneTheme`'s own header states the rule for ink: "the standing rule
/// in this workspace is to match chrome to the theme and never the reverse."
/// The titlebar is chrome, so the owner's request is that same rule reaching
/// one more surface, and reading `ChromeAppearance.isDark` here would be
/// wiring it to the one signal the rule forbids.
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
/// The companion of ``windowIsTransparent(backgroundOpacity:appearance:)``
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
/// ``parityBlurRadius`` is the value, and its own doc comment carries why 20.
public func windowBlurRadius(
    backgroundBlur: Bool,
    backgroundOpacity: Double,
    appearance: ChromeAppearance
) -> Int {
    guard backgroundBlur else { return 0 }
    guard windowIsTransparent(backgroundOpacity: backgroundOpacity, appearance: appearance) else {
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
/// ``windowBlurRadius(backgroundBlur:backgroundOpacity:appearance:)`` returns
/// for every one of its off cases.
///
/// A named constant rather than a literal at the call site because parity is
/// the entire justification for the number: 20 is not a value baia tuned, and
/// anyone changing it is choosing to stop matching the terminal this app exists
/// to replace.
public let parityBlurRadius = 20
