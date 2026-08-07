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

    /// What the sample composites its translucent background against.
    ///
    /// **The defect this closes.** `backgroundHex` looked as though it applied
    /// in the sample and not in the panes, and the config emission was never the
    /// reason: a live capture of the generated ghostty config shows
    /// `background = #141414` emitted last, after the theme's own
    /// `background = 000000`, and libghostty resolves a repeated scalar key
    /// last-wins with no diagnostic (both verified against the linked library).
    /// What differed was what each one composites *onto*. ghostty draws
    /// `background` at `background-opacity` into a non-opaque Metal layer, so a
    /// real pane lands that colour on the desktop through a transparent window,
    /// while this sample landed it on the opaque settings window behind it. At
    /// the owner's live 0.1 that is the whole visible difference: `#141414`
    /// against a mid-grey desktop composites to ≈117/255, nearly the desktop
    /// itself, and against this window's own backdrop it stayed near 20/255 and
    /// read as the hex plainly applying.
    ///
    /// So the sample was the one that was wrong, and it was wrong by flattering:
    /// it showed a setting doing more than it does. A neutral mid-grey stands in
    /// for the desktop, which is what a pane actually has behind it. Not a
    /// screenshot of the real desktop — the sample is a comparison between two
    /// settings, and a backdrop that changed with the wallpaper would move both
    /// columns for a reason that is not a setting. Mid-grey is the honest
    /// worst-case: it is where a translucent background loses the most contrast,
    /// so a hex that still reads here reads anywhere.
    private let desktopStandIn: NSView = {
        let backdrop = NSView()
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(white: 0.5, alpha: 1).cgColor
        return backdrop
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(surface)
        surface.view.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        desktopStandIn.translatesAutoresizingMaskIntoConstraints = false
        // Behind both, so the surface's translucent background composites onto
        // it exactly as a pane's composites onto the desktop.
        view.addSubview(desktopStandIn)
        view.addSubview(surface.view)
        view.addSubview(footer)

        footer.status = status
        footer.isFocused = isFocused
        footer.isWindowActive = true

        NSLayoutConstraint.activate([
            desktopStandIn.topAnchor.constraint(equalTo: view.topAnchor),
            desktopStandIn.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            desktopStandIn.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            desktopStandIn.trailingAnchor.constraint(equalTo: view.trailingAnchor),
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
