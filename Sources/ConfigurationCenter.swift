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

    private(set) var settings: Settings

    /// The live system state `resolvedStyle(setting:appearance:)` needs:
    /// dark/light, Reduce Transparency, Reduce Motion. Held rather than read
    /// fresh on every `resolvedChrome` access, so a burst of reads inside one
    /// render pass sees one appearance rather than a value that could change
    /// mid-frame if the observer fired between two of them.
    ///
    /// Constructor-injected, never a later assignment a caller can forget:
    /// the `focusAccent` lesson (`PaneTheme+Palette.swift`) is exactly a
    /// settings key that reached everything except the one line that read it,
    /// and the fix there was moving resolution to where a parameter cannot be
    /// skipped. `appearanceObserver` is the same shape applied one layer
    /// earlier: nothing here can construct a `ConfigurationCenter` without
    /// naming where its appearance comes from.
    private let appearanceObserver: AppearanceObserver

    /// Raised after `settings` or the live appearance moves, for the app-level
    /// consumers that are not panes: the project roots, session restore, and
    /// the notifier. Both sources feed the same callback because both change
    /// what `resolvedChrome` answers, and a caller that only reacted to one
    /// would draw glass a frame late after a Reduce Transparency toggle.
    var onSettingsChange: (() -> Void)?

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
        appearanceObserver.onAppearanceChange = { [weak self] _ in
            guard let self else { return }
            // `resolvedChrome` reads `appearanceObserver.appearance` fresh on
            // every access, so by the time this closure runs the observer has
            // already updated and `apply(to:)` picks up the new resolution.
            // Without this, dark/light and Reduce Transparency moved the value
            // `resolvedChrome` answers but no pane redrew until some unrelated
            // settings-file edit forced a reload, which is exactly the stale
            // frame `onSettingsChange`'s own doc comment says both sources must
            // not leave behind.
            applyToEveryPane()
            onSettingsChange?()
        }
    }

    // MARK: - Chrome resolution

    /// What the chrome should draw right now: flat, or glass with the
    /// material set the live appearance picks.
    ///
    /// `PaneChrome.resolvedStyle(setting:appearance:)` does the actual
    /// resolution and carries its own tests; this is the one line that calls
    /// it with the two live inputs, `settings.chromeStyle` and the observer's
    /// last-published `ChromeAppearance`. State ink never reads this: grep
    /// `PaneStatusSegments.swift`, `PaneTheme.swift`, and
    /// `PaneTheme+Palette.swift` for `ChromeAppearance` or `resolvedChrome`
    /// and find nothing, the same acceptance `SettingsDerivations.paneTheme`
    /// holds for `focusAccent`.
    var resolvedChrome: ResolvedChrome {
        resolvedStyle(setting: settings.chromeStyle, appearance: appearanceObserver.appearance)
    }

    // MARK: - Derivations

    /// The theme currently in effect.
    var terminalTheme: TerminalTheme { SettingsDerivations.terminalTheme(from: settings) }

    /// The session configuration currently in effect.
    var terminalConfiguration: TerminalConfiguration {
        SettingsDerivations.terminalConfiguration(from: settings)
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

    /// The chrome palette currently in effect.
    var paneTheme: PaneTheme { SettingsDerivations.paneTheme(from: settings) }

    /// The chrome palette `settings` would produce.
    ///
    /// Parameterised for the same reason the terminal derivations are: the
    /// settings window renders a draft through it, and a second mapping written
    /// inside the window is how a preview comes to show what the panes will not.
    func chrome(for settings: Settings) -> PaneTheme {
        SettingsDerivations.paneTheme(from: settings)
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
        pane.attentionStyle = settings.attentionStyle
        // Straight through, the way `attentionStyle` and `focusAccent` are. The
        // resolution is `PaneTheme.attentionColour(_:behavior:)`, which has tests;
        // a line here that decided anything about these two would not, and that is
        // exactly how `focusAccent` came to be decoded, stored, and never read.
        pane.attentionAccent = settings.attentionAccent
        pane.alertBehavior = settings.alertBehavior
        pane.gitPollInterval = settings.gitPollSeconds
        pane.activityPollInterval = settings.activityPollSeconds
        // `resolvedChrome` is computed fresh from the same two live inputs this
        // method already closes over (`settings` and the appearance observer's
        // last value), so it stays correct whether `apply` runs from `register`,
        // a settings reload, or an appearance change.
        pane.resolvedChrome = resolvedChrome
        // Both go through the controller rather than through the view.
        // Assigning `view.configuration` or `view.controller` has a `didSet`
        // that tears the surface down and respawns the shell, losing the
        // scrollback and whatever was running in the pane.
        pane.applyTerminalConfiguration(terminalConfiguration, theme: terminalTheme)
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
        onSettingsChange?()
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
