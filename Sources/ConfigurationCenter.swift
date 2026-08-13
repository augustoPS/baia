import AppKit
import BaiaSettings
import GhosttyTerminal
import PaneChrome

/// The one object that reads `~/.config/baia/config.json`, derives everything
/// from it, and pushes the result into the app.
///
/// Panes stay passive. They expose settable properties and this writes them,
/// rather than each pane reaching for a global, so there is one place that knows
/// what a setting means and one place to look when a setting appears not to
/// apply.
@MainActor
final class ConfigurationCenter {
    private let store: SettingsStore

    /// What the config file says, exactly.
    ///
    /// **Committed, never composed.** ``effectiveSettings`` below is what every
    /// derivation reads; this is what the file holds, and the two differ only
    /// while the debug design panel has something dialled. The distinction has
    /// one consumer that depends on it: `SettingsWindowController` builds its
    /// draft and its "Current" sample column from this, and a sample built from
    /// the composed value would tell the owner his file contains a number that
    /// was never written to it.
    private(set) var settings: Settings

    #if DEBUG
        /// The debug design panel's ephemeral shadow over ``settings``, or nil
        /// when nothing is dialled.
        ///
        /// Debug-only in the strongest sense the language offers: the storage,
        /// the setter and the composition are all inside this fence, so a
        /// Release build has no property to hold, no branch to take, and
        /// ``effectiveSettings`` collapses to `settings` with nothing left to
        /// compile away. Grep `designOverrides` in the app target and every
        /// hit is fenced. The `DesignOverrides` *type* itself is unfenced in
        /// `BaiaSettings` and does ship in Release, because the `fillMaterial`
        /// properties on the surviving drawing sites are typed on
        /// `Chrome.Material`; in Release nothing can set them, so they resolve
        /// nil and every site draws its shipped fill. Dead value-type symbols
        /// were judged cheaper than losing the switch-without-default pin a
        /// Release-side stand-in type would cost (final review, 2026-08-07).
        ///
        /// **The app never writes overrides anywhere.** No `UserDefaults`, no
        /// write to `config.json`, no write to the watched file. The one file
        /// that can carry a dialled value between launches,
        /// `~/.config/baia/design-overrides.json`, is the *owner's* document and
        /// this object only ever reads it; see ``startWatchingDesignOverrides()``.
        /// The one place a dialled value is serialised at all is the design
        /// panel's Copy Values, and it goes to the clipboard. See
        /// ``BaiaSettings/DesignOverrides`` for why a dial is a question rather
        /// than an answer, and why every field is optional.
        private var storedDesignOverrides: DesignOverrides?

        /// The dialled overrides, and the one write path into them.
        ///
        /// Setting this fires the same two calls a settings-file reload fires,
        /// in the same order, so a dialled value rides exactly the plumbing a
        /// committed one does and nothing downstream can tell them apart. It
        /// fires unconditionally rather than guarding on a change: the panel
        /// writes a whole value per control event, and every consumer's `didSet`
        /// drops an unmoved value at its own end.
        ///
        /// **That last clause was false when this was written and three
        /// properties had to be fixed to make it true**: the palette's `theme`
        /// and the sidebar's `theme` and `backgroundOpacity` had no equality
        /// guard while every sibling around them did, so each unmoved write
        /// repainted a surface. It cost one wasted repaint per settings-file
        /// save before this, which is why nobody had noticed; a panel dialling
        /// at control-event rate is what turns that into a visible cost. A
        /// consumer added later without a guard puts the cost back, and this
        /// paragraph is the record of where to look.
        ///
        /// The panel is the only writer outside tests. It is created once and
        /// owned by `AppDelegate` (`onSettingsChange` has no unregister), so
        /// nothing here needs to defend against a second one.
        var designOverrides: DesignOverrides? {
            get { storedDesignOverrides }
            set {
                storedDesignOverrides = newValue
                applyToEveryPane()
                notifySettingsChanged()
            }
        }
    #endif

    /// The settings every derivation on this object reads: ``settings`` with
    /// the debug panel's overrides composed over it, or ``settings`` itself
    /// when nothing is dialled and always in Release.
    ///
    /// **One property rather than a composition at each call site.** The
    /// derivations, ``resolvedChrome`` and the three window gates all read this,
    /// so there is no site that could be missed and left rendering the committed
    /// value beside neighbours rendering the dialled one. That failure has a
    /// name in this codebase: `focusAccent` was decoded, stored, and never read
    /// by the one line that mattered (`PaneTheme+Palette.swift`), and the fix
    /// was moving resolution to where a caller cannot skip it.
    ///
    /// **Composes nothing that Reduce Transparency then cannot overrule.**
    /// `Settings.applying(_:)` is a pure value-to-value map with no appearance
    /// in it; the accessibility guard lives one layer down in
    /// `PaneChrome.resolvedStyle(setting:materialIsDark:appearance:)`, above
    /// its material branch, and reads the live observer *after* this composition
    /// has happened. So `chromeStyle: .glass` dialled on a machine with Reduce
    /// Transparency on changes the setting and correctly changes nothing on
    /// screen. `PaneChromeTests` pins that ordering from the package side.
    ///
    /// In Release this is `settings` with no storage, no branch and no call
    /// behind it.
    var effectiveSettings: Settings {
        #if DEBUG
            guard let storedDesignOverrides else { return settings }
            return settings.applying(storedDesignOverrides)
        #else
            settings
        #endif
    }

