import AppKit
import BaiaSettings
import GhosttyTerminal
import PaneChrome

/// One miniature pane in the settings preview: a sample terminal wearing the
/// real capsule in its top-right corner.
///
/// The capsule is `PaneClusterView` itself, not a drawing of one. It is a
/// passive view driven entirely by settable properties, the same way a real
/// pane drives it, so the preview cannot disagree with the panes about what
/// `focusAccent`, `attentionAccent` or `alertBehavior` look like. Those keys
/// touch nothing else, so without a real chrome view here they would have no
/// visible effect in this window at all.
///
/// **It was `PaneStatusBarView` until 2026-08-13, and the swap is a correction
/// rather than a refresh.** The footer is retired: `chrome.cluster.mode`
/// defaults to `.cluster`, where `TerminalPaneController.applyClusterMode()`
/// hides the bar outright and the capsule is the only chrome a pane wears. This
/// preview instantiated the footer *outside* that dial, so it went on showing a
/// surface the owner's panes no longer have — a settings window previewing
/// chrome that is not on screen anywhere else, which is worse than previewing
/// nothing. The capsule is the surface these dials now actually reach.
///
/// **`attentionStyle` is the one of the four this preview cannot show, and it is
/// deliberate rather than overlooked.** That key never reached the capsule: in a
/// real pane it gates `TerminalPaneController.drawsAttentionFrame`, the 2 pt
/// `PaneEdgeFrameView` stroke around the whole pane, and `PaneClusterView` has no
/// `attentionStyle` property to hand it to. ``attentionFrame`` below is that
/// view, installed here for exactly that reason; see its own doc.
@MainActor
final class SettingsPreviewPane: NSViewController {
    private let surface = SettingsSampleSurface()
    private let capsule = PaneClusterView(frame: .zero)

    /// The pane-edge attention stroke, the same `PaneEdgeFrameView` a real pane
    /// wears, and the only carrier `attentionStyle` has.
    ///
    /// A second real view rather than a second drawing, on this file's standing
    /// rule: the dial is `loud` versus `quiet`, `TerminalPaneController` spells
    /// that as `lastAttention == .asking && attentionStyle == .loud`, and the same
    /// conjunction is recomputed in ``apply(_:theme:chrome:settings:)`` rather
    /// than approximated. Invisible on the calm pane at every setting, which is
    /// correct: `loud` is a statement about a pane that is asking.
    private let attentionFrame = PaneEdgeFrameView(frame: .zero)

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
        capsule.translatesAutoresizingMaskIntoConstraints = false
        attentionFrame.translatesAutoresizingMaskIntoConstraints = false
        desktopStandIn.translatesAutoresizingMaskIntoConstraints = false
        // Behind everything, so the surface's translucent background composites
        // onto it exactly as a pane's composites onto the desktop.
        view.addSubview(desktopStandIn)
        view.addSubview(surface.view)
        // Over the surface, both of them, which is the pane's own stacking: the
        // capsule floats on the terminal and the attention stroke is drawn just
        // inside the pane's edge over whatever is there.
        view.addSubview(attentionFrame)
        view.addSubview(capsule)

        // The same feed a real pane gives the capsule: the segments built from
        // this pane's sample status, and the two halves of the focus gate. The
        // preview window is never inactive as far as this pane is concerned —
        // `isWindowActive` false would scrim every column at once and say
        // nothing about a setting — so the fixed `isFocused` is the whole of it,
        // exactly as the footer's pair was.
        capsule.segments = PaneClusterSegments.build(from: status)
        capsule.isPaneFocused = isFocused
        capsule.isWindowActive = true

        NSLayoutConstraint.activate([
            desktopStandIn.topAnchor.constraint(equalTo: view.topAnchor),
            desktopStandIn.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            desktopStandIn.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            desktopStandIn.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // The surface is now the whole pane rect. Under the footer it stopped
            // 22 pt short, because `PaneStatusBarMetrics.reservedHeight(focused:)`
            // pinned a bar across the bottom and the surface took what was left.
            // Nothing replaces that as a *height input*, and nothing should: the
            // capsule is an overlay, and a real pane at `.cluster` runs its
            // surface to the view's own bottom edge for exactly this reason
            // (`PaneClusterMetrics.bottomArrangement(clusterOnly:underGlass:)`
            // answers `.fullHeightClear`). So the pane's height is unchanged —
            // it was always the column's stack view, `fillEqually` over two
            // panes — and the surface simply gains the 22 pt the bar used to
            // hold. The preview grows a little more terminal, which is what the
            // real pane did when the footer left it.
            surface.view.topAnchor.constraint(equalTo: view.topAnchor),
            surface.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            surface.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            attentionFrame.topAnchor.constraint(equalTo: view.topAnchor),
            attentionFrame.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            attentionFrame.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            attentionFrame.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // Pinned exactly the way it ships: top and trailing only, at the
            // corner inset, with width and height coming from the view's own
            // `intrinsicContentSize`. `TerminalPaneController.installClusterView()`
            // is the shape being matched, down to the two anchors it uses and
            // the two it deliberately does not.
            capsule.topAnchor.constraint(
                equalTo: view.topAnchor,
                constant: PaneClusterMetrics.cornerInset
            ),
            view.trailingAnchor.constraint(
                equalTo: capsule.trailingAnchor,
                constant: PaneClusterMetrics.cornerInset
            ),
        ])
    }

    /// Re-themes the terminal and the chrome together.
    ///
    /// Every half comes from the one `Settings` the column was handed, so the
    /// capsule can never be showing one theme while the surface under it shows
    /// another.
    ///
    /// `focusAccent` is absent from the writes below and still applies: it is
    /// baked into the `PaneTheme` by `SettingsDerivations.paneTheme(from:)`, and
    /// the capsule draws its focus stroke in `theme.inkFocus`. Assigning it here
    /// as well would be a second resolution of one setting.
    func apply(
        _ configuration: TerminalConfiguration,
        theme: TerminalTheme,
        chrome: PaneTheme,
        settings: BaiaSettings.Settings
    ) {
        surface.apply(configuration, theme: theme)
        capsule.theme = chrome
        capsule.attentionAccent = settings.attentionAccent
        capsule.alertBehavior = settings.alertBehavior
        // `TerminalPaneController.applyPresentation()`'s two lines for this view,
        // recomputed rather than approximated: one colour resolved from the same
        // call the capsule's dot uses, so the stroke around the pane and the dot
        // inside it cannot end up two colours, and the volume gate. The asking
        // pane is the only one that can be `.asking`, so `quiet` takes the frame
        // off exactly one of the two panes and leaves the dot on both.
        attentionFrame.colour = chrome.attentionColour(
            settings.attentionAccent,
            behavior: settings.alertBehavior
        )
        attentionFrame.isVisible = status.attention.wearsFrame(under: settings.attentionStyle)
    }
}
