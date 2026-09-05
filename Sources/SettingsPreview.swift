import AppKit
import BaiaSettings
import GhosttyTerminal
import GitWorkspace
import PaneChrome
import WorkspaceLayout

/// The states the Appearance sample can be switched between.
///
/// The five the spec names. "Attention" in the spec's list is the level the
/// chrome calls `acknowledged`: still asking, and seen, which is the state a
/// pane sits in while the owner works beside it. `asking` is the loud level.
enum SamplePaneState: CaseIterable {
    case inactive
    case focused
    case asking
    case acknowledged
    case done

    var title: String {
        switch self {
        case .inactive: "Inactive"
        case .focused: "Focused"
        case .asking: "Asking"
        case .acknowledged: "Acknowledged"
        case .done: "Done"
        }
    }

    /// What the state shows, for the picker's help and the sample's
    /// accessibility description.
    var explanation: String {
        switch self {
        case .inactive: "The window is not in front: every pane recedes behind a scrim."
        case .focused: "The pane holding the keyboard, with its focus frame and cursor colour."
        case .asking: "An agent asked for you and nobody has looked yet: the capsule fills, and the whole pane is framed when attention is set to frame the pane."
        case .acknowledged: "Still asking, and seen: the frame comes off and the capsule stays tinted."
        case .done: "The agent finished and nobody has been in the pane since."
        }
    }

    var isWindowActive: Bool { self != .inactive }

    var isPaneFocused: Bool {
        switch self {
        case .inactive, .focused, .acknowledged: true
        case .asking, .done: false
        }
    }

    var agent: PaneStatus.Agent {
        switch self {
        case .inactive, .focused:
            PaneStatus.Agent(label: "claude", wantsAttention: false, isBusy: true)
        case .asking:
            PaneStatus.Agent(label: "claude", wantsAttention: true, isAcknowledged: false)
        case .acknowledged:
            PaneStatus.Agent(label: "claude", wantsAttention: true, isAcknowledged: true)
        case .done:
            PaneStatus.Agent(label: "claude", wantsAttention: false, hasFinishedUnseen: true)
        }
    }
}

/// One sample pane: a canned in-memory terminal wearing the real chrome stack.
///
/// `PaneChromeStack` is the same object a live pane installs, fed the same
/// `PaneAppearance` the configuration centre resolves for a pane, so the
/// glass plane, the wash, the capsule, the scrim, the frame and the lift are
/// the pane's own views under the pane's own rules. What differs from a pane
/// is only what a pane reads from the world: focus, window activation and the
/// attention level come from the state picker, and the segments from a fixed
/// sample status.
@MainActor
final class SamplePaneController: NSViewController, SidebarHostedContent {
    let surface = SettingsSampleSurface()
    let chrome = PaneChromeStack()

    /// The corners a lone pane in a window owns, minus whichever the sidebar
    /// covers, which is the arithmetic `PaneTreeController.pushBottomCorners`
    /// does for a real tree.
    var edgesCoveredByHost: BottomCorners = [] {
        didSet { pushCorners() }
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 260))
        container.wantsLayer = true
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(surface)
        surface.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface.view)
        NSLayoutConstraint.activate([
            surface.view.topAnchor.constraint(equalTo: view.topAnchor),
            surface.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            surface.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        chrome.install(in: view, around: surface.view)
        pushCorners()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        chrome.layoutDidChange()
    }

    private func pushCorners() {
        chrome.bottomCorners = BottomCorners([.left, .right]).subtracting(edgesCoveredByHost)
    }
}

/// The whole sample: a sidebar host holding one pane, over a neutral backdrop,
/// clipped to a window's corners.
///
/// The sidebar is `SidebarHost` itself, the view controller a workspace window
/// uses as its content, holding a `FilesSurface` over a small fixed tree. So
/// the column's glass container, its band merge and its flat fill are the
/// window's own, not a coloured rectangle standing in for them (audit S11).
///
/// The backdrop is a mid grey rather than the desktop, and the caption under
/// the picker says so: the sample sits inside an opaque window, so what a
/// translucent well composites onto here is this view, and translucency is
/// judged against the owner's own desktop through the real panes, which follow
/// every edit live.
@MainActor
final class WorkspaceSampleController: NSViewController {
    let pane = SamplePaneController()
    private let files = FilesSurface()
    let sidebar: SidebarHost
    private let backdrop = NSView()
    let frame = SampleFrameView()
    private(set) var showsFiles = false

    var state: SamplePaneState = .focused {
        didSet {
            guard state != oldValue else { return }
            applyState()
            reapplyTerminal()
        }
    }

    private var appearance: PaneAppearance?
    private var settings: Settings?

