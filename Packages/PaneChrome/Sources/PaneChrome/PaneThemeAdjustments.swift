import Foundation

/// The handful of ``PaneTheme`` constants the debug design panel can stand in
/// front of, carried as one value rather than reached for as globals.
///
/// **nil is the constant, never zero and never off.** Every field here shadows a
/// number that ships inside ``PaneTheme``, and an unset field leaves that number
/// exactly where it is. ``none`` — the value every existing call site gets by
/// default — is therefore the identity, and `PaneThemeAdjustmentsTests` asserts
/// that field by field rather than trusting the reading.
///
/// **A parameter, not a global.** `BaiaSettings.DesignOverrides.Chrome` is the
/// app-side shape these mirror, and this package deliberately does not import it
/// to read one: the app constructs this value from the composed overrides and
/// threads it through ``SettingsDerivations/paneTheme(from:adjustments:)``, so
/// the package stays pure and every derivation below stays reachable from a test
/// that can simply hand one in. A `DesignOverrides` read inside `PaneChrome`
/// would put a debug-only, app-composed value behind a derivation the flat
/// rendering also depends on, which is the seam this type exists to keep shut.
///
/// **Two dials per ink, and they are not the same kind of thing.** The ratio is
/// the honest one: it names the floor the repair chain in
/// ``PaneTheme/readable(_:on:minimumRatio:)`` targets, so raising it walks
/// further up the fallback chain *on every theme*, measured rather than guessed.
/// The hex bypasses the chain outright and can be illegible — on the owner's own
/// theme and certainly on anyone else's. It is offered because the panel exists
/// to answer "what if it were simply this colour" in one step, and it is a probe
/// rather than a candidate setting. See `DesignOverrides.Chrome.Inks` for the
/// longer form of that argument.
public struct PaneThemeAdjustments: Sendable, Equatable {
    /// Stands in for `PaneTheme.barLift`, today 0.08. A fraction, 0 through 1.
    ///
    /// The one field here that moves a *colour every ink is then measured
    /// against*: ``PaneTheme/barBackground`` is the backdrop the repair chain
    /// grades chrome text on, so setting this moves the text too. That is the
    /// effect working rather than a surprise.
    public var barLift: Double?

    // `sessionHeaderMinimumRatio` and `sessionHeaderInk` stood here until
    // 2026-08-12, and `actionRowMinimumRatio` and `actionRowInk` beside them
    // until later the same day. Each pair dialled one sidebar row's faint ink,
    // and the owner's rulings removed both rows: the session header was a fourth
    // copy of what the window title, the prompt and the capsule already say, and
    // the action row was a second face for the `New Tab` menu item. A dial whose
    // only site is gone is a knob that moves nothing.

    /// Stands in for ``PaneTheme/minimumTextContrast`` where
    /// ``PaneTheme/sectionHeaderInk(on:)`` targets it, today 4.5.
    ///
    /// **The only ink ratio left, and the one that was always doing the work.**
    /// It sat beside the action row's own until 2026-08-12 and was kept separate
    /// from it even though both read 4.5, because the section header is graded
    /// against a *bright glass* backdrop rather than against the bar, so it is
    /// the one whose repair actually fires; folding them together would have
    /// hidden which of the two a dial moved. The rulings that day settled that
    /// distinction by removing the other side of it, and the argument is kept
    /// because it is the reason this one is spelled per-site rather than as a
    /// single ratio for every ink in the app.
    public var sectionHeaderMinimumRatio: Double?

    /// An explicit colour for the working-agent dot, standing in for
    /// ``PaneTheme/ok``.
    ///
    /// A colour with no ratio beside it, unlike the inks above, because the dot
    /// is a filled shape and not text: nothing is read off it, so there is no
    /// text-contrast floor for a repair chain to target.
    public var busyDotInk: RGB?

    /// Nothing dialled: the identity every ``PaneTheme`` carries until an app
    /// hands it something else.
    public static let none = PaneThemeAdjustments()

    public init() {}
}
