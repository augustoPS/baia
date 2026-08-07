import Foundation

/// Everything the owner can set in `~/.config/baia/config.json`.
///
/// The defaults are not a design exercise. They reproduce the owner's live
/// ghostty config, the terminal baia exists to replace, so a first launch with
/// no config file looks like the terminal already in use rather than like a new
/// program with opinions. The standing rule in the owner's vault is to match
/// chrome to the theme and never the reverse.
///
/// There is deliberately no public initializer. Every caller outside this module
/// starts from ``defaultSettings`` and mutates what it needs, so a field added
/// here later cannot reach an old call site as a zero value that still compiles
/// and then renders a 0 point font in a pane nobody can read.
public struct Settings: Sendable, Equatable {
    /// nil means ghostty's own font choice, which is what the owner's config
    /// leaves in place. Naming a font baia does not ship would be a guess that
    /// silently falls back to that same choice anyway.
    public var fontFamily: String?

    /// Points. Fractional on purpose: the owner runs 11.5, and rounding it to 11
    /// or 12 changes how many columns fit a pane.
    public var fontSize: Double

    /// A ghostty theme name, resolved by ghostty against its own theme list.
    /// baia does not validate it, because the list ships inside libghostty and
    /// is not readable from here.
    public var themeName: String

    /// `#RRGGBB` or the `#RGB` shorthand. Overrides whatever background the theme
    /// carries, which is the point: the theme's own black is pure black.
    public var backgroundHex: String

    /// 0 through 1, where 1 is opaque. Below 1 only shows anything with a
    /// compositor behind the window, so it pairs with ``backgroundBlur``.
    public var backgroundOpacity: Double

    /// The boolean, Gaussian-style blur behind a translucent window.
    public var backgroundBlur: Bool

    /// Points of padding between the window edge and the cell grid, on both axes.
    /// One value rather than two, because ghostty's `window-padding-x` and
    /// `window-padding-y` have never been set differently in the config this
    /// reproduces.
    public var windowPadding: Double

    /// Spreads the leftover pixels of a partial cell evenly instead of piling
    /// them against one edge, so a resized window stays visually centred.
    public var windowPaddingBalance: Bool

    /// **Retired, and kept only so existing config files keep decoding.**
    ///
    /// This was forwarded to ghostty as `macos-titlebar-style`, where it was
    /// read by nothing: that key configures a window ghostty created, and
    /// ghostty creates no window in baia. The platform titlebar is the treatment
    /// now — the workspace window carries an `NSToolbar` and takes the system's
    /// material and metrics — so there is nothing for this flag to select
    /// between. ``Settings/terminalOverrides`` carries the full reasoning.
    ///
    /// Decoding, writing and round-tripping are all unchanged, so a config that
    /// sets it is still valid and simply has no effect.
    public var transparentTitlebar: Bool

    /// Keeps `alt+f` and `alt+b` word jump alive on non-US keyboard layouts,
    /// where Option is otherwise a dead key composing accented characters.
    public var optionAsAlt: Bool

    public var cursorStyle: CursorStyle

    /// Directories to scan for projects. Tilde-expanded when read, so a walk
    /// never starts at a literal `~` directory that exists nowhere.
    public var projectRoots: [String]

    /// How many levels below a root a project may sit. The owner's workspace
    /// nests two deep in two places (`website/*` and `skills/*`), so a depth of 1
    /// would miss most of it.
    public var discoveryMaxDepth: Int

    /// Whether a finished agent posts a user notification. The per-tab indicator
    /// is not covered by this: a notification the user denied at the system level
    /// never appears and reports no error, so it can only ever be an addition to
    /// an indicator that already works.
    public var notificationsEnabled: Bool

    /// Seconds between git status reads for a pane.
    public var gitPollSeconds: Double

    /// Seconds between activity reads for a pane.
    public var activityPollSeconds: Double

    /// Whether tabs, pane trees, and working directories come back on launch.
    public var restoreSession: Bool