    /// The dialled chrome extras: the numbers that map to no ``Settings`` field
    /// and reach drawing sites directly. Empty when nothing is dialled, and
    /// always empty in Release.
    ///
    /// **The other half of ``effectiveSettings``, and the reason it is a
    /// property here rather than a read of `designOverrides` at each site.**
    /// `Settings.applying(_:)` deliberately carries ``DesignOverrides/chrome``
    /// past untouched — those values have no settings field to compose into —
    /// so the app has to read them off the overrides value directly. Doing that
    /// once, here, is what stops a drawing site being missed and left on its
    /// constant while its neighbours follow a dial: the same argument
    /// ``effectiveSettings``' own doc comment makes, and the same defect
    /// (`focusAccent`, decoded and stored and never read by the one line that
    /// mattered) it names.
    ///
    /// Every field is still optional inside this value. Nil is the constant the
    /// site already draws, never zero and never off; the drawing sites hold
    /// their own defaults and this only ever stands in front of them.
    ///
    /// In Release this is a fresh empty value with no storage and no branch
    /// behind it, and every `??` downstream of it collapses to its constant.
    var chromeOverrides: DesignOverrides.Chrome {
        #if DEBUG
            storedDesignOverrides?.chrome ?? DesignOverrides.Chrome()
        #else
            DesignOverrides.Chrome()
        #endif
    }

    /// The live system state the window gates need: dark/light, Reduce
    /// Transparency, Reduce Motion. Held rather than read fresh on every
    /// `resolvedChrome` access, so a burst of reads inside one render pass sees
    /// one appearance rather than a value that could change mid-frame if the
    /// observer fired between two of them.
    ///
    /// Of the three fields, `reduceTransparency` is the one that reaches
    /// ``resolvedChrome`` — `isDark` no longer picks a material set, and no
    /// consumer of it is left; see `ChromeAppearance.isDark`'s own doc comment.
    ///
    /// Constructor-injected, never a later assignment a caller can forget:
    /// the `focusAccent` lesson (`PaneTheme+Palette.swift`) is exactly a
    /// settings key that reached everything except the one line that read it,
    /// and the fix there was moving resolution to where a parameter cannot be
    /// skipped. `appearanceObserver` is the same shape applied one layer
    /// earlier: nothing here can construct a `ConfigurationCenter` without
    /// naming where its appearance comes from.
    private let appearanceObserver: AppearanceObserver

    /// Everything to run after `settings` or the live appearance moves, for the
    /// app-level consumers that are not panes: the project roots, session
    /// restore, the notifier, and the settings window's "Current" sample. Both
    /// sources feed the same list because both change what `resolvedChrome`
    /// answers, and a caller that only reacted to one would draw glass a frame
    /// late after a Reduce Transparency toggle.
    ///
    /// A list rather than the single `var onSettingsChange` this was until the
    /// settings window needed one too. A second consumer assigning over the
    /// property would have silently unwired `AppDelegate.settingsDidChange()`,
    /// which is a whole app's worth of live-following (`AppDelegate.swift`'s own
    /// loop over every window) going quiet with nothing on screen to say so.
    private var settingsChangeHandlers: [() -> Void] = []

    /// Registers `handler` to run on every subsequent change.
    ///
    /// **Returns nothing, and there is no way to unregister**, which is a choice
    /// with a known cost rather than an oversight. Every consumer either outlives
    /// this object (`AppDelegate`) or captures itself weakly and no-ops once it
    /// has gone (`SettingsWindowController`), so nothing is kept alive by being
    /// registered and no handler can write into a torn-down surface.
    ///
    /// What it does cost: `AppDelegate.showSettings(_:)` rebuilds its controller
    /// on every ⌘, so the list gains one dead entry per visit to Settings and
    /// never gives one back. A dead entry is a weak load and a branch, and the
    /// count is bounded by how many times a person opens a settings window
    /// between relaunches, so this is measured in nanoseconds and tens of bytes.
    /// The alternative bought with a token type and a bookkeeping dictionary is
    /// not worth it yet. Revisit if a consumer ever registers from something
    /// created per pane, per window, or on a timer, where the bound stops being
    /// a human pressing a key.
    func onSettingsChange(_ handler: @escaping () -> Void) {
        settingsChangeHandlers.append(handler)
    }

    /// Runs every registered handler, in registration order.
    ///
    /// The order is not load-bearing and no handler may make it so: the two fire
    /// sites are a settings reload and an appearance change, and a consumer that
    /// needed to run before or after another would be reaching across a boundary
    /// this list exists to keep flat.
    private func notifySettingsChanged() {
        for handler in settingsChangeHandlers { handler() }
    }

