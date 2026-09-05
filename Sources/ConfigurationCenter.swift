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
    /// The file, for the Settings window's transaction controller, which is
    /// the one writer. Everything else reads through ``settings``.
    let store: SettingsStore

    /// What the config file says, exactly.
    ///
    /// **Committed, never composed.** ``effectiveSettings`` below is what every
    /// derivation reads; this is what the file holds, and the two differ only
    /// while the debug design panel has something dialled. The Settings window
    /// edits this value through ``adopt(_:)`` and previews a slider drag
    /// through it too, so for the length of a drag it runs a frame ahead of the
    /// file; the write at the gesture's end brings the file up to it.
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
    /// has happened. So `chromeStyle: .liquidGlass` dialled on a machine with Reduce
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
    /// What it costs: nothing today. The Settings window is built once and
    /// reused for the life of the process since 2026-09-04, so every registrant
    /// is a singleton. Revisit if a consumer ever registers from something
    /// created per pane, per window, or on a timer.
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
    /// State ink never reads this: grep `PaneGitRuns.swift`,
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
    /// shape:
    /// `PaneChrome.windowIsTransparent(style:backgroundOpacity:appearance:)`
    /// makes the decision and carries the tests, this is the one line that
    /// calls it with the three live inputs.
    ///
    /// **Reads `chromeStyle` as well as `backgroundOpacity` since 2026-08-15.**
    /// The 2026-08-07 decision that this followed opacity alone survives for the
    /// two see-through styles and is retired for `solid`, which is opaque at
    /// every slider position; that function's own doc comment carries what broke
    /// it. Through ``effectiveSettings``, so a dialled style or opacity moves the
    /// window the same way a committed one does.
    var windowIsTransparent: Bool {
        PaneChrome.windowIsTransparent(
            style: effectiveSettings.chromeStyle,
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
    /// above: `PaneChrome.windowBlurRadius(style:backgroundBlur:backgroundOpacity:appearance:paneGlassActive:)`
    /// holds the rule and the tests, and this passes it the five live inputs.
    /// It reads `chromeStyle`, `backgroundBlur` *and* `backgroundOpacity` (all
    /// off ``effectiveSettings``, like its two neighbours) because blur is gated
    /// on the window being transparent at all — see that function's own doc
    /// comment — which is also how both Reduce Transparency and `solid` reach it
    /// without this line mentioning either.
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
            style: effectiveSettings.chromeStyle,
            backgroundBlur: effectiveSettings.backgroundBlur,
            backgroundOpacity: effectiveSettings.backgroundOpacity,
            appearance: appearanceObserver.appearance,
            paneGlassActive: { if case .glass = resolvedChrome { true } else { false } }()
        )
    }

    // MARK: - Derivations

    // **`terminalTheme`, `terminalConfiguration`, and
    // `glassClearTerminalConfiguration` stood here until this pane-appearance
    // deepening.** All three were folded into `PaneChrome.PaneAppearance`,
    // built once by `PaneAppearance.make(settings:overrides:materialIsDark:appearance:)`
    // and carried on the value `apply(to:)` now hands the pane, because none
    // of the three had a reader outside that method: `grep` for each name
    // across `Sources/` found only `ConfigurationCenter.swift` itself. See
    // `PaneAppearance`'s own doc comment for what replaced them, including the
    // glass-clear derivation's `background-opacity` zeroing and why appending
    // it after the theme's own overrides is safe (ghostty's config parser
    // takes the last value it reads for a scalar key).
    //
    // `paneTheme` and `resolvedChrome` immediately below stay: the palette,
    // the two floating panels, the sidebar, the titlebar band and the find
    // panel all read them from `AppDelegate.settingsDidChange()`, so deleting
    // either would be deleting a live wire this deepening was not asked to
    // touch.

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

    // MARK: - Adopting

    /// Takes `settings` as what is in effect and pushes it everywhere.
    ///
    /// The Settings window's transaction controller calls this with what the
    /// file decoded to after its own write, and with each frame of a slider
    /// drag before the write. The watcher's reload that follows the write finds
    /// the file equal to this and does nothing, which is the same guard that
    /// keeps an editor's no-op save quiet.
    func adopt(_ settings: Settings) {
        guard settings != self.settings else { return }
        self.settings = settings
        applyToEveryPane()
        notifySettingsChanged()
    }

    /// Runs every settings-change handler without a settings change.
    ///
    /// For the one input outside the file that the handlers read: the
    /// command-execution acknowledgement, which `AppDelegate.settingsDidChange()`
    /// combines with `controlAllowRun` for the control server.
    func announce() {
        notifySettingsChanged()
    }

    /// The pane appearance `settings` would produce right now, for the Settings
    /// preview.
    ///
    /// Through `PaneAppearance.make` with the live appearance observer and the
    /// theme-derived darkness, exactly as ``apply(to:)`` builds a pane's, so
    /// the preview resolves Reduce Transparency, the material set and the
    /// glass-clear terminal configuration the way a pane spawned under these
    /// settings would. No design overrides: the preview shows the file's
    /// settings, and the dials are ephemeral by construction.
    func appearance(for settings: Settings) -> PaneAppearance {
        PaneAppearance.make(
            settings: settings,
            overrides: DesignOverrides.Chrome(),
            materialIsDark: PaneChrome.windowIsDark(paneTheme: chrome(for: settings)),
            appearance: appearanceObserver.appearance
        )
    }

    /// Builds this instant's ``PaneChrome/PaneAppearance`` and hands it to
    /// `pane.apply(_:)`, which owns the ordering, the diff log, and which
    /// terminal configuration a spawn-frozen pane takes. The ordering
    /// comments this method used to carry one assignment at a time now live
    /// on `TerminalPaneController.apply(_:)`, next to the lines they explain.
    ///
    /// `materialIsDark: windowIsDark` and `appearance: appearanceObserver.appearance`
    /// are the two live inputs `PaneAppearance.make` cannot derive from
    /// `Settings` alone. Passing `windowIsDark` here, the same value
    /// ``resolvedChrome`` above passes, is what keeps a pane's glass and the
    /// window chrome around it on one derivation: both come from the theme,
    /// never from the system's own appearance.
    private func apply(to pane: TerminalPaneController) {
        pane.apply(paneAppearance)
    }

    /// What every pane is handed right now: the composed settings, the dialled
    /// chrome extras, the theme-derived darkness and the live appearance.
    /// Read by ``apply(to:)`` and by the Settings self-check, so the check
    /// compares a pane against the derivation that fed it.
    var paneAppearance: PaneAppearance {
        PaneAppearance.make(
            settings: effectiveSettings,
            overrides: chromeOverrides,
            materialIsDark: windowIsDark,
            appearance: appearanceObserver.appearance
        )
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
        // The store's own path, not `defaultFileURL()`: the two agree in the
        // shipped app and differ under `BAIA_CONFIG_FILE`, where watching the
        // default would reload a file nothing here writes.
        let path = store.url.path(percentEncoded: false)
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

    private var documentChangeHandlers: [() -> Void] = []

    func onDocumentChange(_ handler: @escaping () -> Void) {
        documentChangeHandlers.append(handler)
    }

    private func reload() {
        defer { for handler in documentChangeHandlers { handler() } }
        let state = store.inspect()
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
        guard state == .valid || state == .missing else { return }
        // A document the decoder could not read as an object applies nothing,
        // and the running configuration stays on the last value that did apply.
        // Dropping to the defaults here would re-theme every pane on a
        // half-saved file and put them back a keystroke later, and it is not
        // this object's place to guess what the owner meant; the Settings
        // window shows the recovery state and offers the repair.
        guard !result.documentIsUnreadable else { return }
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
