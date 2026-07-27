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
    /// The palette the split dividers are drawn from, from the config file's
    /// theme rather than fixed. Chrome matches the theme, never the reverse, so a
    /// hardcoded Dark Pastel here would put a Dark Pastel line between two panes
    /// of some other theme.
    var theme: PaneTheme { configuration.paneTheme }

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
    /// The full waiting list, plus the project and message of the pane whose
    /// attention just changed.
    ///
    /// The asking pane is carried rather than re-derived. Reading
    /// `waitingProjects.last` at the far end names whichever pane happens to sit
    /// last in visual order, so with two panes asking the banner announced the
    /// wrong repository, and the message the pane sent through OSC 9 was thrown
    /// away entirely.
    var onAttentionChange: (([String], String, String?) -> Void)?

    /// Raised whenever something worth persisting changes: the tree, the focus,
    /// a pin, or a pane's working directory. The owner debounces and writes.
    var onSessionChange: (() -> Void)?

    /// The settings the panes of this window are configured from.
    ///
    /// Passed in rather than reached for, because both initializers build panes
    /// before the caller could assign it, and a pane that comes up unconfigured
    /// and is corrected a frame later flickers through libghostty's defaults.
    private let configuration: ConfigurationCenter

    init(workingDirectory: String, configuration: ConfigurationCenter) {
        let first = PaneID()
        workspace = Workspace(pane: first)
        self.workingDirectory = workingDirectory
        self.configuration = configuration
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
    init(
        restoring snapshot: SessionSnapshot,
        defaultWorkingDirectory: String,
        configuration: ConfigurationCenter
    ) {
        workspace = snapshot.workspace
        workingDirectory = defaultWorkingDirectory
        self.configuration = configuration
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

    /// Every pane in this window, in visual order, which is the order a
    /// workspace-wide search reports its results in.
    ///
    /// Ordered through the layout tree rather than read off `panes`, which is a
    /// dictionary and would hand back a different order on every call, so the
    /// same search would list its hits differently each time it was run.
    var allPanes: [TerminalPaneController] {
        workspace.tabs.flatMap { $0.tree.paneIDs }.compactMap { panes[$0] }
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

    /// Grows the focused pane one keyboard step in that direction.
    ///
    /// Deliberately not through `rebuild()`, which is what every other command
    /// here does. `rebuild()` removes every child view, which leaves the window
    /// with no first responder until something re-focuses a pane, and
    /// `AppTerminalView.performKeyEquivalent` opens by checking that it *is* the
    /// first responder: a pane that lost it silently answers no ghostty binding
    /// at all, with nothing on screen to say why. Under key repeat that would
    /// happen many times a second, reparenting the live surface each time. This
    /// takes the same push path a finished drag does instead.
    func resizeFocusedPane(_ direction: FocusDirection) {
        guard workspace.resizeFocusedPane(direction, by: PaneTree.keyboardResizeStep) else { return }
        pushRatios()
    }

    /// Puts every divider in this window back to the middle.
    func equalizePanes() {
        guard workspace.equalizeFocusedTab() else { return }
        pushRatios()
    }

    /// Moves the dividers that are already on screen to what the tree now says.
    ///
    /// The same three steps ``recordRatio(at:_:)`` takes, in the other order: a
    /// drag has already moved the divider by the time the model hears about it,
    /// while a key changes the model first and the divider has to follow.
    ///
    /// `renderedTree` is load-bearing here too. Leaving it behind the tree would
    /// make the next rebuild, including the one a theme change runs, tear down and
    /// rebuild every pane in the window.
    private func pushRatios() {
        renderedTree = tree
        if let current = displayedTree, let root = children.first {
            PaneSplitController.applyRatios(of: current, to: root)
        }
        onSessionChange?()
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
        // Configured before anything else touches it, and before the view loads,
        // so the surface is built already themed rather than coming up in
        // libghostty's defaults and changing under the owner a frame later. This
        // also supplies the pane's theme, so the local `theme` assignment that
        // used to be here would only overwrite it with a stale value.
        configuration.register(pane)
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
        pane.onAttentionChange = { [weak self, weak pane] in
            guard let self else { return }
            // Reported for every pane, not only the focused one. A pane asking
            // while the user looks at another is the entire case this serves.
            onAttentionChange?(
                waitingProjects,
                pane?.anchorTracker.anchor?.displayName ?? "baia",
                pane?.attentionMessage
            )
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
    /// Repaints the dividers after a theme change.
    ///
    /// Pushed into the views that are already on screen, never through
    /// `rebuild()`. `rebuild()`'s first statement returns unless the tree or the
    /// zoom changed, and a theme change moves neither, so routing through it was
    /// a no-op: a divider kept the old theme's colour until some unrelated split
    /// happened to rebuild it. Forcing it past that guard is the worse half of the
    /// trade, since it removes every child and reparents every live ghostty
    /// surface, which is a `SIGWINCH` to whatever is running in each of them for a
    /// colour.
    ///
    /// `super.drawDivider(in:)` re-reads `dividerColor` on every draw, so a stored
    /// theme plus a `needsDisplay` is the entire repaint, with no teardown.
    ///
    /// The panes are deliberately not walked: ``ConfigurationCenter`` re-themes
    /// each surface itself.
    func refreshTheme() {
        for child in children { PaneSplitController.applyTheme(theme, to: child) }
    }

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
        let content = makeViewController(for: displayed, at: SplitPath())
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

    /// - Parameter path: where `node` sits in the displayed tree, so a split can
    ///   name itself when its divider is dragged. Valid for the controller's whole
    ///   lifetime: every structural change goes through ``rebuild()``, which
    ///   reconstructs the lot against the new tree.
    private func makeViewController(for node: PaneTree, at path: SplitPath) -> NSViewController {
        switch node {
        case let .leaf(id):
            // A pane missing from the map would be a tree and a controller set
            // that disagree, so render an empty placeholder rather than trapping
            // and taking the whole window down with it.
            return panes[id] ?? NSViewController()
        case let .split(axis, ratio, first, second):
            let split = PaneSplitController(axis: axis, ratio: ratio, path: path, theme: theme)
            split.onRatioChange = { [weak self] path, ratio in
                self?.recordRatio(at: path, ratio)
            }
            split.setChildren(
                first: makeViewController(for: first, at: path.appending(0)),
                second: makeViewController(for: second, at: path.appending(1))
            )
            return split
        }
    }

    /// Writes a finished drag into the tree.
    ///
    /// No `rebuild()`. A ratio is not a structural change, and rebuilding for one
    /// would remove every child and reparent every live ghostty surface, which is
    /// a `SIGWINCH` to whatever is running in each of them for a divider that has
    /// already moved on screen.
    private func recordRatio(at path: SplitPath, _ ratio: Double) {
        guard workspace.setRatio(at: path, to: ratio) else { return }
        // Load-bearing. `renderedTree` is what `rebuild()` compares against, and
        // leaving it behind the tree would make the next rebuild, including the
        // one `refreshTheme()` runs for a colour change, tear down and rebuild
        // every pane in the window.
        renderedTree = tree
        onSessionChange?()
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
    /// The narrowest either pane may be, in points, and therefore how close to an
    /// edge a divider can ever sit. A pane narrower than this cannot show a
    /// useful terminal, and a pane at zero width is an invisible live shell.
    ///
    /// Shared with ``applyRatio()`` rather than written only on the items,
    /// because a ratio whose position falls inside this margin is a target
    /// `NSSplitView` will refuse, and asking for it again on every layout pass is
    /// a loop the process does not survive.
    static let minimumPaneThickness: CGFloat = 96

    private let axis: SplitAxis

    /// The palette this split's divider is drawn from.
    ///
    /// A `var` because the config file's theme can change while the window is up,
    /// and the only alternative to pushing the new value into the split that is
    /// already on screen is rebuilding the hierarchy, which reparents every live
    /// terminal. Always the terminal theme, never the system appearance: that is
    /// the leak `PaneSplitView` exists to close.
    var theme: PaneTheme {
        didSet {
            guard theme != oldValue else { return }
            // Only once the view exists. Reading `splitView` before that makes
            // `NSSplitViewController` build one, and `loadView()` reads the stored
            // value on its own way through.
            guard isViewLoaded else { return }
            (splitView as? PaneSplitView)?.paneTheme = theme
        }
    }

    /// Where the divider sits, as the first child's fraction of this split.
    ///
    /// A `var`, and that is the whole bug this file used to have. Seeded from the
    /// tree and then enforced on every layout pass, it was authoritative over a
    /// value nothing could ever change, so every drag was undone by the layout
    /// pass the drag itself triggered.
    private var ratio: Double

    /// Which split in the tree this controller renders, so a finished drag can
    /// name it. Pane ids cannot: the divider between a pane and a nested column
    /// belongs to the outer split, and the pane-keyed mutator resolves to the
    /// innermost one.
    private let path: SplitPath

    /// Raised when a drag lands the divider somewhere new. The owner writes it
    /// into the tree; nothing here persists anything itself.
    var onRatioChange: ((SplitPath, Double) -> Void)?

    /// Where the divider sat when the gesture in progress began, if one is.
    /// Read once at mouse-up to tell a drag from a click.
    private var positionAtDragStart: CGFloat?

    init(axis: SplitAxis, ratio: Double, path: SplitPath, theme: PaneTheme) {
        self.axis = axis
        self.ratio = ratio
        self.path = path
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
        split.onDragWillBegin = { [weak self] in
            guard let self else { return }
            positionAtDragStart = firstChildThickness
        }
        split.onDragFinished = { [weak self] in self?.recordDrag() }
        splitView = split
        super.loadView()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("baia does not use nibs")
    }

    /// Pushes a theme into every split at or below `controller`.
    ///
    /// Static, and here rather than on the owner, so the walk sits inside the
    /// region the pane-resize probes slice out of this file and can therefore be
    /// proven headlessly. The owner keeps only the loop over its own children.
    ///
    /// Anything that is not a split ends the descent. A pane is re-themed by
    /// ``ConfigurationCenter`` directly and has no divider to repaint.
    static func applyTheme(_ theme: PaneTheme, to controller: NSViewController) {
        guard let split = controller as? PaneSplitController else { return }
        split.theme = theme
        for child in split.children { applyTheme(theme, to: child) }
    }

    /// Pushes every ratio in `tree` into the splits already on screen under
    /// `controller`, which is how a keyboard resize moves a divider.
    ///
    /// The tree and the hierarchy are walked in lockstep rather than the split
    /// being looked up by ``SplitPath``, because equalizing moves every divider at
    /// once and a per-path lookup would walk the same spine once per split.
    ///
    /// Static, and here rather than on the owner, for the reason ``applyTheme(_:to:)``
    /// is: it puts the whole push inside the region the pane-resize probes slice
    /// out of this file, so a keyboard resize can be driven headlessly.
    ///
    /// Nothing is torn down. `rebuild()` would remove every child view and leave
    /// the window with no first responder, which silently disables every ghostty
    /// binding in the pane the user is typing in, and it would reparent each live
    /// surface, which is a `SIGWINCH` per keystroke to whatever is running.
    static func applyRatios(of tree: PaneTree, to controller: NSViewController) {
        guard case let .split(_, ratio, first, second) = tree,
              let node = controller as? PaneSplitController
        else { return }
        node.setRatio(ratio)
        // A split always has exactly two items once `setChildren` has run, and
        // before that there is nothing on screen to move.
        guard node.splitViewItems.count == 2 else { return }
        applyRatios(of: first, to: node.splitViewItems[0].viewController)
        applyRatios(of: second, to: node.splitViewItems[1].viewController)
    }

    /// Moves this divider to a ratio the model has already accepted.
    ///
    /// The stored value is assigned even when the view is not loaded yet, since
    /// that is what `viewDidLayout` reads on its first pass. `applyRatio()` is the
    /// same enforcement a layout pass runs, so a keyboard resize cannot reach a
    /// position a drag could not: it goes through ``reachablePosition(in:)``, which
    /// is what keeps a split too small to seat both minimums from asking for a
    /// position `NSSplitView` refuses on every pass until AppKit gives up and the
    /// process dies.
    func setRatio(_ ratio: Double) {
        self.ratio = ratio
        guard isViewLoaded else { return }
        applyRatio()
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
            item.minimumThickness = Self.minimumPaneThickness
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
        // While the user's hand is on the divider the user is authoritative.
        // Harnesses disagreed on whether a layout pass arrives mid-gesture at all,
        // and this costs one bool to be right either way.
        guard !((splitView as? PaneSplitView)?.isDragging ?? false) else { return }
        guard splitViewItems.count == 2 else { return }
        let thickness = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard thickness > 0 else { return }
        guard let target = reachablePosition(in: thickness) else { return }
        let current = firstChildThickness
        // A half point of tolerance. Reassigning the position on every layout
        // pass would fight the user's own divider drag, since a drag triggers
        // the layout that would immediately undo it.
        guard abs(current - target) > 0.5 else { return }
        splitView.setPosition(target, ofDividerAt: 0)
    }

    /// Where the divider can actually sit for the stored ratio, or nil when the
    /// split is too small to give both panes their minimum and there is no legal
    /// position at all.
    ///
    /// This is the difference between a divider that stops at the edge of the
    /// last usable column and a dead app. `NSSplitViewItem.minimumThickness`
    /// refuses any position inside its margin, so once `thickness * ratio` falls
    /// there, `setPosition` never lands, `current` never equals `target`, and
    /// every layout pass asks again. Each refused request re-dirties layout, and
    /// for a nested split, which its parent re-lays out on every pass anyway,
    /// that never converges: AppKit gives up with `NSGenericException`, "the
    /// window has been marked as needing another Update Constraints in Window
    /// pass", and the process dies. It is reachable two ways, both ordinary. Drag
    /// a nested divider near its stop and then make the window smaller. Or do
    /// that, quit, and relaunch into the saved frame, which is worse: the crash
    /// arrives during construction, every launch reads the same session file, and
    /// the only way out is deleting it by hand.
    ///
    /// Clamping the applied position and not the stored ratio is deliberate. The
    /// tree keeps what the user asked for, so re-widening the window restores the
    /// arrangement instead of a value bent to fit the smallest it ever got.
    private func reachablePosition(in thickness: CGFloat) -> CGFloat? {
        let lowest = Self.minimumPaneThickness
        let highest = thickness - Self.minimumPaneThickness - splitView.dividerThickness
        guard highest >= lowest else { return nil }
        return min(max(thickness * ratio, lowest), highest)
    }

    /// Where the divider ended up, measured the one way both halves of this
    /// controller agree on.
    ///
    /// `splitViewItems[0].viewController.view.frame` rather than
    /// `splitView.subviews[0].frame`: `NSSplitViewController` wraps each child in
    /// an item view of its own and the two rects are not the same. Recording a
    /// drag from one and enforcing it from the other would leave a permanent
    /// disagreement, and `applyRatio` would tug the divider on every layout pass
    /// instead of early-returning.
    private var firstChildThickness: CGFloat {
        guard let first = splitViewItems.first?.viewController.view else { return 0 }
        return splitView.isVertical ? first.frame.width : first.frame.height
    }

    /// Turns a finished drag into a fraction and reports it.
    ///
    /// Clamped through ``PaneTree/clampedRatio(_:)``, the same function the model
    /// applies, so the stored value and the drawn position cannot drift apart and
    /// leave the divider to jump on some later layout pass.
    private func recordDrag() {
        let start = positionAtDragStart
        positionAtDragStart = nil
        guard splitViewItems.count == 2 else { return }
        let thickness = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard thickness > 0 else { return }
        let current = firstChildThickness
        // Did the divider move, in the same half point `applyRatio` settles at.
        // Comparing the measured fraction against the stored `ratio` instead
        // destroyed arrangements: wherever `minimumPaneThickness` holds the
        // divider off the stored ratio, and that is any split where the ratio
        // puts the divider inside the margin, the two differ permanently, so a
        // bare click wrote the clamped position into the tree and the session
        // file. There is no `mouseDragged` to consult here, because
        // `NSSplitView`'s tracking loop eats its own events, so where the divider
        // started is the only honest record of what the gesture did.
        guard let start, abs(current - start) > 0.5 else { return }
        let fraction = PaneTree.clampedRatio(current / thickness)
        ratio = fraction
        onRatioChange?(path, fraction)
        // Settle onto the clamped value now rather than waiting for a layout pass
        // that may not come. A drag past the clamp otherwise sits where the mouse
        // left it until something unrelated dirties the layout.
        applyRatio()
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
    ///
    /// Readable by the controller as well, which suspends its own ratio
    /// enforcement for the length of the gesture. While the user's hand is on the
    /// divider the user is authoritative, and a layout pass that arrives mid-drag
    /// must not argue with it.
    private(set) var isDragging = false

    /// Raised once, when a real drag ends. Carries nothing: the controller
    /// measures the result itself, with the same expression its own ratio
    /// enforcement uses, so the two cannot disagree about where the divider is.
    ///
    /// Hung off `mouseDown` rather than `splitViewDidResizeSubviews`, which also
    /// fires for the controller's own `setPosition` and would need a reentrancy
    /// guard to avoid a write-back loop. This fires for a user drag and nothing
    /// else.
    var onDragFinished: (() -> Void)?

    /// Raised as a gesture starts, before `NSSplitView`'s tracking loop has moved
    /// anything, so the controller can note where the divider was.
    ///
    /// Whether the divider moved is the only honest way to tell a drag from a
    /// click: `super.mouseDown` consumes its own drag events inside its tracking
    /// loop, so overriding `mouseDragged` here would never fire.
    var onDragWillBegin: (() -> Void)?

    override var dividerThickness: CGFloat { 1 }

    override var dividerColor: NSColor {
        // `inkFocus`, the same colour the focused anchor name and the footer's
        // focus frame take, rather than a blend of its own. A divider under the
        // mouse is one point and can carry full chroma, and matching the rest of
        // the focus signal is what stops the drag reading as a third colour the
        // eye has to learn.
        let colour = isDragging ? paneTheme.inkFocus : paneTheme.divider
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
        // Before `super`, which does not return until the mouse comes up.
        onDragWillBegin?()
        super.mouseDown(with: event)
        // `super.mouseDown` runs the drag to completion in its own event loop, so
        // this lands when the mouse comes up rather than immediately.
        isDragging = false
        needsDisplay = true
        // After the flag clears, so the controller's own settling `setPosition` is
        // not refused by its mid-drag guard.
        onDragFinished?()
    }
}