    /// Every live pane, held weakly.
    ///
    /// `NSHashTable.weakObjects` rather than an array, because a strong reference
    /// here would be a leaked pane, and a leaked pane is a leaked shell:
    /// libghostty exposes no way to close a surface, and the pty dies only when
    /// the view deallocates. Nothing unregisters; a deallocated pane leaves the
    /// table on its own.
    private let panes = NSHashTable<TerminalPaneController>.weakObjects()

    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWorkItem: DispatchWorkItem?

    #if DEBUG
        private var designOverridesWatcher: DispatchSourceFileSystemObject?
        private var designOverridesReloadWorkItem: DispatchWorkItem?
        private var designOverridesDirectoryWatcher: DispatchSourceFileSystemObject?
    #endif

    init(
        store: SettingsStore = SettingsStore(fileURL: SettingsStore.defaultFileURL()),
        appearanceObserver: AppearanceObserver = AppearanceObserver()
    ) {
        self.store = store
        self.appearanceObserver = appearanceObserver
        // Written before the first read, so a first launch leaves the owner a
        // fully populated file to edit rather than nothing at all. Never
        // overwrites, and races safely: the write is `O_EXCL`.
        _ = store.writeDefaultIfAbsent()
        let result = store.load()
        settings = result.settings
        Self.report(result)
        startWatching()
        #if DEBUG
            // Read once before the watcher is armed, so a file already on disk at
            // launch is in effect from the first frame rather than from the first
            // save after launch. Absent is the ordinary case and costs nothing.
            reloadDesignOverrides()
            startWatchingDesignOverrides()
        #endif
        appearanceObserver.onAppearanceChange = { [weak self] _ in
            guard let self else { return }
            // `resolvedChrome` reads `appearanceObserver.appearance` fresh on
            // every access, so by the time this closure runs the observer has
            // already updated and `apply(to:)` picks up the new resolution.
            // Without this, dark/light and Reduce Transparency moved the value
            // `resolvedChrome` answers but no pane redrew until some unrelated
            // settings-file edit forced a reload, which is exactly the stale
            // frame `settingsChangeHandlers`' own doc comment says both sources
            // must not leave behind.
            applyToEveryPane()
            notifySettingsChanged()
        }
    }

    // MARK: - Chrome resolution

    /// What the chrome should draw right now: flat, or glass with the material
    /// set the *theme's* own darkness picks.
    ///
    /// `PaneChrome.resolvedStyle(setting:materialIsDark:appearance:)` does the
    /// actual resolution and carries its own tests; this is the one line that
    /// calls it with the three live inputs.
    ///
    /// **`materialIsDark` is ``windowIsDark`` — this line's own neighbour below
    /// — rather than the observer's `isDark`, which is what makes this property
    /// read the way this comment has always promised: the chrome follows the
    /// theme.** Until that parameter existed, the observer's
    /// `NSApp.effectiveAppearance` read chose the material set, so a dark theme
    /// under a light system appearance drew light glass in the footer, the
    /// sidebar, the palette and the popover while the titlebar above them —
    /// already on `windowIsDark` — rendered correctly dark. Passing one
    /// derivation to both is what stops the two disagreeing, and it is why a
    /// system light/dark switch with the theme unmoved now repaints nothing.
    ///
    /// `appearanceObserver.appearance` is still passed and still matters: Reduce
    /// Transparency lives there and keeps its authority to force `.flat`, which
    /// no theme may override.
    ///
    /// State ink never reads this: grep `PaneStatusSegments.swift`,
    /// `PaneTheme.swift`, and `PaneTheme+Palette.swift` for `ChromeAppearance`
    /// or `resolvedChrome` and find nothing, the same acceptance
    /// `SettingsDerivations.paneTheme` holds for `focusAccent`.
    ///
    /// **The setting comes from ``effectiveSettings``, so the debug design
    /// panel's dialled `chromeStyle` reaches here exactly as a committed one
    /// does, and Reduce Transparency keeps its authority over both.** The
    /// composition is a pure value map that happens before this call; the
    /// force-flat guard is inside `resolvedStyle` and reads
    /// `appearanceObserver.appearance` live, below the composition rather than
    /// beside it. Dialling glass with the accessibility flag set therefore
    /// moves the setting and leaves the screen flat, which is the ordering
    /// working. In Release `effectiveSettings` *is* `settings` and this line
    /// reads exactly what it read before the panel existed.
    var resolvedChrome: ResolvedChrome {
        resolvedStyle(
            setting: effectiveSettings.chromeStyle,
            materialIsDark: windowIsDark,
            appearance: appearanceObserver.appearance
        )
    }

    /// Whether the workspace window should be non-opaque right now.
    ///
    /// The companion of ``resolvedChrome`` immediately above, and the same
    /// shape: `PaneChrome.windowIsTransparent(backgroundOpacity:appearance:)`
    /// makes the decision and carries the tests, this is the one line that
    /// calls it with the two live inputs. Deliberately reads
    /// `backgroundOpacity` rather than `chromeStyle` — window transparency
    /// follows the opacity setting, not the chrome style (owner decision,
    /// 2026-08-07); see that function's own doc comment. Through
    /// ``effectiveSettings``, so a dialled opacity moves the window the same
    /// way a committed one does.
    var windowIsTransparent: Bool {
        PaneChrome.windowIsTransparent(
            backgroundOpacity: effectiveSettings.backgroundOpacity,
            appearance: appearanceObserver.appearance
        )
    }