    /// Which derivation the focus colour comes from. See ``FocusAccent``.
    ///
    /// There is no companion key for the focus *treatment*. The focused pane
    /// wears a 2 pt frame around its footer and every other pane is left alone,
    /// which is one treatment for one problem, so there is nothing left to
    /// choose between.
    public var focusAccent: FocusAccent

    /// How hard an unacknowledged pane asks. See ``AttentionStyle``.
    public var attentionStyle: AttentionStyle

    /// Which derivation the attention signal is drawn from. See
    /// ``AttentionAccent``.
    ///
    /// The git segments do not follow it. Red still means conflict.
    public var attentionAccent: AttentionAccent

    /// What to do when the attention colour and the focus colour resolve to the
    /// same thing. See ``AlertBehavior``.
    public var alertBehavior: AlertBehavior

    /// Whether the chrome renders flat or asks for the v5 glass materials. See
    /// ``ChromeStyle``.
    ///
    /// Default `.flat`, so a config written before this key existed renders
    /// byte-identically. Reduce Transparency overrides whatever this says; that
    /// resolution happens in `PaneChrome`, not here, because it needs the live
    /// accessibility flag this package has no way to read.
    public var chromeStyle: ChromeStyle

    /// What the sidebar opens showing, or that there is none. See
    /// ``SidebarContent``.
    ///
    /// One key rather than one per surface, because there is one region. It shows
    /// what the footer cannot: the footer says `*3 ?1` on a line that must not
    /// wrap, and the sidebar names which three files are dirty and which one is
    /// untracked. The footer therefore stands nothing down when this is set, unlike
    /// the first draft of the design where the panel was to own branch and
    /// ahead-behind and the footer was to go quiet.
    public var sidebar: SidebarContent

    /// Whether the in-pane control channel answers a pane's requests.
    ///
    /// Default true. A pane reaches nothing outside itself and its own
    /// descendants, and peering needs a token a pane can only be handed by
    /// something that already trusts it, so an off-by-default channel would ship
    /// a feature nobody ever sees.
    ///
    /// False is a refusal and not an unbinding: the socket stays bound and every
    /// request is answered `disabled`. Unbinding was the first draft and it is
    /// wrong, because an unbound socket is indistinguishable from a dead app, so
    /// every pane's `baia` would report a launch failure that did not happen and
    /// the key would be unobservable from the diagnostic that has to prove it
    /// works.
    ///
    /// Read by `ControlServer` (seeded at startup through the same
    /// `settingsChanged` call the reload path uses, since 2026-08-07). When
    /// false, every verb answers `disabled`.
    public var controlChannelEnabled: Bool

    /// Whether the control channel's `run` verb is offered.
    ///
    /// Default false. Running a command in another pane is the one verb that
    /// turns a reach into an execution, so it stays off until someone asks for
    /// it by name in the file.
    ///
    /// False is not the same as the verb being absent, and the difference is the
    /// point. `run` is a declared verb at both settings, answering `disabled`
    /// when this is false and `refused` when it is true, since `run` itself
    /// lands in v2. Were the verb simply missing, both values would answer
    /// `unknownVerb`, a test flipping the key would pass, and the key would
    /// still reach nothing.
    ///
    /// Read by `ControlVerb`/`ControlServer`, seeded and reloaded alongside
    /// ``controlChannelEnabled``.
    public var controlAllowRun: Bool

    /// Whether `read` may answer with a descendant pane's lines.
    ///
    /// **Default true, unlike ``controlAllowRun``, and the difference is what the
    /// verb hands over.** `run` gives a pane execution in another pane's context,
    /// which is new authority. `read` gives it the screen of a pane it created and
    /// can already see, which is convenience rather than authority, so it is on
    /// out of the box.
    ///
    /// It has a key at all because it is still the one verb whose answer carries
    /// another pane's content, including whatever the owner typed into it. A
    /// capability that cannot be named cannot be switched off, and this one is
    /// worth being able to switch off.
    public var controlAllowRead: Bool

