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
/// The headings are `SurfaceTitleView`, the same view the real sidebar draws, so
/// the one part carrying theme colour into the sidebar is shared rather than
/// reimplemented. `SidebarHost` itself is not reused: its initialiser takes a
/// `PaneTreeController`, and building one here would spawn real `.exec` panes and
/// leak a shell per preview.
@MainActor
final class SettingsPreviewColumn: NSViewController {
    private let focusedPane: SettingsPreviewPane
    private let askingPane: SettingsPreviewPane
    private let changesHeading = SurfaceTitleView()
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

        changesHeading.title = "CHANGES"
        changesHeading.count = 4
        changesHeading.anchorName = "baia"
        filesHeading.title = "FILES"

        sidebar.wantsLayer = true
        for heading in [changesHeading, filesHeading] {
            heading.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(heading)
        }
        NSLayoutConstraint.activate([
            changesHeading.topAnchor.constraint(equalTo: sidebar.topAnchor),
            changesHeading.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            changesHeading.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            changesHeading.heightAnchor.constraint(equalToConstant: 24),
            // Parked below the first with a gap standing in for the rows a real
            // Changes list would hold. The preview shows how a heading is themed,
            // not what is in the repository.
            filesHeading.topAnchor.constraint(equalTo: changesHeading.bottomAnchor, constant: 64),
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
        for heading in [changesHeading, filesHeading] {
            heading.theme = chrome
        }
        // The sidebar takes the pane background, the way the real column does:
        // a surface is filled with the same material a pane is.
        sidebar.layer?.backgroundColor = ChangesSurface.nsColor(chrome.panelBackground).cgColor
    }
}
