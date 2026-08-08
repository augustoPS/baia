import AppKit
import BaiaSettings
import GhosttyTerminal
import SwiftUI

/// The settings window: the form on the left, the committed settings and the
/// pending draft rendered side by side on the right.
///
/// Each side is a whole miniature workspace, sidebar and terminal and footer,
/// with a focused pane above an asking one. Both are fed identical canned output
/// and identical sample state, so the only difference on screen is the settings
/// themselves. That comparison is why the window exists.
///
/// Nothing here touches a real pane. Accept writes the file, the
/// `ConfigurationCenter` watcher notices, and the panes are re-themed by the same
/// path that handles a hand-edit.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let center: ConfigurationCenter
    private let model: SettingsDraft
    private let before = SettingsPreviewColumn()
    private let after = SettingsPreviewColumn()

    /// Whether this window's surfaces are live, and so whether either sample may
    /// be written.
    ///
    /// Two jobs, and the second is why it is set in `init` rather than only by
    /// ``startObserving()``. It re-arms the draft observation, which
    /// `withObservationTracking` needs because it fires once and forgets; and it
    /// gates ``applyCommittedToSample()``, whose callback is registered on the
    /// center and therefore outlives the close — `AppDelegate` holds the last
    /// settings window until the next ⌘, so "closed" and "deallocated" are not
    /// the same moment here and a weak capture alone would not cover the gap.
    ///
    /// Cleared in ``windowWillClose(_:)`` rather than in a `close()` override,
    /// because the red button never calls the latter. See that method.
    private var isObserving = false

    init(center: ConfigurationCenter) {
        self.center = center
        model = SettingsDraft(committed: center.settings)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        super.init(window: window)
        // The one channel that catches *every* close. The red button sends
        // `performClose:`, which calls `NSWindow.close()` directly and never
        // routes through this controller's `close()` override, so the override
        // alone left `isObserving` true on the one close path a person is most
        // likely to take. Same shape as ``WorkspaceWindowController``, which
        // takes the delegate for the same reason.
        window.delegate = self

        let form = NSHostingView(rootView: SettingsView(
            model: model,
            onApply: { [weak self] in self?.apply() },
            onAccept: { [weak self] in self?.accept() },
            onCancel: { [weak self] in self?.close() },
            chrome: { center.chrome(for: $0) }
        ))
        form.translatesAutoresizingMaskIntoConstraints = false
        // The form is the fixed side. The samples take whatever the window has
        // left, because they are the part worth making bigger.
        form.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        form.setContentCompressionResistancePriority(.required, for: .horizontal)

        let samples = NSStackView(views: [labelled(before.view, "Current"),
                                          labelled(after.view, "New")])
        samples.orientation = .horizontal
        samples.distribution = .fillEqually
        samples.spacing = 12
        samples.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 12)
        samples.translatesAutoresizingMaskIntoConstraints = false

        let split = NSStackView(views: [form, samples])
        split.orientation = .horizontal
        split.spacing = 0
        split.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            form.widthAnchor.constraint(equalToConstant: 400),
        ])
        window.contentView = content

        // Before the first paint, because `applyCommittedToSample()` is gated on
        // it: the flag means "this window's surfaces are live", which is true
        // from here until the window closes, and not merely "the draft is being
        // tracked".
        // `startObserving()` sets it again at the bottom, which costs nothing.
        isObserving = true
        // The left column is what is in effect, so it moves exactly when that
        // does: once now, and again on every change the center announces.
        applyCommittedToSample()
        center.onSettingsChange { [weak self] in self?.applyCommittedToSample() }
        applyDraftToSample()
        startObserving()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// A sample under a caption, so the two are told apart without a legend.
    private func labelled(_ sample: NSView, _ title: String) -> NSView {
        let caption = NSTextField(labelWithString: title)
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .secondaryLabelColor
        let column = NSStackView(views: [caption, sample])
        column.orientation = .vertical
        column.spacing = 6
        column.alignment = .leading
        sample.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sample.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            sample.trailingAnchor.constraint(equalTo: column.trailingAnchor),
        ])
        return column
    }

    /// Re-themes the left sample from what the center currently has committed.
    ///
    /// **Registered on the center rather than called from ``apply()``**, and
    /// that is the whole point of the arrangement. ``write()`` deliberately
    /// applies nothing itself: it moves the file, the watcher notices, and
    /// `reload` re-derives. So at the moment Apply returns, `center.settings` is
    /// still the *old* value and a refresh there would repaint the column with
    /// what it already showed. Hanging off the center's own announcement waits
    /// for the round trip and, for free, catches the other way the column goes
    /// stale: a hand-edit to `~/.config/baia/config.json` while this window is
    /// open, which no button here will ever be pressed for.
    ///
    /// Reads the four values fresh off `center` on every call, the same four the
    /// init passed, so a change to any one of them lands.
    ///
    /// **All four are derived from `center.settings` explicitly, through the
    /// parameterised `derivations(for:)` and `chrome(for:)` rather than off the
    /// center's own properties.** Those properties read
    /// `ConfigurationCenter.effectiveSettings`, which composes the debug design
    /// panel's overrides, and this column's whole job is to say what the *file*
    /// holds. Taking them off the center would render a column that is half
    /// dialled and half committed the moment anything is dialled — the
    /// terminal and chrome halves following the panel while the `settings`
    /// argument beside them still described the file. Passing one source to all
    /// four is what keeps them agreeing, and it is the same argument
    /// ``applyDraftToSample()`` below makes for the draft.
    ///
    /// **Safe after the window closes, and it takes both halves to be so.** The
    /// registration captures `self` weakly, which covers the controller having
    /// been released; but `AppDelegate` holds the last settings window in a
    /// property until the *next* ⌘, so a closed controller is typically still
    /// alive and a weak capture alone would let a hand-edit re-theme surfaces
    /// that are on their way out. `isObserving` is the half that covers that,
    /// which is the same flag and the same reasoning as ``startObserving()``'s
    /// re-arm; ``windowWillClose(_:)`` clears it on every close path there is.
    private func applyCommittedToSample() {
        guard isObserving else { return }
        let committed = center.settings
        let (configuration, theme) = center.derivations(for: committed)
        before.apply(
            configuration,
            theme: theme,
            chrome: center.chrome(for: committed),
            settings: committed
        )
    }

    /// Re-themes the right sample from the draft.
    ///
    /// Derives through `ConfigurationCenter` rather than mapping settings onto a
    /// terminal configuration a second time here. Two mappings for one meaning is
    /// how a sample comes to show something the panes will not.
    private func applyDraftToSample() {
        let (configuration, theme) = center.derivations(for: model.draft)
        after.apply(
            configuration,
            theme: theme,
            chrome: center.chrome(for: model.draft),
            settings: model.draft
        )
    }

    /// Re-themes the right sample whenever the draft moves.
    ///
    /// `withObservationTracking` reports one change and then forgets, so the
    /// handler re-arms. The hop to the main actor is what makes the surface write
    /// legal: `onChange` runs wherever the mutation happened, and libghostty
    /// requires the actor.
    private func startObserving() {
        isObserving = true
        withObservationTracking {
            _ = model.draft
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, isObserving else { return }
                applyDraftToSample()
                startObserving()
            }
        }
    }

    /// Writes the draft through `center.commit`, answering whether it landed.
    ///
    /// The one write path: both Apply and Accept call this and neither
    /// serializes the draft any other way. `center.commit` applies nothing
    /// itself; the rename fires the `ConfigurationCenter` watcher, which reloads
    /// and re-themes the running panes exactly as it would a hand-edit to the
    /// file.
    private func write() -> Bool {
        guard center.commit(model.draft) else {
            // The write failed, which means the config directory is unwritable or
            // the disk is full. Closing (or, for Apply, treating the draft as
            // clean) would look like success and lose the edit, so the caller
            // leaves the draft exactly as it was.
            NSSound.beep()
            return false
        }
        return true
    }

    /// Writes the draft and closes the window.
    private func accept() {
        guard write() else { return }
        close()
    }

    /// Writes the draft and keeps the window open.
    ///
    /// Rebases `model`'s dirty comparison onto the just-written values, so the
    /// button goes idle again until the next edit rather than staying armed on a
    /// draft that is now what is on disk.
    ///
    /// Touches the left-hand sample not at all, and must not: it follows the
    /// center's committed state, which this write reaches only once the watcher
    /// has re-read the file. ``applyCommittedToSample()`` is registered for that
    /// announcement and carries the reasoning.
    private func apply() {
        guard write() else { return }
        model.markApplied()
    }

}

extension SettingsWindowController: NSWindowDelegate {
    /// Stops both the draft observation and the center's committed-settings
    /// callback before the surfaces go, so a change landing during teardown — or
    /// a hand-edit to the config file long after this window was closed — cannot
    /// re-theme a view that is on its way out. See ``isObserving``.
    ///
    /// **Here rather than in a `close()` override**, which is what this was and
    /// what left the gap. `NSWindowController.close()` is not on the path the red
    /// button takes: `performClose:` calls `NSWindow.close()` directly. The
    /// notification is the one thing every path posts, the override included, so
    /// this covers Cancel, Accept, `AppDelegate.showSettings(_:)`'s programmatic
    /// close on reopen, and the title-bar button alike.
    func windowWillClose(_: Notification) {
        isObserving = false
    }
}
