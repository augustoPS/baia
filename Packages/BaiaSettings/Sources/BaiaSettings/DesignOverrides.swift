import Foundation

/// The ephemeral override layer behind the debug design panel.
///
/// The owner dials appearance live, over real sessions, with agents running in
/// the panes. So these values shadow the committed ``Settings`` in memory: a dial
/// is a question about how something looks, and the answer is worth keeping only
/// once the owner decides it is, which is what editing the config file already
/// means. `ConfigurationCenter` composes this before every derivation, including
/// every derivation taken while the panel has never been opened, which is why
/// ``Settings/applying(_:)`` on an empty value has to be exactly the identity.
///
/// **baia never writes an override anywhere.** Not to
/// `~/.config/baia/config.json`, not to `UserDefaults`, not to the file described
/// below. That is the claim, and it is narrower than "never persisted", which is
/// what this said until a watched file existed: `~/.config/baia/design-overrides.json`
/// does carry dialled values across launches, and it is the *owner's* document.
/// He writes it in an editor, baia reads it (``DesignOverridesText/parse(_:)``)
/// and re-themes on save, and deleting it is Reset. Read-only in the direction
/// that matters: nothing in the app can put a value on disk that the owner did
/// not type there. The one place an override is serialised at all is the design
/// panel's Copy Values, and it goes to the clipboard.
///
/// The file exists because on macOS 26A5388g the panel's own controls can crash
/// the app inside the OS's new gesture bridge, so an editor and a save are the
/// crash-safe way to dial.
///
/// **Every field is optional and nil means "the committed value", never "the
/// default value".** The distinction is the whole type. A non-optional field
/// initialised to a default would silently pin every un-dialled knob to whatever
/// this file thought the default was, so an owner running a config that departs
/// from the defaults would see the panel's mere existence move his chrome.
///
/// ## The absence of geometry is the contract
///
/// **There is no `fontSize`, no `fontFamily`, no `windowPadding`, no
/// `windowPaddingBalance`, and none may ever be added.** This type structurally
/// lacks them, and that absence is load-bearing rather than an oversight or a
/// scope cut.
///
/// The reason is the SIGWINCH wall. A geometry change resizes the cell grid,
/// which resizes the live PTY, which sends SIGWINCH to whatever is running in
/// the pane. A panel is dialled continuously and over real work, so a font-size
/// slider would resize every running agent's terminal on every frame of a drag.
/// Redrawing a TUI mid-run is the mild failure; the ones worth naming are an
/// agent's in-progress output reflowed out of legibility and a long run
/// disturbed by a knob nobody meant to point at it.
///
/// The wall cannot be honoured by a convention that "the panel just does not
/// expose a font slider", because the panel is not the only caller and a
/// convention is not checked. It is honoured here, once, by there being no field
/// to set. Adding one would be a behaviour change disguised as a feature, and
/// ``DesignOverridesTests`` pins it from the other side: composed settings emit
/// no change to any ghostty key that moves the grid.
///
/// Non-geometry appearance is unaffected. Opacity, blur, materials, accents and
/// the chrome extras all redraw without touching a single cell metric, which is
/// exactly why those are the ones offered.
public struct DesignOverrides: Sendable, Equatable {
    // MARK: - The seven that shadow a `Settings` field

    /// Shadows ``Settings/backgroundOpacity``.
    public var backgroundOpacity: Double?

    /// Shadows ``Settings/backgroundBlur``.
    public var backgroundBlur: Bool?

    /// Shadows ``Settings/chromeStyle``.
    ///
    /// Reduce Transparency still overrides whatever this resolves to. That
    /// resolution lives in `PaneChrome`, downstream of the composition here, so
    /// dialling `glass` on a machine with the accessibility flag set changes the
    /// setting and correctly changes nothing on screen.
    public var chromeStyle: ChromeStyle?

    /// Shadows ``Settings/attentionStyle``.
    public var attentionStyle: AttentionStyle?

    /// Shadows ``Settings/attentionAccent``.
    public var attentionAccent: AttentionAccent?

    /// Shadows ``Settings/focusAccent``.
    public var focusAccent: FocusAccent?

    /// Shadows ``Settings/transparentTitlebar``.
    ///
    /// Retired downstream: the field still decodes and round-trips, and reaches
    /// ghostty in neither direction. Offered here anyway, because a panel that
    /// silently omits a settable key is a panel whose absences cannot be told
    /// apart from its bugs.
    public var transparentTitlebar: Bool?