    /// The owner's ghostty config, field for field, transcribed from
    /// `vault/projects/ghostty/config.ghostty`.
    ///
    /// The background is lifted off pure black on purpose. The config comment
    /// records why: pure black amplifies the wallpaper bleed through a
    /// translucent window, which widens the perceived gap between a focused and
    /// an unfocused window rather than narrowing it.
    ///
    /// The blur is the boolean, Gaussian-style one. Liquid Glass, spelled
    /// `background-blur = macos-glass-clear` or `macos-glass-regular`, was tried
    /// and rejected: macOS desaturates those materials when the window is
    /// inactive, producing a colour shift that could not be suppressed. Do not
    /// reintroduce a glass value here.
    public static let defaultSettings = Settings(
        fontFamily: nil,
        fontSize: 11.5,
        themeName: "Dark Pastel",
        backgroundHex: "#141414",
        // 0.42 is design v5's well value, unblocked by the wells audit
        // (2026-08-05: every repair-chain promise holds at 0.42 over both
        // bounding backdrops, all 485 themes). 0.85 before that, the owner's
        // ghostty parity value, which the audit also re-verified.
        backgroundOpacity: 0.42,
        backgroundBlur: true,
        windowPadding: 8,
        windowPaddingBalance: true,
        transparentTitlebar: true,
        optionAsAlt: true,
        cursorStyle: .block,
        projectRoots: [Settings.expandingTilde("~/Projects")],
        discoveryMaxDepth: 3,
        notificationsEnabled: true,
        gitPollSeconds: 2,
        activityPollSeconds: 1,
        restoreSession: true,
        focusAccent: .accent,
        attentionStyle: .loud,
        attentionAccent: .alert,
        alertBehavior: .stock,
        // Glass by default since 2026-08-06, the owner's call with the wells
        // audit and the glass live pass in hand. Reduce Transparency still
        // forces flat through `resolvedStyle`, so this default never costs
        // legibility.
        chromeStyle: .glass,
        sidebar: .off,
        controlChannelEnabled: true,
        controlAllowRun: false,
        controlAllowRead: true
    )

    /// Expands a leading `~` the way a shell would.
    ///
    /// Environment variables are deliberately not expanded. `$HOME` would work
    /// and `$PROJECTS` would not, and a substitution that covers one name out of
    /// two is worse than none: the failing case looks like a path that exists.
    static func expandingTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// The bounds a decoded value has to satisfy.
    ///
    /// They live next to the type rather than inside the decoder because they are
    /// part of what a `Settings` means, and the tests read them by name instead of
    /// repeating the numbers.
    enum Limits {
        /// Below 4 points the grid is unreadable and above 72 a single cell fills
        /// a pane. Both are typos rather than intents.
        static let fontSize: ClosedRange<Double> = 4 ... 72

        /// ghostty clamps this key itself, so the range matches its parser rather
        /// than being a baia opinion: the same file has to behave the same way in
        /// both terminals.
        static let opacity: ClosedRange<Double> = 0 ... 1

        /// Padding wider than a small window leaves no cell grid at all, and
        /// ghostty renders that as an empty pane with no error.
        static let padding: ClosedRange<Double> = 0 ... 128

        /// A depth of 0 finds nothing, and the walk costs grow with the fan out
        /// of each level, so an accidental 40 would stat the whole home
        /// directory.
        static let discoveryDepth: ClosedRange<Double> = 1 ... 8

        /// A typo of 0 must not spin a poll timer at whatever rate the run loop
        /// will grant. The ceiling matters for the opposite reason: an hour is
        /// already indistinguishable from disabled, and a stray exponent would
        /// otherwise leave a feature reading as enabled while nothing fires.
        static let pollSeconds: ClosedRange<Double> = 0.25 ... 3600
    }
}