    /// Whether the workspace window's own chrome — titlebar material, tab bar —
    /// should render dark right now.
    ///
    /// Reads ``paneTheme`` and takes no `appearanceObserver.appearance` at all,
    /// which is what separates it from ``windowIsTransparent`` and
    /// ``windowBlurRadius`` beside it: those two are legitimately keyed off the
    /// *system* appearance and Reduce Transparency, but the titlebar is chrome,
    /// and the standing rule (`PaneTheme`'s own header) is that chrome matches
    /// the theme and never the system. `PaneChrome.windowIsDark(paneTheme:)`
    /// carries the rest of that reasoning and the tests.
    ///
    /// **Read twice, and deliberately: ``resolvedChrome`` above passes this
    /// value as its `materialIsDark`.** So the window's own appearance and the
    /// glass material inside it come from one derivation rather than from two
    /// that could drift, and a theme edit moves both in the frame that
    /// `applyToEveryPane()` and `notifySettingsChanged()` already re-theme the
    /// panes in.
    var windowIsDark: Bool {
        PaneChrome.windowIsDark(paneTheme: paneTheme)
    }

    /// How far the compositor should blur what shows through the workspace
    /// window right now, or `0` for no blur.
    ///
    /// The third of these one-line derivations and the same shape as the two
    /// above: `PaneChrome.windowBlurRadius(backgroundBlur:backgroundOpacity:appearance:paneGlassActive:)`
    /// holds the rule and the tests, and this passes it the four live inputs.
    /// It reads `backgroundBlur` *and* `backgroundOpacity` (both off
    /// ``effectiveSettings``, like its two neighbours) because blur is gated on
    /// the window being transparent at all — see that function's own doc
    /// comment — which is also how Reduce Transparency reaches it without this
    /// line mentioning the flag.
    ///
    /// The fourth input is the live ``resolvedChrome``, read here rather than
    /// stored: glass panes turn the compositor blur off entirely, because the
    /// plane behind them already does the lensing. That means a *mixed* window
    /// — panes spawned under glass still running after a live flip to flat, or
    /// the reverse — briefly gets a radius matching the setting rather than
    /// each pane, since one window has one backdrop and the panes in it do not.
    /// It costs nothing visible: `Diagnostics/pane-glass-blur` measured the
    /// blur under a plane as invisible either way, so the transient is a
    /// compositor pass appearing or disappearing where nobody can see it.
    var windowBlurRadius: Int {
        PaneChrome.windowBlurRadius(
            backgroundBlur: effectiveSettings.backgroundBlur,
            backgroundOpacity: effectiveSettings.backgroundOpacity,
            appearance: appearanceObserver.appearance,
            paneGlassActive: { if case .glass = resolvedChrome { true } else { false } }()
        )
    }

    // MARK: - Derivations

    /// The theme currently in effect.
    var terminalTheme: TerminalTheme { SettingsDerivations.terminalTheme(from: effectiveSettings) }

    /// The session configuration currently in effect.
    var terminalConfiguration: TerminalConfiguration {
        SettingsDerivations.terminalConfiguration(from: effectiveSettings)
    }

    /// ``terminalConfiguration``, with `window-padding-y` raised by
    /// ``PaneChrome/PaneStatusBarMetrics/glassWindowPaddingBump`` — arrangement
    /// (B) from the glass-backdrop spike's verdict, for a pane whose surface
    /// was built to extend under the footer bar.
    ///
    /// Built from ``settings/windowPadding`` directly rather than by reading
    /// the padding back out of `terminalConfiguration`: `TerminalConfiguration`
    /// carries its accumulated commands as `internal` state (`GhosttyTerminal`
    /// keeps `commands` unexported), so there is nothing here to reach in and
    /// inspect even if that were the right way to do it, and it would not be —
    /// this reads the one input that actually decided the base value.
    ///
    /// Appended after everything `terminalOverrides` already renders, which is
    /// what makes this safe to compose rather than something that has to
    /// duplicate `TerminalOverride.windowPadding`'s own rounding rule twice:
    /// ghostty's config parser takes the *last* value it reads for a scalar
    /// key, the same rule `SettingsDerivations.terminalTheme` leans on to fold
    /// a background override on top of a theme, so one more `window-padding-y`
    /// line after the settings-derived one simply wins.
    ///
    /// `TerminalPaneController.bottomArrangementAtSpawn` decides which of
    /// this, ``glassClearTerminalConfiguration`` or ``terminalConfiguration``
    /// a given pane is handed, frozen at that pane's spawn; see
    /// `spawnedUnderGlass`'s doc comment for why a pane already running must
    /// never be moved between them. This one is `.fullHeightWithBump`'s:
    /// glass, with the footer floating over the surface's last points.
    ///
    /// `background-opacity` is appended for the same reason and on the same
    /// last-value-wins rule as the padding line above, and it goes to `0`: under
    /// glass the well belongs to the plane and the wash, so the pane's own Metal
    /// layer must stop painting a second one over them. That doubled well is the
    /// difference between what `Diagnostics/pane-glass-legibility` measured and
    /// what would otherwise ship. The settings key keeps its value and its other
    /// readers — ``windowIsTransparent`` and the wash both still resolve off
    /// `effectiveSettings.backgroundOpacity`; this zeroes the *surface*, not the
    /// setting. The per-pane freeze through `isSpawnedUnderGlass` is unchanged:
    /// a pane still gets this configuration or ``terminalConfiguration`` once,
    /// at spawn, and is never moved between them.
    var glassCompensatedTerminalConfiguration: TerminalConfiguration {
        terminalConfiguration
            .windowPaddingY(
                Int((effectiveSettings.windowPadding + PaneStatusBarMetrics.glassWindowPaddingBump).rounded())
            )
            .backgroundOpacity(0)
    }

