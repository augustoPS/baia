import AppKit
import PaneChrome
import WorkspaceLayout

/// One window's worth of panes.
///
/// The tree in `WorkspaceLayout` is the truth about layout; this type renders it
/// and owns the pane controllers. It is the **only** strong owner of a
/// `TerminalPaneController`, which matters more than it looks: libghostty
/// exposes no way to close a surface, and removing a terminal view from the
/// window keeps its child process alive. A pane's pty dies only when the
/// controller deallocates, so a second strong reference anywhere is a leaked
/// live shell, invisible except as a stray `login` in `ps`.
final class PaneTreeController: NSViewController {
    /// Raised when the focused pane changes or its anchor moves, so the window
    /// can retitle itself. The window owns its title because only the focused
    /// pane may name it.
    var onFocusedPaneChange: (() -> Void)?

    /// Raised when the last pane is gone, because a window with no panes should
    /// close rather than sit empty.
    var onEmpty: (() -> Void)?

    /// A single-tab workspace rather than a bare `Tab`, because every focus rule
    /// this type needs (which pane survives a close, where an arrow key lands,
    /// what zoom does to a dangling id) already lives on `Workspace` and is
    /// tested there. Tabs are separate windows, so the extra tabs are never used.
    private var workspace: Workspace
    private var panes: [PaneID: TerminalPaneController] = [:]
    private let workingDirectory: String

    /// The palette every pane and every divider in this window derives from.
    let theme: PaneTheme = .darkPastel

    /// Held so they can be removed in ``viewWillDisappear()``.
    ///
    /// Not in a `deinit`, for the same reason the trackers do not invalidate
    /// their timers there: Swift 6 forbids touching non-`Sendable` state from a
    /// nonisolated deinit, and an observer token is not `Sendable`. Removing them
    /// as the window goes away is the symmetric half of registering them as it
    /// appears, and it happens while the controller is unambiguously alive.
    private var activationObservers: [any NSObjectProtocol] = []

    /// The hierarchy currently on screen. Compared against the tree before a
    /// rebuild so a focus change, which happens on every click, does not tear
    /// down and rebuild split views for nothing.
    private var renderedTree: PaneTree?
    private var renderedZoom: PaneID?

    /// Raised when any pane starts or stops asking for attention, with the
    /// projects that are asking. The window badges itself and notifies from this.
    var onAttentionChange: (([String]) -> Void)?

    /// Raised whenever something worth persisting changes: the tree, the focus,
    /// a pin, or a pane's working directory. The owner debounces and writes.
    var onSessionChange: (() -> Void)?

    init(workingDirectory: String) {
        let first = PaneID()
        workspace = Workspace(pane: first)
        self.workingDirectory = workingDirectory
        super.init(nibName: nil, bundle: nil)
        panes[first] = makePane(id: first, workingDirectory: workingDirectory)
    }

    /// Rebuilds a window from a snapshot.
    ///
    /// The snapshot is expected to have been reconciled already, so every pane in
    /// the tree has a matching record and every recorded directory exists. A pane
    /// the tree names but the records do not still gets built, at the default
    /// directory, because a window that renders is better than one that refuses
    /// to open over a bookkeeping mismatch.
    init(restoring snapshot: SessionSnapshot, defaultWorkingDirectory: String) {
        workspace = snapshot.workspace
        workingDirectory = defaultWorkingDirectory
        super.init(nibName: nil, bundle: nil)

        let records = Dictionary(
            snapshot.panes.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for id in snapshot.workspace.tabs.flatMap({ $0.tree.paneIDs }) {
            let record = records[id]
            panes[id] = makePane(
                id: id,
                workingDirectory: record?.workingDirectory ?? defaultWorkingDirectory,
                pinnedDirectory: record?.pinnedDirectory.map {
                    URL(filePath: $0, directoryHint: .isDirectory)
                }
            )
        }
    }

    /// What the session file records for this window.
    ///
    /// Pane records are taken from the live controllers rather than from anything
    /// cached, so a directory the shell moved to since the last write is included.
    func snapshot(windowFrame: WindowFrame?) -> SessionSnapshot {
        SessionSnapshot(
            workspace: workspace,
            panes: workspace.tabs
                .flatMap { $0.tree.paneIDs }
                .compactMap { panes[$0]?.paneState },
            windowFrame: windowFrame
        )
    }

    private var focusedPaneID: PaneID? { workspace.focusedPane }

    private var tree: PaneTree? { workspace.focusedTab?.tree }

    private var zoomedPane: PaneID? { workspace.focusedTab?.zoomedPane }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("baia does not use nibs")
    }