    init() {
        sidebar = SidebarHost(
            content: pane,
            surfaces: nil,
            theme: .darkPastel,
            backgroundOpacity: 1,
            resolvedChrome: .flat,
            spansTitlebar: false
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        files.tree = Self.sampleTree
        files.anchorPath = "/sample/baia"

        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(white: 0.5, alpha: 1).cgColor

        frame.wantsLayer = true
        frame.layer?.cornerRadius = WindowCorner.radius
        frame.layer?.cornerCurve = .continuous
        frame.layer?.masksToBounds = true

        addChild(sidebar)
        sidebar.width = 176
        for subview in [backdrop, sidebar.view] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            frame.addSubview(subview)
            NSLayoutConstraint.activate([
                subview.topAnchor.constraint(equalTo: frame.topAnchor),
                subview.bottomAnchor.constraint(equalTo: frame.bottomAnchor),
                subview.leadingAnchor.constraint(equalTo: frame.leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
            ])
        }
        frame.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(frame)
        NSLayoutConstraint.activate([
            frame.topAnchor.constraint(equalTo: view.topAnchor),
            frame.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            frame.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            frame.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            view.heightAnchor.constraint(equalToConstant: 300),
        ])
        applyState()
    }

    /// Re-themes everything from one settings value and the appearance the
    /// centre resolved for it.
    func apply(_ settings: Settings, appearance: PaneAppearance) {
        self.settings = settings
        self.appearance = appearance
        pane.chrome.apply(appearance)
        sidebar.theme = appearance.theme
        sidebar.backgroundOpacity = settings.backgroundOpacity
        sidebar.resolvedChrome = appearance.resolvedChrome
        let wantsFiles = settings.sidebar == .files
        if wantsFiles != showsFiles {
            showsFiles = wantsFiles
            sidebar.show(wantsFiles ? files : nil)
        }
        reapplyTerminal()
    }

    /// The surface takes what a pane spawned right now would take: the
    /// glass-clear configuration under glass, the settings-derived one under
    /// flat, and the focus colour on the cursor while focused, exactly as
    /// `TerminalPaneController.applyTerminalConfiguration` picks them. A real
    /// pane freezes that choice at spawn; the sample has no grid to protect and
    /// re-resolves on every change, which is what lets it show the next pane.
    private func reapplyTerminal() {
        guard let appearance else { return }
        let isGlass = if case .glass = appearance.resolvedChrome { true } else { false }
        let base = isGlass ? appearance.glassClearTerminalConfiguration : appearance.terminalConfiguration
        let configuration = state.isPaneFocused
            ? base.cursorColor(appearance.theme.inkFocus.hexString)
            : base
        surface.apply(configuration, theme: appearance.terminalTheme)
    }

    private var surface: SettingsSampleSurface { pane.surface }

    private func applyState() {
        pane.chrome.isWindowActive = state.isWindowActive
        pane.chrome.isPaneFocused = state.isPaneFocused
        let status = Self.status(agent: state.agent)
        pane.chrome.attention = PaneStatus.Attention(status.agent)
        pane.chrome.clusterView.segments = PaneClusterSegments.build(from: status)
        frame.setAccessibilityLabel("Workspace sample, \(state.title.lowercased()) pane. \(state.explanation)")
    }

    /// Fixed sample facts, so the only thing that moves the sample is a
    /// setting or the state picker.
    private static func status(agent: PaneStatus.Agent) -> PaneStatus {
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
            agent: agent
        )
    }

    private static let sampleTree: [FileTreeNode] = [
        FileTreeNode(name: "Packages", path: "Packages", isDirectory: true, children: [
            FileTreeNode(name: "BaiaSettings", path: "Packages/BaiaSettings", isDirectory: true, children: []),
            FileTreeNode(name: "PaneChrome", path: "Packages/PaneChrome", isDirectory: true, children: []),
        ]),
        FileTreeNode(name: "Sources", path: "Sources", isDirectory: true, children: [
            FileTreeNode(name: "AppDelegate.swift", path: "Sources/AppDelegate.swift", isDirectory: false, children: []),
            FileTreeNode(name: "ConfigurationCenter.swift", path: "Sources/ConfigurationCenter.swift", isDirectory: false, children: []),
            FileTreeNode(name: "SettingsWindowController.swift", path: "Sources/SettingsWindowController.swift", isDirectory: false, children: []),
        ]),
        FileTreeNode(name: "Makefile", path: "Makefile", isDirectory: false, children: []),
        FileTreeNode(name: "README.md", path: "README.md", isDirectory: false, children: []),
    ]
}

/// The sample's clipping frame, and its one accessibility element.
///
/// Decorative for a screen reader: one image with a description of the state,
/// rather than a terminal, a file tree and a capsule each announced as stops.
/// The state picker beside it is the control; this is the picture it changes.
final class SampleFrameView: NSView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityChildren() -> [Any]? { [] }
    override var acceptsFirstResponder: Bool { false }
}

/// The Appearance page's sample with its state picker and caption.
@MainActor
final class SettingsPreviewController: NSViewController {
    let sample = WorkspaceSampleController()
    private let picker = NSSegmentedControl(
        labels: SamplePaneState.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let caption = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        picker.target = self
        picker.action = #selector(pick)
        picker.selectedSegment = SamplePaneState.allCases.firstIndex(of: sample.state) ?? 1
        picker.setAccessibilityLabel("Sample pane state")
        for (index, state) in SamplePaneState.allCases.enumerated() {
            picker.setToolTip(state.explanation, forSegment: index)
        }
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        caption.preferredMaxLayoutWidth = 560
        updateCaption()

        addChild(sample)
        let header = NSStackView(views: [NSTextField(labelWithString: "Sample"), picker])
        header.orientation = .horizontal
        header.spacing = 12
        let stack = NSStackView(views: [header, sample.view, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sample.view.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            sample.view.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    @objc private func pick() {
        let states = SamplePaneState.allCases
        guard states.indices.contains(picker.selectedSegment) else { return }
        sample.state = states[picker.selectedSegment]
        updateCaption()
    }

    private func updateCaption() {
        caption.stringValue = sample.state.explanation
            + " The sample sits over a neutral grey; judge translucency against your desktop in the real panes, which follow every change as it is made."
    }
}
