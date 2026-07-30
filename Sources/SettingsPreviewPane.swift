import AppKit
import BaiaSettings
import GhosttyTerminal
import PaneChrome

/// One miniature pane in the settings preview: a sample terminal with a real
/// status bar under it.
///
/// The footer is `PaneStatusBarView` itself, not a drawing of one. It is already
/// a passive view driven entirely by settable properties, the same way a real
/// pane drives it, so the preview cannot disagree with the panes about what
/// `focusAccent`, `attentionStyle`, `attentionAccent` or `alertBehavior` look
/// like. Those four keys touch nothing else, so without this footer three of them
/// had no visible effect in the window at all.
@MainActor
final class SettingsPreviewPane: NSViewController {
    private let surface = SettingsSampleSurface()
    private let footer = PaneStatusBarView()

    /// Whether this pane is shown as the focused one.
    ///
    /// Fixed per instance. The column shows one focused and one asking, side by
    /// side, because attention is a state and a preview at rest cannot show it.
    private let isFocused: Bool
    private let status: PaneStatus

    init(isFocused: Bool, status: PaneStatus) {
        self.isFocused = isFocused
        self.status = status
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(surface)
        surface.view.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface.view)
        view.addSubview(footer)

        footer.status = status
        footer.isFocused = isFocused
        footer.isWindowActive = true

        NSLayoutConstraint.activate([
            surface.view.topAnchor.constraint(equalTo: view.topAnchor),
            surface.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.topAnchor.constraint(equalTo: surface.view.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(
                equalToConstant: PaneStatusBarMetrics.reservedHeight(focused: isFocused)
            ),
        ])
    }

    /// Re-themes the terminal and the footer together.
    ///
    /// Both halves come from the one `Settings` the column was handed, so the
    /// footer can never be showing one theme while the surface above it shows
    /// another.
    func apply(
        _ configuration: TerminalConfiguration,
        theme: TerminalTheme,
        chrome: PaneTheme,
        settings: BaiaSettings.Settings
    ) {
        surface.apply(configuration, theme: theme)
        footer.theme = chrome
        footer.attentionStyle = settings.attentionStyle
        footer.attentionAccent = settings.attentionAccent
        footer.alertBehavior = settings.alertBehavior
    }
}