    /// ``glassCompensatedTerminalConfiguration``'s `background-opacity`
    /// zeroing without its padding bump, for a glass pane spawned with no
    /// footer (`.fullHeightClear` under glass). The well still belongs to the
    /// plane and the wash, so the surface must not paint a second one over
    /// them, but no bar floats over the surface's last points, so there is
    /// nothing for a `window-padding-y` bump to clear and the settings-derived
    /// padding stands. Frozen per pane on the same terms as the other two.
    var glassClearTerminalConfiguration: TerminalConfiguration {
        terminalConfiguration.backgroundOpacity(0)
    }

    /// The configuration and theme `settings` would produce, without applying them.
    ///
    /// Exposed for the settings window's right-hand sample, so a draft renders
    /// through exactly the derivation a pane gets. A second mapping written inside
    /// the window is how a sample comes to show what the panes will not, which is
    /// the one defect that would make the comparison worthless.
    func derivations(for settings: Settings) -> (TerminalConfiguration, TerminalTheme) {
        (
            SettingsDerivations.terminalConfiguration(from: settings),
            SettingsDerivations.terminalTheme(from: settings)
        )
    }

    /// The chrome palette currently in effect, with the dialled ink and bar-lift
    /// adjustments standing in front of the theme's own constants.
    ///
    /// ``paneThemeAdjustments`` is nothing at all unless the panel has dialled
    /// one of its five fields, and `PaneThemeAdjustments.none` is asserted to be
    /// the exact identity of every derivation it reaches
    /// (`PaneThemeAdjustmentsTests`), so this reads as it always did until
    /// something is dialled.
    var paneTheme: PaneTheme {
        SettingsDerivations.paneTheme(from: effectiveSettings, adjustments: paneThemeAdjustments)
    }

    /// The chrome palette `settings` would produce.
    ///
    /// Parameterised for the same reason the terminal derivations are: the
    /// settings window renders a draft through it, and a second mapping written
    /// inside the window is how a preview comes to show what the panes will not.
    ///
    /// **No adjustments, deliberately.** This builds the sample the settings
    /// window shows for a *draft of the config file*, and the extras are never
    /// written to that file — they are ephemeral by construction (see
    /// ``BaiaSettings/DesignOverrides``). A sample carrying a dialled bar lift
    /// would tell the owner his draft contains a number nothing will ever save,
    /// which is the same objection that keeps ``settings`` committed rather than
    /// composed.
    func chrome(for settings: Settings) -> PaneTheme {
        SettingsDerivations.paneTheme(from: settings)
    }

    /// The dialled ``PaneTheme`` constants, translated from the chrome extras
    /// into the package's own vocabulary.
    ///
    /// **The one place the hexes are parsed**, and a hex the parser rejects is
    /// dropped rather than substituted: `RGB(hex:)` answers nil, the field stays
    /// nil, and the ink falls back to its repair chain. A half-typed `#ff` in a
    /// live text field would otherwise flash black across the sidebar on the way
    /// to being finished, and black is a legitimate colour, so a substitution
    /// would look like a deliberate choice with nothing to notice.
    ///
    /// The ratios are passed through unclamped. They are a floor handed to
    /// ``PaneChrome/PaneTheme/readable(_:on:minimumRatio:)``, whose fallback
    /// chain terminates at white or black whatever the target, so an
    /// unsatisfiable 30:1 walks the chain to its end and stops rather than
    /// looping or trapping.
    private var paneThemeAdjustments: PaneThemeAdjustments {
        let inks = chromeOverrides.inks
        var adjustments = PaneThemeAdjustments.none
        adjustments.barLift = chromeOverrides.barLift
        adjustments.sectionHeaderMinimumRatio = inks.sectionHeaderMinimumRatio
        adjustments.busyDotInk = inks.busyDotHex.flatMap(RGB.init(hex:))
        return adjustments
    }

    // MARK: - Applying

    /// Adds a pane and configures it immediately.
    func register(_ pane: TerminalPaneController) {
        panes.add(pane)
        apply(to: pane)
    }