    // MARK: - The half that maps to no `Settings` field

    /// Numbers that reach drawing sites directly rather than through a
    /// ``Settings`` field. See ``Chrome``.
    public var chrome = Chrome()

    /// A value with nothing dialled: the identity of ``Settings/applying(_:)``.
    public init() {}
}

public extension DesignOverrides {
    /// The dials with no ``Settings`` field behind them.
    ///
    /// These are constants today, spread across `ChromeMaterials`, `PaneTheme`
    /// and the drawing views. They are not settings and are not becoming
    /// settings: a config key is a promise to keep a value working, and these
    /// exist to be dialled for an afternoon and then either folded into a
    /// constant or forgotten. Carrying them here rather than in ``Settings``
    /// keeps them out of the config file, out of the decoder, and out of the
    /// writer's round-trip.
    ///
    /// **nil is today's constant, not zero and not off.** A consumer reads
    /// `overrides.chrome.lift.ringAlpha ?? ChromeMaterials.Lift.ringAlpha`, so an
    /// undialled panel draws precisely what shipped. Which constant each field
    /// stands in for is named on the field.
    ///
    /// Nested rather than flat because the groups are how they are dialled: the
    /// lift is one effect made of eight numbers, and a panel that lists them
    /// beside a rim alpha is a panel nobody can read.
    struct Chrome: Sendable, Equatable {
        /// The focused pane's lift. See ``Lift``.
        public var lift = Lift()

        /// The lens rim. See ``Rim``.
        public var rim = Rim()

        /// The ink derivations. See ``Inks``.
        public var inks = Inks()

        /// Which fill each glass surface draws with. See ``Surfaces``.
        public var surfaces = Surfaces()

        /// Stands in for `PaneTheme.barLift`, today 0.10: how far the footer's
        /// bar is blended off the terminal background so it reads as chrome
        /// rather than as the last line of output.
        ///
        /// A fraction, 0 through 1. It is the one number here that moves a
        /// *colour every ink is then measured against*, since `barBackground` is
        /// the backdrop the repair chain grades footer text on, so dialling it
        /// moves the text too. That is the effect working rather than a
        /// surprise, and it is said here because the panel shows one slider and
        /// two things change.
        public var barLift: Double?

        // **`sidebarWashFloor` and `bareGlass` were here, and both retired on
        // 2026-08-08. The inventory is thirty, not thirty-two.**
        //
        // `sidebarWashFloor` put a minimum under the sidebar wash's opacity, so
        // the column would not stop reading as a surface at the bottom of the
        // opacity range. `bareGlass` suppressed the whole hand-drawn glass-era
        // layer at once — both washes and the caps label's legibility repair —
        // so the native material could be judged with none of this app's paint
        // in front of it.
        //
        // The second answered its question and the answer took the first with
        // it. The owner A/B'd naked native glass against the hand-drawn layer
        // through `bareGlass`, over his own desktop, and ruled that the naked
        // material wins. So the washes are gone from the code, a floor under a
        // wash that no longer exists is meaningless, and a flip that suppresses
        // a layer that is no longer drawn has nothing left to suppress. The one
        // survivor is the caps label's repair, now unconditional on glass and
        // more load-bearing without the wash darkening its backdrop — see
        // `SurfaceTitleView.labelInk`.
        //
        // A knob that existed to settle a question is not kept once the answer
        // is shipped code; keeping it would be keeping a second rendering path
        // for a look nobody chose.

        public init() {}
    }
}

public extension DesignOverrides.Chrome {
    /// The focused pane's lift: a ring, an inner highlight and a drop shadow,
    /// drawn under glass.
    ///
    /// Every default is in `ChromeMaterials.Lift`, whose own numbers come from
    /// the plan's Task 6 text rather than from the vitreous token files. That
    /// makes this the group most worth dialling: no token file has ever graded
    /// these against a real window.
    struct Lift: Sendable, Equatable {
        /// Whether the lift draws at all. nil leaves it drawing wherever it
        /// draws today.
        ///
        /// Present so "is the lift carrying its weight?" can be answered by
        /// switching it off, rather than by zeroing four alphas and hoping that
        /// is the same thing.
        public var enabled: Bool?

        /// Stands in for `ChromeMaterials.Lift.ringSpread`, today 0.5 points.
        public var ringSpread: Double?

        /// Stands in for `ChromeMaterials.Lift.ringAlpha`, today 0.22.
        public var ringAlpha: Double?

