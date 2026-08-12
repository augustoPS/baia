import AppKit
import BaiaSettings
import GhosttyTerminal
import PaneChrome

/// One side of the settings comparison: a sidebar column beside two miniature
/// panes, themed as one window.
///
/// Two panes rather than one, and their states are fixed. `focusAccent` shows on
/// a focused pane; `attentionStyle`, `attentionAccent` and `alertBehavior` show
/// only on a pane raising attention. A single calm pane would leave three of the
/// four signal keys with nothing to look at, which is what this column exists to
/// fix.
///
/// The heading is a `SurfaceTitleView`, the same view the real sidebar draws, so
/// the one part carrying theme colour into the sidebar is shared rather than
/// reimplemented. `SidebarHost` itself is not reused: its initialiser takes a
/// `PaneTreeController`, and building one here would spawn real `.exec` panes and
/// leak a shell per preview.
@MainActor
final class SettingsPreviewColumn: NSViewController {
    private let focusedPane: SettingsPreviewPane
    private let askingPane: SettingsPreviewPane
    /// One heading, since the owner's 2026-08-12 ruling removed the sidebar's
    /// CHANGES section. A second `SurfaceTitleView` stood above this one until
    /// then, drawing a hardcoded `CHANGES 4` with a gap below it standing in for
    /// rows; a preview of a section the column no longer has would be the
    /// settings window showing a window that cannot exist.
    private let filesHeading = SurfaceTitleView()
    private let sidebar = NSView()

    /// Fixed sample state, so both columns describe the same imaginary workspace
    /// and the only difference between them is the settings.
    private static func status(asking: Bool) -> PaneStatus {
        PaneStatus(
            anchorName: "baia",
            anchorIsRepository: true,
            isPinned: false,
            workingDirectory: nil,
            git: PaneStatus.Git(
                head: "main",
                hasUpstream: true,
                ahead: 2,
                behind: 0,
                dirty: true,
                untracked: 3,
                conflicted: 0,
                operation: nil,
                isLinkedWorktree: false
            ),
            // Attention is computed from the agent, not set directly, so the
            // asking pane gets one that wants attention and the calm pane gets a
            // busy one that does not.
            agent: PaneStatus.Agent(
                label: "claude",
                wantsAttention: asking,
                isAcknowledged: false,
                isBusy: !asking
            )
        )
    }

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        focusedPane = SettingsPreviewPane(isFocused: true, status: Self.status(asking: false))
        askingPane = SettingsPreviewPane(isFocused: false, status: Self.status(asking: true))
        super.init(nibName: nibName, bundle: bundle)
    }

    convenience init() {
        self.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        filesHeading.title = "FILES"
        // Kept on the one heading left, where they used to dress the `CHANGES`
        // one: they are what carries theme colour into the trailing half of a
        // heading, and dropping them with the section would have quietly taken
        // two themed things out of the preview.
        filesHeading.anchorName = "baia"

        sidebar.wantsLayer = true
        filesHeading.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(filesHeading)
        NSLayoutConstraint.activate([
            filesHeading.topAnchor.constraint(equalTo: sidebar.topAnchor),
            filesHeading.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            filesHeading.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            filesHeading.heightAnchor.constraint(equalToConstant: 24),
        ])

        let panes = NSStackView(views: [focusedPane.view, askingPane.view])
        panes.orientation = .vertical
        panes.distribution = .fillEqually
        panes.spacing = 8
        panes.translatesAutoresizingMaskIntoConstraints = false
        addChild(focusedPane)
        addChild(askingPane)

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebar)
        view.addSubview(panes)
        // The sidebar is the fixed-width part and must not win the column. Without
        // this it hugs at the same priority as the panes and, since the panes only
        // carry a low-priority preferred width, it takes everything.
        sidebar.setContentHuggingPriority(.required, for: .horizontal)
        sidebar.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: view.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 132),
            panes.topAnchor.constraint(equalTo: view.topAnchor),
            panes.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panes.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 8),
            panes.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    /// Themes the whole column from one `Settings`.
    func apply(
        _ configuration: TerminalConfiguration,
        theme: TerminalTheme,
        chrome: PaneTheme,
        settings: BaiaSettings.Settings
    ) {
        for pane in [focusedPane, askingPane] {
            pane.apply(configuration, theme: theme, chrome: chrome, settings: settings)
        }
        filesHeading.theme = chrome
        // The sidebar takes the pane background, the way the real column does:
        // a surface is filled with the same material a pane is.
        sidebar.layer?.backgroundColor = SidebarRowMetrics.nsColor(chrome.panelBackground).cgColor
    }
}