    var focusedPane: TerminalPaneController? {
        focusedPaneID.flatMap { panes[$0] }
    }

    var paneCount: Int { panes.count }

    var isZoomed: Bool { zoomedPane != nil }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1024, height: 680))
        container.wantsLayer = true
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuild()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusedPane?.takeFocus()
        observeWindowActivation()
        syncPanePresentation()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        for observer in activationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        activationObservers.removeAll()
    }

    /// The whole window recedes when it stops being key.
    ///
    /// Observed here rather than in the window controller because the scrim is a
    /// property of each pane, and this is the only object that knows them all.
    /// Both notifications are needed: `didResignKey` does not fire for a window
    /// that was never key, so a window restored behind another one would open at
    /// full contrast and only correct itself once clicked.
    private func observeWindowActivation() {
        guard let window = view.window, activationObservers.isEmpty else { return }
        let centre = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            activationObservers.append(
                centre.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.syncPanePresentation() }
                }
            )
        }
    }

    /// Tells every pane whether it is the focused one and whether its window is
    /// key.
    ///
    /// Driven from here rather than left to `terminalDidChangeFocus` alone. That
    /// callback fires on a responder change, which covers a click but not a pane
    /// created by a split, a pane restored from a session, or a window that
    /// changed key state without any pane's responder moving.
    private func syncPanePresentation() {
        let active = view.window?.isKeyWindow ?? true
        for (id, pane) in panes {
            pane.setPaneFocused(id == focusedPaneID)
            pane.isWindowActive = active
        }
    }

    // MARK: - Commands

    /// - Parameter workingDirectory: where the new pane opens. Nil means beside
    ///   the focused pane, in whatever directory it is currently in, which is the
    ///   ⌘D case. The palette passes a project instead, because splitting to a
    ///   project is a different intent from splitting to see more of this one.
    func splitFocusedPane(axis: SplitAxis, workingDirectory requested: String? = nil) {
        let new = PaneID()
        // The new pane opens where the focused one currently is rather than at
        // the window's default, because splitting is how a second view of the
        // same project is opened and starting at $HOME would defeat that.
        let directory = requested
            ?? focusedPane?.anchorTracker.workingDirectory?.path(percentEncoded: false)
            ?? workingDirectory
        guard workspace.splitFocusedPane(axis: axis, newPane: new, ratio: 0.5) else { return }
        panes[new] = makePane(id: new, workingDirectory: directory)
        rebuild()
        focusPane(new)
        onSessionChange?()
    }

    func closeFocusedPane() {
        guard let closing = focusedPaneID else { return }
        guard workspace.closeFocusedPane() else {
            // The last pane of the window. Dropping it here would leave an empty
            // window, so the owner closes instead, which releases this whole
            // controller and with it the pane's shell.
            onEmpty?()
            return
        }
        // Dropped before the rebuild so the controller, and therefore the pty,
        // is released rather than lingering until the next mutation.
        panes[closing] = nil
        rebuild()
        if let next = focusedPaneID { focusPane(next) }
        onSessionChange?()
    }

    func moveFocus(_ direction: FocusDirection) {
        guard workspace.moveFocus(direction), let next = focusedPaneID else { return }
        focusPane(next)
    }

    func focusNextPane() {
        guard workspace.focusNextPane(), let next = focusedPaneID else { return }
        focusPane(next)
    }

    func toggleZoom() {
        guard workspace.toggleZoomOnFocusedPane() else { return }
        rebuild()
        focusedPane?.takeFocus()
        syncPanePresentation()
    }

    private func focusPane(_ id: PaneID) {
        guard let pane = panes[id] else { return }
        pane.takeFocus()
        syncPanePresentation()
        onFocusedPaneChange?()
        onSessionChange?()
    }

    // MARK: - Rendering

    private func makePane(
        id: PaneID,
        workingDirectory: String,
        pinnedDirectory: URL? = nil
    ) -> TerminalPaneController {
        let pane = TerminalPaneController(
            paneID: id,
            workingDirectory: workingDirectory,
            pinnedDirectory: pinnedDirectory
        )
        pane.theme = theme
        // Clicking a pane makes its surface first responder, and the workspace
        // has to agree, or the next arrow key would traverse from wherever the
        // model still thought focus was.
        pane.onFocusGained = { [weak self] in
            guard let self, focusedPaneID != id else { return }
            workspace.focusPane(id)
            syncPanePresentation()
            onFocusedPaneChange?()
        }
        pane.onAnchorChange = { [weak self] in
            guard let self else { return }
            // Every pane reports, not only the focused one, because the session
            // records each pane's own directory and pin. Only the focused pane
            // renames the window.
            onSessionChange?()
            guard focusedPaneID == id else { return }
            onFocusedPaneChange?()
        }
        pane.onAttentionChange = { [weak self] in
            guard let self else { return }
            // Reported for every pane, not only the focused one. A pane asking
            // while the user looks at another is the entire case this serves.
            onAttentionChange?(waitingProjects)
        }
        pane.onProcessClose = { [weak self] in
            guard let self else { return }
            // The shell that exited is not necessarily the focused one, so the
            // workspace is pointed at it before the close.
            workspace.focusPane(id)
            closeFocusedPane()
        }
        return pane
    }

    /// Rebuilds the container hierarchy from the tree, reusing every existing
    /// pane controller.
    ///
    /// Split containers are cheap and are recreated wholesale, but a pane
    /// controller never is: recreating one would build a new surface and spawn a
    /// new shell, losing the scrollback and whatever was running. Moving a live
    /// terminal view to a new parent is safe, because libghostty rebuilds a
    /// surface only when it has none, so the instance carries its pty with it.
    private func rebuild() {
        guard let current = tree else { return }
        guard renderedTree != current || renderedZoom != zoomedPane else { return }
        renderedTree = current
        renderedZoom = zoomedPane

        for child in children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }

        guard let displayed = displayedTree else { return }
        let content = makeViewController(for: displayed)
        addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.topAnchor.constraint(equalTo: view.topAnchor),
            content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// A zoomed pane renders alone. Zoom is presentation only, so the tree keeps
    /// its shape and unzooming needs no reconstruction.
    private var displayedTree: PaneTree? {
        guard let current = tree else { return nil }
        guard let zoomed = zoomedPane, panes[zoomed] != nil else { return current }
        return .leaf(zoomed)
    }

    private func makeViewController(for node: PaneTree) -> NSViewController {
        switch node {
        case let .leaf(id):
            // A pane missing from the map would be a tree and a controller set
            // that disagree, so render an empty placeholder rather than trapping
            // and taking the whole window down with it.
            return panes[id] ?? NSViewController()
        case let .split(axis, ratio, first, second):
            let split = PaneSplitController(axis: axis, ratio: ratio, theme: theme)
            split.setChildren(
                first: makeViewController(for: first),
                second: makeViewController(for: second)
            )
            return split
        }
    }

    /// The projects of every pane currently asking for attention, in visual
    /// order so the same set always reads the same way.
    var waitingProjects: [String] {
        workspace.tabs
            .flatMap { $0.tree.paneIDs }
            .compactMap { panes[$0] }
            .filter(\.wantsAttention)
            .map { $0.anchorTracker.anchor?.displayName ?? "baia" }
    }

    var windowTitle: (title: String, subtitle: String) {
        focusedPane?.windowTitle ?? ("baia", "")
    }

    /// The path this window's tab is disambiguated with.
    var tabPath: String { focusedPane?.tabPath ?? "baia" }

    /// This window's tab label, given the disambiguated project name.
    func tabTitle(project: String, budget: TabTitle.Budget) -> String {
        focusedPane?.tabTitle(project: project, budget: budget) ?? project
    }
}