    private func applyToEveryPane() {
        for pane in panes.allObjects {
            apply(to: pane)
        }
    }

    // MARK: - Committing

    /// Writes `settings` to the config file, answering whether it landed.
    ///
    /// Applies nothing. The write moves the file, the watcher notices, and
    /// `reload` applies it exactly as it applies a hand-edit. So the settings
    /// window is not a second path into the panes and cannot disagree with the
    /// file about what is in effect.
    ///
    /// This exists only because `store` is private and the window has no other
    /// way to reach the file.
    func commit(_ settings: Settings) -> Bool {
        store.write(settings)
    }

    private func apply(to pane: TerminalPaneController) {
        pane.theme = paneTheme
        pane.attentionStyle = effectiveSettings.attentionStyle
        // Straight through, the way `attentionStyle` and `focusAccent` are. The
        // resolution is `PaneTheme.attentionColour(_:behavior:)`, which has tests;
        // a line here that decided anything about these two would not, and that is
        // exactly how `focusAccent` came to be decoded, stored, and never read.
        pane.attentionAccent = effectiveSettings.attentionAccent
        pane.alertBehavior = effectiveSettings.alertBehavior
        pane.gitPollInterval = effectiveSettings.gitPollSeconds
        pane.activityPollInterval = effectiveSettings.activityPollSeconds
        // `resolvedChrome` is computed fresh from the same two live inputs this
        // method already closes over (`settings` and the appearance observer's
        // last value), so it stays correct whether `apply` runs from `register`,
        // a settings reload, or an appearance change.
        pane.resolvedChrome = resolvedChrome
        // The focused pane's lift and the lens rim, from the chrome extras.
        // Both resolve to today's rendering with nothing dialled — the lift to
        // its constants, the rim to absent — and in Release neither can be
        // anything else. Assigned here rather than at pane construction so a
        // dial reaches panes that are already open, which is every pane the
        // owner is looking at while he dials.
        pane.liftParameters = .from(chromeOverrides.lift)
        pane.rimParameters = .from(chromeOverrides.rim)
        // The pane wash's two inputs: the owner's one opacity knob and the
        // floor override under it (`ChromeMaterials.PaneWash.opacity`). Both
        // are appearance-only. They reach a view drawn behind the surface at
        // the pane's full bounds and never the surface's frame or padding, so
        // neither can move a live grid the way a padding change would.
        pane.backgroundOpacity = effectiveSettings.backgroundOpacity
        pane.paneWashFloor = chromeOverrides.paneWashFloor
        // The pane cluster's two dials (`chrome.cluster.*`). Both are
        // appearance-only on a running pane: the capsule is an overlay pinned
        // over the surface, so neither reaches the grid.
        //
        // **A third assignment stood here until 2026-08-13:
        // `pane.clusterMode = chromeOverrides.cluster.resolvedMode`.** The
        // dial behind it retired with the gate, so the pane's `clusterMode`
        // is now a constant the property initialises itself to and this
        // method has nothing to feed it. What that assignment did at spawn
        // beyond gating the capsule — freezing `bottomArrangementAtSpawn`,
        // read below to pick the configuration — it did by being in place
        // before that read, and a constant is in place earlier still.
        pane.clusterCornerInset = chromeOverrides.cluster.cornerInset
        pane.clusterOpacity = chromeOverrides.cluster.opacity
        // The footer's glass tint was assigned here until 2026-08-09, from
        // `chromeOverrides.surfaces.footer`. Both went with the glass view they
        // wrote to; see `DesignOverrides.Chrome`.
        //
        // Both go through the controller rather than through the view.
        // Assigning `view.configuration` or `view.controller` has a `didSet`
        // that tears the surface down and respawns the shell, losing the
        // scrollback and whatever was running in the pane.
        //
        // **Which configuration, not just whether one applies.** Reading
        // `pane.bottomArrangementAtSpawn` here rather than branching on the
        // live `resolvedChrome` assigned above is
        // deliberate: that property is frozen at this pane's first
        // configuration (see `spawnedUnderGlass`'s doc comment), so a pane
        // spawned under flat keeps taking `terminalConfiguration` even after
        // a live toggle moves `resolvedChrome` to glass, and a pane spawned
        // under glass keeps its `+glassWindowPaddingBump` even after a toggle
        // moves back to flat. Either direction, changing which configuration
        // an already-running pane receives would move its `window-padding-y`
        // on a live surface, which is a live grid resize — the SIGWINCH
        // hazard arrangement (B) was built to avoid, not to relocate to a
        // settings reload.
        //
        // The cluster case rode the same freeze while the mode was dialable,
        // and since 2026-08-13 it is no longer a case: every pane wears the
        // capsule and none wears a footer, so `clusterOnly` is constant and
        // the arrangement is `.fullHeightClear` unless the pane spawned under
        // glass. The freeze stays because `resolvedChrome` still moves under
        // a live toggle. This is also the first read of the frozen pair, and
        // it runs at registration — after `resolvedChrome` is assigned above,
        // before the view loads — which is what "at spawn" means concretely.
        let spawnConfiguration: TerminalConfiguration = switch pane.bottomArrangementAtSpawn {
        case .insetAboveBar: terminalConfiguration
        case .fullHeightWithBump: glassCompensatedTerminalConfiguration
        case .fullHeightClear:
            pane.isSpawnedUnderGlass ? glassClearTerminalConfiguration : terminalConfiguration
        }
        pane.applyTerminalConfiguration(spawnConfiguration, theme: terminalTheme)
    }

