import BaiaSettings

/// Everything ``PaneLiftView`` draws with, resolved: the constants in
/// `ChromeMaterials.Lift`/`Motion`, or whatever the debug design panel has
/// dialled in front of them.
///
/// **``shipped`` is exactly the constants, and it is the default.** A lift view
/// that is never handed one of these renders precisely what it rendered before
/// this type existed, which is what makes the whole wire a no-op with the
/// overrides nil. ``from(_:)`` builds a dialled one; nil per field there falls
/// back to the constant, never to zero and never to off.
///
/// **Resolved once, into non-optionals, rather than eight `??` at the draw
/// sites.** `draw(_:)` and `updateShadowPath()` both need the ring and the
/// shadow reach, and a fallback spelled twice is a fallback that can be spelled
/// two ways. It is also what keeps ``PaneLiftView`` free of any import beyond
/// what it already has — a constraint described in `Sources/PaneOverlayView.swift`,
/// which is no longer this file, since this type has since moved out of it;
/// `Diagnostics/footer-corners` compiles that file
/// verbatim against `PaneChrome`, `BaiaSettings` and `WorkspaceLayout` alone,
/// and a `DesignOverrides` read inside the view would be a fourth edge that
/// probe cannot link.
///
/// Colours are deliberately absent. The ring and the highlight are white at an
/// alpha, per the plan's Task 6 text, and the panel dials the alphas rather than
/// the hue: a coloured lift is a different effect, not this one turned up.
///
/// **Moved into `PaneChrome` from `Sources/PaneOverlayView.swift`** so
/// ``PaneAppearance/make(settings:overrides:materialIsDark:appearance:)`` can carry a
/// resolved value without reaching for an app-target type. Verbatim, with its
/// doc comment; the access level changed, from `struct`/`static`/`var` to
/// `public`, and `Sendable` was added on the move, since the type now crosses
/// a module boundary it did not cross before.
public struct PaneLiftParameters: Sendable, Equatable {
    public var enabled: Bool
    public var ringSpread: Double
    public var ringAlpha: Double
    public var innerHighlightOffsetY: Double
    public var innerHighlightAlpha: Double
    public var shadowDropOffsetY: Double
    public var shadowDropBlur: Double
    public var shadowDropAlpha: Double
    public var duration: Double

    /// Explicit, because a public struct's memberwise initializer is only
    /// internal: `Diagnostics/override-wires/wiretest.swift:149` constructs
    /// this type field by field from outside `PaneChrome`, across the module
    /// boundary the move just crossed.
    public init(
        enabled: Bool,
        ringSpread: Double,
        ringAlpha: Double,
        innerHighlightOffsetY: Double,
        innerHighlightAlpha: Double,
        shadowDropOffsetY: Double,
        shadowDropBlur: Double,
        shadowDropAlpha: Double,
        duration: Double
    ) {
        self.enabled = enabled
        self.ringSpread = ringSpread
        self.ringAlpha = ringAlpha
        self.innerHighlightOffsetY = innerHighlightOffsetY
        self.innerHighlightAlpha = innerHighlightAlpha
        self.shadowDropOffsetY = shadowDropOffsetY
        self.shadowDropBlur = shadowDropBlur
        self.shadowDropAlpha = shadowDropAlpha
        self.duration = duration
    }

    /// The constants, unmoved: what every pane draws until something is dialled.
    ///
    /// `duration` takes the long end of the 140-220 ms band, which is the value
    /// ``PaneLiftView/apply(animated:)`` picked before this type existed and for
    /// the reason recorded there: the lift crosses two panes on a click, and the
    /// short end was tuned for a single-layer fade.
    public static let shipped = PaneLiftParameters(
        enabled: true,
        ringSpread: ChromeMaterials.Lift.ringSpread,
        ringAlpha: ChromeMaterials.Lift.ringAlpha,
        innerHighlightOffsetY: ChromeMaterials.Lift.innerHighlightOffsetY,
        innerHighlightAlpha: ChromeMaterials.Lift.innerHighlightAlpha,
        shadowDropOffsetY: ChromeMaterials.Lift.shadow.dropOffsetY,
        shadowDropBlur: ChromeMaterials.Lift.shadow.dropBlur,
        shadowDropAlpha: ChromeMaterials.Lift.shadow.dropAlpha,
        duration: ChromeMaterials.Motion.liftDurationLong
    )

