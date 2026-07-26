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

    /// Hides the titlebar chrome while keeping the traffic lights and the native
    /// rounded corners. `window-decoration = none` is the alternative and it
    /// loses both.
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

    /// How the focused pane is marked. See ``FocusStyle``.
    public var focusStyle: FocusStyle

    /// Which derivation the focus colour comes from. See ``FocusAccent``.
    public var focusAccent: FocusAccent

    /// How hard an unacknowledged pane asks. Read through
    /// ``resolvedAttentionStyle`` rather than directly, since ``focusStyle`` can
    /// override it.
    public var attentionStyle: AttentionStyle

    /// How far an unfocused pane is scrimmed towards its own background, under
    /// ``FocusStyle/recede``.
    ///
    /// This is the one number in the design pass with a real cost attached, so
    /// it is the one that is settable. The owner watches agents in the panes he
    /// is not typing in, and the scrim is a deliberate tax on reading them: at
    /// 0.28 the foreground lands around 4.5:1 on the surface, still legible.
    /// ``Limits/scrim`` stops at 0.34 because past it the unfocused text is no
    /// longer comfortably readable, and a focus treatment that hides the output
    /// it is meant to help you scan has inverted its own purpose.
    public var unfocusedScrim: Double

    /// The attention treatment actually drawn, after ``focusStyle`` has had its
    /// say.
    ///
    /// ``FocusStyle/invert`` and ``AttentionStyle/loud`` both fill the footer,
    /// and a bar filled for two reasons carries neither. Resolved on read rather
    /// than repaired in a decoder or an initializer, so the stored value survives
    /// a round trip: someone who sets `loud`, tries `invert`, and goes back to
    /// `recede` gets the `loud` he asked for rather than a `quiet` written into
    /// his file behind his back.
    public var resolvedAttentionStyle: AttentionStyle {
        focusStyle == .invert ? .quiet : attentionStyle
    }

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
        backgroundOpacity: 0.85,
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
        focusStyle: .recede,
        focusAccent: .accent,
        attentionStyle: .loud,
        unfocusedScrim: 0.28
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

        /// The ceiling is the design's, not an arbitrary round number: past 0.34
        /// an unfocused pane's foreground drops under the contrast the bar's own
        /// text is held to, so the panes the owner is monitoring stop being
        /// readable. Zero is allowed and means the scrim is off, which is how
        /// someone who dislikes the treatment turns it off without having to
        /// know that `focusStyle` exists.
        static let scrim: ClosedRange<Double> = 0 ... 0.34
    }
}