    // MARK: - Watching

    /// Watches the config file for edits.
    ///
    /// `.rename` and `.delete` are watched alongside `.write` because most
    /// editors do not write in place. `vim` and any atomic save write a new inode
    /// and rename it over the old path, which fires delete on this descriptor and
    /// leaves the watcher pointed at a file nobody will ever write again. The
    /// re-arm is what keeps the second save working.
    private func startWatching() {
        stopWatching()
        let path = SettingsStore.defaultFileURL().path(percentEncoded: false)
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            if event.contains(.delete) || event.contains(.rename) {
                // The path now names a different inode, or none. Re-arm against
                // the path rather than the descriptor, after long enough for the
                // rename to land.
                scheduleReload(rearm: true)
            } else {
                scheduleReload(rearm: false)
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    /// Coalesces a burst of events into one reload.
    ///
    /// A single save produces several: a truncate, one or more writes, and an
    /// extend. Reloading on each would re-theme every pane two or three times
    /// per keystroke-in-an-editor, and reloading mid-write would read a
    /// half-written file and report every key in it as invalid.
    private func scheduleReload(rearm: Bool) {
        reloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if rearm { startWatching() }
            reload()
        }
        reloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    #if DEBUG
        // MARK: - Watching the design overrides

        /// `~/.config/baia/design-overrides.json`: the file the owner dials in
        /// while the panel's own controls are not to be trusted.
        ///
        /// Beside `config.json` deliberately, in the directory the owner already
        /// opens to edit settings, so there is one place to look for everything
        /// baia reads. The name says what it holds rather than that it is debug
        /// state, because it is the only thing in that directory a Release build
        /// will not read at all.
        ///
        /// **baia never writes this path.** There is no first-launch default and
        /// no save-back, unlike ``BaiaSettings/SettingsStore/writeDefaultIfAbsent()``
        /// beside it. The file is the owner's input, its absence is the ordinary
        /// state, and deleting it is how a dialling session is reset.
        static func designOverridesFileURL() -> URL {
            SettingsStore.defaultFileURL()
                .deletingLastPathComponent()
                .appending(path: "design-overrides.json")
        }

        /// Watches the design-overrides file for edits.
        ///
        /// **A second source rather than a branch inside ``startWatching()``, and
        /// the reason is not tidiness.** A `DispatchSourceFileSystemObject`
        /// watches one descriptor, so a second path needs a second source
        /// whichever way this is arranged; sharing the debounce work item would
        /// then let a `config.json` save cancel a pending overrides reload and
        /// drop it, since ``scheduleReload(rearm:)`` cancels whatever is
        /// outstanding. And the settings watcher must stay unfenced — it is the
        /// only path into `settings` in Release — so folding this in would put
        /// `#if DEBUG` inside its event handler rather than around a method.
        ///
        /// The rest is ``startWatching()``'s shape for ``startWatching()``'s
        /// reasons: `.rename` and `.delete` are watched alongside `.write`
        /// because most editors do not save in place, and the re-arm against the
        /// path is what keeps the second save working.
        ///
        /// One thing it needs that the settings watcher does not: **this file is
        /// normally absent**, and `open` on a path that does not exist gives no
        /// descriptor to watch. `config.json` is written on first launch so it
        /// always exists; this one appears the moment the owner first saves it,
        /// which would be after the app started. So an absent file falls back to
        /// watching the *directory*, which does exist, and re-arms on the path
        /// once something with that name lands in it.
        private func startWatchingDesignOverrides() {
            stopWatchingDesignOverrides()
            let path = Self.designOverridesFileURL().path(percentEncoded: false)
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else {
                watchDesignOverridesDirectory()
                return
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .extend],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let event = source.data
                if event.contains(.delete) || event.contains(.rename) {
                    scheduleDesignOverridesReload(rearm: true)
                } else {
                    scheduleDesignOverridesReload(rearm: false)
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            designOverridesWatcher = source
        }

        /// Watches `~/.config/baia/` for the overrides file appearing.
        ///
        /// The file's absence is the ordinary state, so this is the arm that runs
        /// on most launches. A directory source fires on any change inside it,
        /// including every `config.json` save, which is why the handler goes
        /// through the same debounce and the same reload as everything else: an
        /// unrelated write finds the overrides file still absent, parses nothing,
        /// and assigns nil over nil, which the equality guard in
        /// ``reloadDesignOverrides()`` drops before it can re-theme anything.
        private func watchDesignOverridesDirectory() {
            let directory = Self.designOverridesFileURL().deletingLastPathComponent()
            let descriptor = open(directory.path(percentEncoded: false), O_EVTONLY)
            guard descriptor >= 0 else { return }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                // Always re-arms: the point of this source is to notice the file
                // arriving, and arming on the path is what has to happen once it
                // has. `startWatchingDesignOverrides` falls back here again when
                // the event was some other file in the directory.
                self?.scheduleDesignOverridesReload(rearm: true)
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            designOverridesDirectoryWatcher = source
        }

        private func stopWatchingDesignOverrides() {
            designOverridesWatcher?.cancel()
            designOverridesWatcher = nil
            designOverridesDirectoryWatcher?.cancel()
            designOverridesDirectoryWatcher = nil
        }

        /// Coalesces a burst of events into one reload, for
        /// ``scheduleReload(rearm:)``'s reasons: one save is several events, and
        /// reloading mid-write reads a half-written file and reports it as
        /// broken. It matters more here than it does there, because this file is
        /// saved repeatedly inside one session and every reload re-themes every
        /// pane.
        ///
        /// Its own work item, so a `config.json` save cannot cancel a pending
        /// overrides reload or the other way round.
        private func scheduleDesignOverridesReload(rearm: Bool) {
            designOverridesReloadWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if rearm { startWatchingDesignOverrides() }
                reloadDesignOverrides()
            }
            designOverridesReloadWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
        }

        /// Reads the file and dials what it says, or keeps what is dialled and
        /// says why it could not.
        ///
        /// Three outcomes, and the middle one is the one worth naming:
        ///
        /// - **Absent, or parsing to nothing dialled.** `designOverrides` becomes
        ///   nil, which is Reset: the center's `effectiveSettings` short-circuits
        ///   and the app is back on exactly what the config file says. So
        ///   deleting the file, or emptying it, is how a session ends.
        /// - **Unparseable.** The current overrides are kept and the message goes
        ///   to stderr the way ``report(_:)`` sends the settings decoder's
        ///   complaints. Dropping to nil on a bad parse would make every
        ///   half-typed save flash the whole window back to the committed look,
        ///   which is unreadable to dial against; keeping the last good value
        ///   means a typo costs a message and nothing on screen moves.
        /// - **Parsed.** Assigned through `designOverrides`, which is the one
        ///   write path and fires the same two calls a settings reload does.
        ///
        /// The equality guard is `reload()`'s, for `reload()`'s reason: editors
        /// touch a file on save even when its bytes have not changed, and the
        /// directory watcher above fires on writes to files that are not this one
        /// at all.
        private func reloadDesignOverrides() {
            let path = Self.designOverridesFileURL().path(percentEncoded: false)
            guard let data = FileManager.default.contents(atPath: path) else {
                guard storedDesignOverrides != nil else { return }
                designOverrides = nil
                return
            }

            switch DesignOverridesText.parse(String(decoding: data, as: UTF8.self)) {
            case let .success(parsed):
                // An empty value is nil rather than an empty `DesignOverrides()`,
                // the same distinction the panel's Reset makes: the two render
                // identically, but nil is what takes the center off its composed
                // path instead of leaving it composing nothing forever.
                let next = parsed == DesignOverrides() ? nil : parsed
                guard next != storedDesignOverrides else { return }
                designOverrides = next
            case let .failure(error):
                FileHandle.standardError.write(Data(
                    "baia: design-overrides.json: \(error.message); keeping what is dialled\n".utf8
                ))
            }
        }
    #endif

    private func reload() {
        let result = store.load()
        // Reported *before* the equality guard, and this ordering is the whole
        // point. What the decoder could not use is a fact about the file, not
        // about whether the file changed anything, and the two cases where it
        // matters most both decode to no change at all: a value that clamps back
        // to what is already loaded (`backgroundOpacity: 1.5` under a live 1),
        // and a document so malformed that nothing in it applied. Reporting
        // after the guard meant the owner edited the file, saw no effect, and was
        // told nothing. Found by the live pass, which read an empty log.
        //
        // This does not become chatter: `report` writes only when the decoder
        // actually rejected something, so a clean file stays silent no matter how
        // often an editor touches it.
        Self.report(result)
        // A file that decodes to what is already loaded changes nothing. Editors
        // touch a file on save even when its bytes are unchanged.
        guard result.settings != settings else { return }
        settings = result.settings
        applyToEveryPane()
        notifySettingsChanged()
    }

    /// Says what it could not use, on stderr.
    ///
    /// The decoder is per-field resilient, so a bad key is not an error path:
    /// every other field still applied. But a value that silently fell back is
    /// exactly what the decoder was written to make visible, and there is no
    /// diagnostics surface in the app yet.
    private static func report(_ result: SettingsDecodeResult) {
        if result.documentIsUnreadable {
            FileHandle.standardError.write(Data(
                "baia: config.json is not a JSON object, so none of it applied\n".utf8
            ))
            return
        }
        for key in result.invalidKeys {
            FileHandle.standardError.write(Data(
                "baia: config.json: `\(key)` is out of range or the wrong type, using the default\n".utf8
            ))
        }
        for key in result.unknownKeys {
            FileHandle.standardError.write(Data(
                "baia: config.json: `\(key)` is not a setting baia reads\n".utf8
            ))
        }
    }
}