        /// Stands in for `ChromeMaterials.Lift.innerHighlightOffsetY`, today 1
        /// point.
        ///
        /// A shadow inset, not a layout inset: it moves where the highlight is
        /// drawn inside the frame and never where the frame is, so it reaches no
        /// cell metric. The whole ``DesignOverrides`` no-geometry contract turns
        /// on that distinction, and this is the one field where the two could be
        /// confused by name.
        public var innerHighlightOffsetY: Double?

        /// Stands in for `ChromeMaterials.Lift.innerHighlightAlpha`, today 0.30.
        public var innerHighlightAlpha: Double?

        /// Stands in for `ChromeMaterials.Lift.shadow`'s drop offset, today 12
        /// points.
        public var shadowDropOffsetY: Double?

        /// Stands in for `ChromeMaterials.Lift.shadow`'s drop blur, today 34
        /// points.
        public var shadowDropBlur: Double?

        /// Stands in for `ChromeMaterials.Lift.shadow`'s drop alpha, today 0.6.
        public var shadowDropAlpha: Double?

        /// The lift transition's duration, in seconds. Today the 0.140 to 0.220
        /// band `ChromeMaterials.Motion` carries.
        ///
        /// One number rather than the band's two, because a panel dials the
        /// duration it is watching. Reduce Motion still wins downstream, so
        /// dialling this on a machine with the flag set changes nothing on
        /// screen, correctly.
        public var duration: Double?

        public init() {}
    }

    /// The lens rim: a bright top edge and a dark bottom one, per appearance.
    struct Rim: Sendable, Equatable {
        /// Whether the rim draws at all.
        public var enabled: Bool?

        /// Stands in for the appearance's `rimTopAlpha`, today 0.42 dark and
        /// 0.86 light.
        ///
        /// One value rather than one per appearance, because the panel is dialled
        /// on the machine in front of the owner and that machine is in one
        /// appearance at a time. A dialled value therefore applies to whichever
        /// appearance is live, and the constant tables keep both.
        public var topAlpha: Double?

        public init() {}
    }

    /// One of the material-set fills a glass surface can be pointed at.
    ///
    /// **These four are exactly the roles `ChromeMaterials` carries, and no
    /// more.** `materials.css` defines others (`ultraThin`, `thin`, `regular`,
    /// `hud`), and `ChromeMaterials`' own doc comment states the rule for them:
    /// a role is added when a task first needs it, never ahead of one, because a
    /// role with no consumer is untested wiring. Naming a fifth case here would
    /// break that rule from the far end, offering the panel a material the
    /// drawing sites cannot resolve.
    ///
    /// Each case selects a *fill role*, not a colour. Which literal it resolves
    /// to still depends on the live appearance, since `MaterialSet.dark` and
    /// `.light` carry different values under the same four names, so a surface
    /// dialled to ``thick`` stays correct when the system flips appearance.
    enum Material: String, Sendable, Equatable, CaseIterable {
        /// `fillChrome`. Titlebar, toolbar and status bar in `materials.css`.
        case chrome

        /// `fillSidebar`. Source lists in `materials.css`.
        case sidebar

        /// `fillThick`. Sheets and alerts in `materials.css`.
        case thick

        /// `fillMenu`. Menus and popovers in `materials.css`.
        case menu
    }

    /// Which fill each glass surface draws with.
    ///
    /// The five surfaces are the ones the drawing sites already tell apart, so
    /// pointing one at a different fill is a re-selection among values that
    /// exist rather than a new material. nil leaves a surface on the fill it
    /// draws today, which is not the same fill for all five and is deliberately
    /// not named here: the mapping lives at the drawing site, and duplicating it
    /// into this doc comment would be a second copy free to drift from the first.
    ///
    /// Worth dialling because all four fills are currently retired from the live
    /// draw paths. Task 2's untinted glass dropped every tint and fill that read
    /// them, so what a surface draws today comes from the theme rather than from
    /// these tokens. Any answer about which fill suits which surface therefore
    /// has to be found by looking, which is what the panel is for.
    struct Surfaces: Sendable, Equatable {
        /// The pane footer's backing.
        public var footer: Material?

        /// The sidebar's backing.
        public var sidebar: Material?

        /// The command palette's backing.
        public var palette: Material?

        /// The approval popover's backing.
        public var popover: Material?

        /// The workspace window's titlebar backing.
        public var titlebar: Material?

        public init() {}
    }

