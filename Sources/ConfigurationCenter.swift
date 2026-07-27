import AppKit
import BaiaSettings
import GhosttyTerminal
import GhosttyTheme
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

    /// Raised after `settings` moves, for the app-level consumers that are not
    /// panes: the project roots, session restore, and the notifier.
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

    init(store: SettingsStore = SettingsStore(fileURL: SettingsStore.defaultFileURL())) {
        self.store = store
        // Written before the first read, so a first launch leaves the owner a
        // fully populated file to edit rather than nothing at all. Never
        // overwrites, and races safely: the write is `O_EXCL`.
        _ = store.writeDefaultIfAbsent()
        let result = store.load()
        settings = result.settings
        Self.report(result)
        startWatching()
    }

    // MARK: - Derivations

    /// The catalog entry for the configured theme name.
    ///
    /// Resolved through `GhosttyThemeCatalog` rather than by sending
    /// `theme = <name>` to ghostty. The bundled libghostty is a trimmed build
    /// that ships no theme files, so the config key would be dropped without a
    /// diagnostic and the terminal would keep its defaults while the config
    /// looked applied.
    ///
    /// An unknown name falls back to the default theme rather than to whatever
    /// libghostty would do on its own, so a typo degrades to the terminal the
    /// owner already runs.
    private var themeDefinition: GhosttyThemeDefinition? {
        GhosttyThemeCatalog.theme(named: settings.themeName)
            ?? GhosttyThemeCatalog.theme(named: Settings.defaultSettings.themeName)
    }

    /// The terminal theme, with the configured background folded in on top.
    ///
    /// The fold is not cosmetic. `TerminalController` renders base, then the
    /// session configuration, then the theme, and ghostty takes the last value
    /// for a scalar key, so a background sent through the session layer is
    /// replaced by the theme's own. The owner's `#141414` is deliberately lifted
    /// off pure black, and losing it reports nothing.
    var terminalTheme: TerminalTheme {
        guard let themeDefinition else { return .default }
        let overrides = settings.themeOverrides
        let configuration = TerminalConfiguration(
            startingFrom: themeDefinition.toTerminalConfiguration()
        ) { builder in
            for override in overrides {
                builder.withCustom(override.key, override.value)
            }
        }
        return TerminalTheme(light: configuration, dark: configuration)
    }

    /// Everything the theme does not own, applied per pane through
    /// `setTerminalConfiguration`.
    var terminalConfiguration: TerminalConfiguration {
        let overrides = settings.sessionOverrides
        return TerminalConfiguration { builder in
            for override in overrides {
                builder.withCustom(override.key, override.value)
            }
        }
    }

    /// The chrome palette, from the same catalog entry the terminal is themed
    /// from.
    ///
    /// One lookup feeding both is the point. The standing rule is that chrome
    /// matches the theme and never the reverse, and two sources for one theme is
    /// how a footer ends up in Dark Pastel while the surface is in something
    /// else.
    ///
    /// `focusAccent` goes in as an argument rather than being applied to the
    /// result, so this reads the setting and decides nothing about it. The
    /// resolution is `PaneTheme.accent(for:)`, which has tests; a line here
    /// would not, and a line here is how the key came to be decoded, stored and
    /// never read.
    ///
    /// The fallback keeps the shipped accent. It is reached only when the
    /// catalog cannot produce even its own default theme, which is a broken
    /// build rather than a config the owner wrote, and there is no palette in
    /// hand at that point to resolve a choice against anyway.
    var paneTheme: PaneTheme {
        guard let themeDefinition else { return .darkPastel }
        return PaneTheme(
            background: settings.backgroundHex,
            foreground: themeDefinition.foreground,
            selectionBackground: themeDefinition.selectionBackground,
            palette: themeDefinition.palette,
            focusAccent: settings.focusAccent
        )
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