    /// ``shipped``, with each dialled field standing in front of its constant.
    ///
    /// Field by field rather than "rebuild from the overrides", the same shape
    /// `Settings.applying(_:)` takes and for the same reason: a field this
    /// function has never heard of keeps its constant instead of arriving as a
    /// zero.
    public static func from(_ lift: DesignOverrides.Chrome.Lift) -> PaneLiftParameters {
        var resolved = shipped
        if let value = lift.enabled { resolved.enabled = value }
        if let value = lift.ringSpread { resolved.ringSpread = value }
        if let value = lift.ringAlpha { resolved.ringAlpha = value }
        if let value = lift.innerHighlightOffsetY { resolved.innerHighlightOffsetY = value }
        if let value = lift.innerHighlightAlpha { resolved.innerHighlightAlpha = value }
        if let value = lift.shadowDropOffsetY { resolved.shadowDropOffsetY = value }
        if let value = lift.shadowDropBlur { resolved.shadowDropBlur = value }
        if let value = lift.shadowDropAlpha { resolved.shadowDropAlpha = value }
        if let value = lift.duration { resolved.duration = value }
        return resolved
    }
}

/// The lens rim: the bright top edge `--rim-top` names, drawn inside a pane's
/// own outline.
///
/// **Off by default, and off is exactly today's rendering.** The rim constants
/// have been transcribed and tested in ``ChromeMaterials`` since v5 and no
/// drawing site has ever read them; this is their first consumer, and it draws
/// nothing at all unless ``enabled`` is set. So the wire adds a knob without
/// adding a pixel, which is the acceptance the whole override layer is held to.
///
/// Top edge only, per the constants' own doc (`inset 0 0.5px 0`, a bright top
/// rim). `--rim-bottom` is transcribed beside it in ``ChromeMaterials`` and is
/// deliberately not drawn here: `DesignOverrides.Chrome.Rim` offers one alpha,
/// and a bottom edge nothing can dial would be an effect the owner cannot
/// switch off independently of the one he asked for.
///
/// Moved into `PaneChrome` alongside ``PaneLiftParameters``, for the same
/// reason and verbatim but for access level, and `Sendable` was added on the
/// move for the same reason as that type's: it now crosses a module boundary.
public struct PaneRimParameters: Sendable, Equatable {
    public var enabled: Bool

    /// The bright edge's alpha. Defaults to the *dark* appearance's constant,
    /// which is the one the app draws under today (`ChromeAppearance`'s material
    /// set follows the theme, and the shipped theme is dark).
    ///
    /// One value rather than one per appearance, matching
    /// `DesignOverrides.Chrome.Rim`'s own reasoning: the panel is dialled on the
    /// machine in front of the owner and that machine is in one appearance at a
    /// time.
    public var topAlpha: Double

    /// Explicit, for the same cross-module reason as ``PaneLiftParameters``'s:
    /// the memberwise initializer a public struct gets for free is internal,
    /// not public.
    public init(enabled: Bool, topAlpha: Double) {
        self.enabled = enabled
        self.topAlpha = topAlpha
    }

    /// The edge's thickness, in points: `inset 0 0.5px 0`. Not dialable, and
    /// deliberately so — it is a hairline the token names, and the override
    /// offers an alpha alone.
    public static let thickness: Double = 0.5

    /// Absent: what every pane draws today and what a nil override leaves it
    /// drawing.
    public static let off = PaneRimParameters(
        enabled: false,
        topAlpha: ChromeMaterials.Dark.rimTopAlpha
    )

    public static func from(_ rim: DesignOverrides.Chrome.Rim) -> PaneRimParameters {
        var resolved = off
        if let value = rim.enabled { resolved.enabled = value }
        if let value = rim.topAlpha { resolved.topAlpha = value }
        return resolved
    }
}