    /// Ink adjustments, modelled the way `PaneTheme.sectionHeaderInk(on:)`
    /// already works.
    ///
    /// **A minimum contrast ratio, not a colour.** The standing rule is that a
    /// setting names a derivation and lets the theme decide what it resolves to,
    /// and the ink derivations are already spelled as a repair against the
    /// backdrop the ink is actually drawn on. So the honest dial is the floor the
    /// repair targets: raise it and the chain walks further up its fallback
    /// chain, on every theme, measured rather than guessed. A hex would be a
    /// number that looks right on Dark Pastel and says nothing about the other
    /// 484 themes in the catalog, which is the exact mistake
    /// `PaneTheme.sectionHeaderInk(on:)`'s own comment records having made once.
    ///
    /// Each ratio nevertheless has a hex beside it, for free dialling: the panel
    /// exists to find out what looks right before anyone can say why, and a hex
    /// answers "what if it were simply this colour" in one step. The hex bypasses
    /// the repair chain entirely, so a value set here can be illegible, on the
    /// owner's own theme and certainly on someone else's. It is a probe and not a
    /// candidate setting: what ships from an afternoon of dialling is a ratio.
    struct Inks: Sendable, Equatable {
        /// The minimum contrast ratio the sidebar's session-header ink targets.
        /// Today `PaneTheme.minimumTextContrast`, 4.5, WCAG AA for body text.
        public var sessionHeaderMinimumRatio: Double?

        /// An explicit `#RRGGBB` for the session-header ink, bypassing the repair
        /// chain. Wins over ``sessionHeaderMinimumRatio`` when both are set,
        /// since a named colour has no ratio left to satisfy.
        public var sessionHeaderHex: String?

        /// The minimum contrast ratio the sidebar's action-row ink targets.
        /// Today 4.5.
        public var actionRowMinimumRatio: Double?

        /// An explicit `#RRGGBB` for the action-row ink. Same bypass as
        /// ``sessionHeaderHex``.
        public var actionRowHex: String?

        /// The minimum contrast ratio `PaneTheme.sectionHeaderInk(on:)` targets,
        /// today 4.5.
        ///
        /// Separate from the two sidebar inks above even though all three sit at
        /// 4.5 today. The section header is the one already graded against a
        /// *bright glass* backdrop rather than against the bar, so it is the one
        /// whose repair actually fires, and folding it in with the others would
        /// hide which of the three a dial moved.
        public var sectionHeaderMinimumRatio: Double?

        /// An explicit `#RRGGBB` for the working-agent dot, today `PaneTheme.ok`.
        ///
        /// A hex with no ratio beside it, unlike the inks above, because the dot
        /// is a filled shape and not text: nothing is read off it, so there is no
        /// text-contrast floor for a repair chain to target.
        public var busyDotHex: String?

        public init() {}
    }
}

public extension Settings {
    /// This settings value with every dialled override standing in front of it.
    ///
    /// Pure, total, and idempotent: it reads nothing outside its two arguments,
    /// every field of ``DesignOverrides`` is either applied here or deliberately
    /// carried past (the chrome extras, which map to no field on this type), and
    /// applying the same overrides twice lands where applying them once did.
    /// `ConfigurationCenter` calls it before every derivation, so all three
    /// matter: a composition that read a clock or accumulated a delta would drift
    /// under exactly that use.
    ///
    /// Spelled as "replace the fields that are set" rather than "rebuild from the
    /// overrides", so a field this function has never heard of keeps its
    /// committed value instead of arriving as a zero. That is the same argument
    /// that leaves ``Settings`` without a public initializer.
    ///
    /// ``DesignOverrides/chrome`` is untouched on purpose and is not lost: those
    /// numbers reach drawing sites directly, so the app side reads them off the
    /// overrides value it already holds rather than out of the returned settings.
    func applying(_ overrides: DesignOverrides) -> Settings {
        var composed = self
        if let value = overrides.backgroundOpacity { composed.backgroundOpacity = value }
        if let value = overrides.backgroundBlur { composed.backgroundBlur = value }
        if let value = overrides.chromeStyle { composed.chromeStyle = value }
        if let value = overrides.attentionStyle { composed.attentionStyle = value }
        if let value = overrides.attentionAccent { composed.attentionAccent = value }
        if let value = overrides.focusAccent { composed.focusAccent = value }
        if let value = overrides.transparentTitlebar { composed.transparentTitlebar = value }
        return composed
    }
}