/// One split node: exactly two children and one divider.
///
/// `NSSplitViewController` rather than a bare `NSSplitView` because it maintains
/// the divider's autolayout constraints, and a terminal view has no intrinsic
/// size to fall back on when those are wrong.
final class PaneSplitController: NSSplitViewController {
    private let axis: SplitAxis
    private let ratio: Double
    private let theme: PaneTheme

    init(axis: SplitAxis, ratio: Double, theme: PaneTheme) {
        self.axis = axis
        self.ratio = ratio
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    /// The split view is built here rather than left to `NSSplitViewController`
    /// so that the divider can be a subclass. Assigned before `viewDidLoad`
    /// touches it, since the controller creates a plain one lazily on first
    /// access and replacing it afterwards loses the items already added.
    override func loadView() {
        let split = PaneSplitView()
        split.paneTheme = theme
        splitView = split
        super.loadView()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("baia does not use nibs")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The inversion that reads wrong every time. `isVertical` describes the
        // DIVIDER, not the arrangement: a vertical divider puts the children
        // side by side. `.horizontal` here means the children sit side by side,
        // so it maps to `isVertical == true`. Getting this backwards produces a
        // layout that works and is rotated, which no test of the tree can catch.
        splitView.isVertical = (axis == .horizontal)
        // `dividerStyle = .thin` is deliberately absent. AppKit's thin separator
        // is drawn from the *system* appearance, so a pane on a dark terminal
        // theme under a light system appearance grows a bright line across it,
        // which is the one rule the whole chrome layer exists to keep.
    }

    func setChildren(first: NSViewController, second: NSViewController) {
        for item in splitViewItems { removeSplitViewItem(item) }
        for child in [first, second] {
            let item = NSSplitViewItem(viewController: child)
            // A pane narrower than this cannot show a useful terminal, and a
            // pane at zero width is an invisible live shell.
            item.minimumThickness = 96
            item.canCollapse = false
            item.holdingPriority = .defaultLow
            addSplitViewItem(item)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyRatio()
    }

    /// Widens the region the mouse can grab without widening the divider itself.
    ///
    /// This is the reason `PaneSplitView` exists. Making the divider thicker to
    /// make it grabbable takes seven points of terminal away from one side, and
    /// every one of those changes the ghostty grid and sends `SIGWINCH` to
    /// whatever is running in the pane. The additional rect changes only where
    /// the mouse finds it, and costs the panes nothing.
    override func splitView(
        _ splitView: NSSplitView,
        additionalEffectiveRectOfDividerAt _: Int
    ) -> NSRect {
        (splitView as? PaneSplitView)?.effectiveDividerRect() ?? .zero
    }

    /// Applied after layout because the ratio is a fraction of a thickness that
    /// does not exist until the split view has been sized. Guarded on a real
    /// thickness so the first pass, where everything is zero, does not pin the
    /// divider at the origin and leave one pane collapsed.
    private func applyRatio() {
        guard splitViewItems.count == 2 else { return }
        let thickness = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard thickness > 0 else { return }
        let target = thickness * ratio
        let current = splitView.isVertical
            ? splitViewItems[0].viewController.view.frame.width
            : splitViewItems[0].viewController.view.frame.height
        // A half point of tolerance. Reassigning the position on every layout
        // pass would fight the user's own divider drag, since a drag triggers
        // the layout that would immediately undo it.
        guard abs(current - target) > 0.5 else { return }
        splitView.setPosition(target, ofDividerAt: 0)
    }
}

/// The plank between two stalls.
///
/// Three things it does that AppKit's own divider does not. It takes its colour
/// from the terminal theme rather than from the system appearance, which is the
/// one place that leak was still open. It sits two steps below the footer
/// hairline, so the line *between* panes never outranks the line *under* one.
/// And it widens the region the mouse can grab without widening the divider
/// itself.
///
/// That last one is the reason this class exists at all. Making the divider
/// thicker to make it grabbable takes seven points of terminal away from one
/// side, and every one of those changes the ghostty grid and sends `SIGWINCH` to
/// whatever is running. `additionalEffectiveRectOfDivider(at:)` changes only
/// where the mouse finds it, and costs the panes nothing.
final class PaneSplitView: NSSplitView {
    var paneTheme: PaneTheme = .darkPastel {
        didSet {
            guard paneTheme != oldValue else { return }
            needsDisplay = true
        }
    }

    /// True while the user is dragging this divider, so it can brighten.
    private var isDragging = false

    override var dividerThickness: CGFloat { 1 }

    override var dividerColor: NSColor {
        let colour = isDragging ? paneTheme.edgeFocus : paneTheme.divider
        return NSColor(
            srgbRed: CGFloat(colour.red),
            green: CGFloat(colour.green),
            blue: CGFloat(colour.blue),
            alpha: 1
        )
    }

    /// Three and a half points either side, so a seven-point band answers the
    /// mouse for a one-point line.
    ///
    /// Not an override: `additionalEffectiveRectOfDivider(at:)` is declared on
    /// `NSSplitViewDelegate`, not on `NSSplitView`. Written as an override here
    /// it compiles as a new method that AppKit never calls, which looks exactly
    /// like a divider that is simply hard to grab.
    var grabSlack: CGFloat { 3.5 }

    func effectiveDividerRect() -> NSRect {
        guard subviews.count >= 2 else { return .zero }
        let first = subviews[0].frame

        if isVertical {
            return NSRect(
                x: first.maxX - grabSlack,
                y: bounds.minY,
                width: dividerThickness + grabSlack * 2,
                height: bounds.height
            )
        }
        return NSRect(
            x: bounds.minX,
            y: first.maxY - grabSlack,
            width: bounds.width,
            height: dividerThickness + grabSlack * 2
        )
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        needsDisplay = true
        super.mouseDown(with: event)
        // `super.mouseDown` runs the drag to completion in its own event loop, so
        // this lands when the mouse comes up rather than immediately.
        isDragging = false
        needsDisplay = true
    }
}
