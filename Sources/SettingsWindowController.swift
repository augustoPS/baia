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

    /// Kept so the observation can be re-armed. `withObservationTracking` fires
    /// once and forgets, so each change re-registers the next one.
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

        let form = NSHostingView(rootView: SettingsView(
            model: model,
            onAccept: { [weak self] in self?.accept() },
            onCancel: { [weak self] in self?.close() }
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

        // The left column never moves: it is what is in effect. Applied once.
        before.apply(
            center.terminalConfiguration,
            theme: center.terminalTheme,
            chrome: center.paneTheme,
            settings: center.settings
        )
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

    /// Writes the draft. The watcher applies it.
    private func accept() {
        guard center.commit(model.draft) else {
            // The write failed, which means the config directory is unwritable or
            // the disk is full. Closing would look like success and lose the
            // edit, so the window stays open with the draft intact.
            NSSound.beep()
            return
        }
        close()
    }

    override func close() {
        // Stops the observation before the surfaces go, so a change landing
        // during teardown cannot re-theme a view that is on its way out.
        isObserving = false
        super.close()
    }
}
