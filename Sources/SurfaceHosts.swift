import AppKit
import PaneChrome
import WorkspaceLayout

/// `NSGlassEffectView`, with the same three refusals `PaneStatusBarView`'s own
/// glass backing makes.
///
/// A plain `NSGlassEffectView` hit-tests itself by AppKit's own default, and
/// every section's rows, headings and the two draggable strips already handle
/// their own `mouseDown`. Sitting this glass behind them (see
/// `SidebarHost.applyResolvedChrome()`) is only safe if it never intercepts a
/// click meant for one of them, the same reasoning
/// `PaneStatusGlassBacking`'s own doc comment gives for the footer.
private final class SidebarGlassBacking: NSGlassEffectView {
    override var acceptsFirstResponder: Bool { false }

    override var canBecomeKeyView: Bool { false }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// One or more surfaces in the window, beside the panes.
///
/// Becomes the window's `contentViewController`, with the pane tree as a child, so
/// the tree keeps owning every pane and this owns only the arithmetic of where the
/// tree ends and the sidebar begins. Nothing here reaches into a pane.
///
/// **What it costs, measured rather than assumed.** Taking width from the tree
/// resizes every ghostty grid and sends `SIGWINCH` to everything running. On
/// 2026-07-27 that was watched with a coding agent in a pane, across three widths
/// down to roughly 300 pt: the agent redrew whole every time and the shell's
/// scrollback re-wrapped and rejoined cleanly. The cost is churn, not damage.
///
/// Only *width* costs that. Everything this does afterwards, swapping the contents
/// or stacking two of them, changes heights inside a column whose width never moves,
/// so no grid is resized and nothing running is signalled. The one reflow a sidebar
/// costs is its first appearance.
@MainActor
final class SidebarHost: NSViewController {
    let tree: PaneTreeController

    /// The stacked sections, top to bottom.
    ///
    /// A list rather than one surface, because the changes and the tree are worth
    /// seeing together: the changes list is short and glanceable and the tree is long
    /// and browsable, so a short list above a scrolling tree is a column's natural
    /// shape rather than a compromise between two claims on it.
    private(set) var sections: [Section] = []

    /// A surface with the heading the host draws for it.
    struct Section {
        let surface: any WorkspaceSurface
        let heading = SurfaceTitleView()
    }

    /// Points taken from the panes.
    ///
    /// 260 because that is the width the reflow was measured at, so what the owner
    /// judges is what was tested. Replaced by the session file once one has been
    /// written.
    var width: Double = SidebarGeometry.default.width {
        didSet {
            guard width != oldValue else { return }
            view.needsLayout = true
            onGeometryChange?()
        }
    }

    /// Raised when a drag settles the column's size, so the session file records it.
    ///
    /// Raised on every step of a drag rather than at its end, because the saver
    /// coalesces: `AppDelegate.scheduleSave` already exists to keep a `cd` in every
    /// pane from rewriting the file several times a second, and a drag is the same
    /// shape of event.
    var onGeometryChange: (() -> Void)?

    /// What the session file carries, and what it restores.
    var geometry: SidebarGeometry {
        get { SidebarGeometry(width: width, splitHeight: firstSectionHeight) }
        set {
            width = newValue.width
            firstSectionHeight = newValue.splitHeight
            view.needsLayout = true
        }
    }

    /// What the file tree was left showing, per anchor, and what a relaunch puts
    /// back. Empty for a sidebar with no Files section, which is a real state:
    /// the section can be switched off, and a column showing only Changes has no
    /// expansions to report rather than none to remember.
    ///
    /// Read and written through the host for the reason ``geometry`` is: the
    /// delegate writes the session file and knows what a window is, and the
    /// sections are the host's business. Nothing outside gets to go hunting
    /// through `sections` for a surface to cast.
    var fileTreeExpansions: [String: [String]] {
        get {
            sections.lazy.compactMap { $0.surface as? FilesSurface }.first?
                .fileTreeExpansions ?? [:]
        }
        set {
            for section in sections {
                (section.surface as? FilesSurface)?.fileTreeExpansions = newValue
            }
        }
    }

    var theme: PaneTheme {
        didSet {
            for section in sections {
                section.surface.theme = theme
                section.heading.theme = theme
            }
            sessionHeader.theme = theme
            actionRow.theme = theme
            divider.layer?.backgroundColor = nsColor(theme.hairline).cgColor
        }
    }

    /// The session header row (28pt, design v5 §5), naming the same pane the
    /// column's sections describe. Set by ``AppDelegate/refreshSidebar(of:)``
    /// alongside ``anchorName``, from ``PaneChrome/PaneStatus`` directly rather
    /// than from a second derivation: see ``SidebarSessionHeaderView``.
    var sessionStatus: PaneStatus? {
        get { sessionHeader.status }
        set { sessionHeader.status = newValue }
    }

    private let sessionHeader = SidebarSessionHeaderView()

    /// The bottom action row (32pt, design v5 §5): "New session" and its
    /// keycap. Fired on click; what a new session means is the caller's
    /// business, the same split ``WorkspaceSurface/onSelect`` already keeps
    /// between a row that knows it was clicked and an owner that knows what
    /// clicking it does.
    var onNewSession: (() -> Void)? {
        get { actionRow.onNewSession }
        set { actionRow.onNewSession = newValue }
    }

    /// The keycap the action row draws. See ``SidebarActionRowView/keycap``:
    /// the caller sets this from `WorkspaceMenu.MenuBarLayout.shortcutText(of:)`
    /// so the row can never advertise a key its click does not perform.
    var newSessionKeycap: String {
        get { actionRow.keycap }
        set { actionRow.keycap = newValue }
    }

    private let actionRow = SidebarActionRowView()

    /// The repository the column is describing.
    ///
    /// Design v3 §4.2 had the first heading draw this trailing, "the connector
    /// between the footer and the sidebar". Design v5 §5 replaces that connector
    /// with ``sessionStatus``'s own row, so ``refreshHeadings()`` no longer feeds
    /// it to any heading; the property stays because ``SettingsPreviewColumn``
    /// still themes `SurfaceTitleView.anchorName` directly, and removing the
    /// value this host used to compute for it would be a change to that preview
    /// dressed up as a rename.
    var anchorName: String? {
        didSet { refreshHeadings() }
    }

    /// Whether the window is key, which the anchor name's accent is gated on.
    private var isWindowActive = true {
        didSet {
            guard isWindowActive != oldValue else { return }
            for section in sections { section.heading.isWindowActive = isWindowActive }
        }
    }

    /// Pushes what the headings draw beside their labels.
    ///
    /// Called by the caller that fed the surfaces rather than watched, because the
    /// count is a property of what was just assigned into them and nothing else
    /// changes it.
    func refreshHeadings() {
        for section in sections {
            section.heading.count = section.surface.headingCount
            section.heading.totals = section.surface.headingTotals
        }
    }

    /// What the sections fill their bodies at, so the column is the same material
    /// as the panes it sits beside. Design v3 §1.
    ///
    /// Held here rather than read by each surface, because it is a property of the
    /// window's material and not of a list of files, and because the two sections
    /// disagreeing about it is exactly the seam a design pass would then be asked
    /// to explain.
    var backgroundOpacity: Double = 1 {
        didSet {
            for section in sections { section.surface.backgroundOpacity = backgroundOpacity }
        }
    }

    /// What each section is told to resolve its own chrome against, and what
    /// ``glassBacking`` is built or torn down to match.
    ///
    /// **This host now has real glass of its own (this task).** Task 2 found
    /// the sidebar had never had one — its "glass" was ``ChangesSurface`` and
    /// ``FilesSurface`` swapping their scroll view's flat background colour for
    /// ``MaterialSet/fillSidebar``, an `rgba` fill with no `NSGlassEffectView`
    /// underneath it to reveal, and Task 2 dropped that fill along with the
    /// footer's tint. The glass-backdrop spike's sidebar arm (its README's
    /// finding 6) measured that an untinted `regular` glass column, positioned
    /// where the sidebar actually sits over the transparent window region,
    /// carries the file rows and (once repaired — see
    /// ``SurfaceTitleView/labelInk``) the CHANGED header both, and its
    /// verdict rejects the `NSSplitViewController` restructure this could have
    /// reached for instead.
    ///
    /// Pushed straight through to every ``Section/surface`` exactly as before,
    /// the same shape as ``theme`` and ``backgroundOpacity`` immediately above:
    /// the surfaces still decide their own fill (now: none at all under glass,
    /// so nothing opaque sits between this glass and what it samples — see
    /// ``ChangesSurface/fill()`` and ``FilesSurface/fill()``), this host only
    /// carries the resolution down and now also owns the glass itself.
    var resolvedChrome: ResolvedChrome = .flat {
        didSet {
            guard resolvedChrome != oldValue else { return }
            for section in sections { section.surface.resolvedChrome = resolvedChrome }
            for section in sections { section.heading.resolvedChrome = resolvedChrome }
            applyResolvedChrome()
        }
    }

    /// The glass material behind the sidebar's own column, or nil under flat.
    ///
    /// Created and torn down by ``applyResolvedChrome()``, not merely hidden —
    /// the same "absence is part of byte-identical" rule
    /// `PaneStatusBarView.glassBacking`'s doc comment states for the footer,
    /// and for the same reason: a hidden `NSGlassEffectView` still costs a
    /// compositing pass macOS runs whether or not it draws anything, and flat
    /// must not pay it.
    ///
    /// Added first, before `tree.view` and every section, so it sits behind
    /// the whole hierarchy in z-order — `NSGlassEffectView.style = .regular`
    /// samples what the window server has already composited beneath it, which
    /// for a borderless transparent window is the desktop, not this app's own
    /// views, so being behind them in z-order is what "sampling the desktop"
    /// actually requires; a glass view stacked *above* the sections would
    /// sample the sections instead and read as an opaque tint over them.
    private var glassBacking: SidebarGlassBacking?

    /// `NSGlassEffectView.tintColor` untinted, unconditionally.
    ///
    /// Written once at creation and never revisited by a later call the way
    /// the footer's `updateGlassTint()` is, because nothing on this host's own
    /// path ever has a reason to set one: unlike the bar's capsule, no element
    /// behind this glass is ever accented. Spelled out explicitly rather than
    /// left at the type's own default regardless — the same "never set a tint"
    /// rule the footer's untinting (Task 2) established, so a tint set here by
    /// a later, unrelated change is at least a diff against a line that says
    /// why it must stay nil rather than a silent default nobody has to
    /// contradict.
    private static let sidebarGlassTint: NSColor? = nil

    private let divider = NSView()

    /// The draggable split between two stacked sections.
    ///
    /// Only meaningful with two of them, and hidden otherwise. Dragging it changes
    /// heights inside a column whose width never moves, so it resizes no ghostty grid
    /// and signals no process: the only thing a sidebar does that costs a reflow is
    /// taking width from the panes in the first place.
    private lazy var sectionDivider: DividerGrabView = {
        let divider = DividerGrabView(axis: .vertical) { [weak self] delta in
            self?.dragSplit(by: delta)
        }
        // Reported to the heading *below* the split, which is the one whose top
        // edge the boundary is. The strip itself stays transparent and hit-only.
        divider.onTouch = { [weak self] touch in
            self?.sections.dropFirst().first?.heading.split = touch
        }
        return divider
    }()

    /// The grab area over the sidebar's own edge.
    ///
    /// The one drag that costs something. Widening takes room from the panes, which
    /// resizes every ghostty grid and signals everything running, once per frame of
    /// the drag. That was measured rather than feared and the output survives it, but
    /// it is the reason this is a deliberate drag on a visible edge rather than
    /// anything that can happen by accident.
    private lazy var widthDivider = DividerGrabView(axis: .horizontal) { [weak self] delta in
        self?.dragWidth(by: delta)
    }

    /// How tall the first section is when two are stacked.
    ///
    /// Starts at a value rather than at a share of the column, because the two
    /// surfaces are not symmetrical: a changes list is a handful of rows and a file
    /// tree is a whole repository, so an even split leaves half the column holding
    /// three lines. Dragging replaces the guess with the owner's answer.
    /// Read by ``geometry`` and written by a drag. Not private for that reason
    /// alone: the clamp that keeps it usable lives in layout, where the column's
    /// height is known.
    private(set) var firstSectionHeight: Double = SidebarGeometry.default.splitHeight

    init(
        tree: PaneTreeController,
        surfaces: [any WorkspaceSurface],
        theme: PaneTheme,
        backgroundOpacity: Double,
        resolvedChrome: ResolvedChrome
    ) {
        self.tree = tree
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        self.resolvedChrome = resolvedChrome
        super.init(nibName: nil, bundle: nil)
        sections = surfaces.map(Section.init(surface:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Replaces what the column is showing. An empty list closes it.
    ///
    /// The whole stack at once rather than one section at a time, because the states
    /// worth being in are named sets rather than a pile of independent toggles, and
    /// swapping the set is what the config key already says.
    ///
    /// Closing is a width of zero rather than a host that goes away. A host that came
    /// and went would have to swap the window's `contentViewController`, and that
    /// reparents every ghostty surface, which resizes every grid and signals every
    /// process. At zero width nothing is reparented and the cost is the ordinary
    /// reflow a width change already carries, which was measured clean.
    func show(_ surfaces: [any WorkspaceSurface]) {
        for section in sections {
            section.surface.view.removeFromSuperview()
            section.heading.removeFromSuperview()
        }
        sections = surfaces.map(Section.init(surface:))
        install()
        view.needsLayout = true
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1024, height: 680))
        container.wantsLayer = true
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Built before anything else touches `view`, so a sidebar constructed
        // already configured for glass (the common case: `resolvedChrome` was
        // set in `init` and this is the first time anything asked for `view`)
        // never has a frame where the backing is momentarily missing.
        applyResolvedChrome()

        addChild(tree)
        view.addSubview(tree.view)

        divider.wantsLayer = true
        divider.layer?.backgroundColor = nsColor(theme.hairline).cgColor
        view.addSubview(divider)

        sectionDivider.wantsLayer = true
        view.addSubview(sectionDivider)

        widthDivider.wantsLayer = true
        view.addSubview(widthDivider)

        sessionHeader.theme = theme
        actionRow.theme = theme
        view.addSubview(sessionHeader)
        view.addSubview(actionRow)

        install()
        refreshHeadings()
    }

    /// The key state the anchor name's accent is gated on, watched the way the
    /// pane tree watches it for the footers, and for the same reason: a window
    /// can change key without any responder in it moving.
    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window, windowObservers.isEmpty else { return }
        isWindowActive = window.isKeyWindow
        let centre = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(
                centre.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.isWindowActive = self?.view.window?.isKeyWindow ?? true
                    }
                }
            )
        }
    }

    /// Removed as the window goes away rather than in `deinit`, which is the same
    /// shape `PaneTreeController` uses and for the same reason: `deinit` is
    /// nonisolated and an observer token is not `Sendable`.
    override func viewWillDisappear() {
        super.viewWillDisappear()
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
    }

    private var windowObservers: [any NSObjectProtocol] = []

    private func install() {
        for section in sections {
            section.surface.theme = theme
            section.surface.backgroundOpacity = backgroundOpacity
            section.surface.resolvedChrome = resolvedChrome
            section.heading.title = section.surface.title
            section.heading.theme = theme
            section.heading.isWindowActive = isWindowActive
            section.heading.resolvedChrome = resolvedChrome
            view.addSubview(section.surface.view)
            view.addSubview(section.heading)
        }
        raiseGrabStrips()
        // `show(_:)` calls `install()` after `viewDidLoad` has already built
        // `glassBacking`, and every newly installed section view is added above
        // it in z-order by the two `addSubview` calls just above — no restack
        // needed here for the glass to keep reading as what is behind the
        // column rather than as a layer painted over it.
    }

    /// Creates or tears down ``glassBacking`` to match ``resolvedChrome``.
    ///
    /// The same shape `PaneStatusBarView.applyResolvedChrome()` takes for the
    /// footer: flat removes the view entirely rather than hiding it, and glass
    /// creates one only if none exists yet, so a chrome change that toggles
    /// glass-flat-glass does not tear down and rebuild a view that did not
    /// need to move.
    ///
    /// Safe to call before `view` has ever been laid out — `viewDidLoad` calls
    /// it first, before `tree.view` or any section exists — because it only
    /// inserts or removes a subview and sets its style; the frame that makes it
    /// cover the right column is `viewDidLayout`'s job, which runs afterwards
    /// regardless of whether this created a view this pass or found one
    /// already there.
    private func applyResolvedChrome() {
        switch resolvedChrome {
        case .flat:
            glassBacking?.removeFromSuperview()
            glassBacking = nil
        case .glass:
            guard glassBacking == nil else { break }
            let backing = SidebarGlassBacking(frame: .zero)
            backing.style = .regular
            backing.cornerRadius = 0
            backing.tintColor = Self.sidebarGlassTint
            backing.wantsLayer = true
            // First subview added to `view`, ahead of `tree.view` and every
            // section: see `glassBacking`'s own doc comment for why sitting
            // behind the whole hierarchy in z-order is what lets it sample the
            // window's own transparent region (the desktop) rather than this
            // app's other views.
            view.addSubview(backing, positioned: .below, relativeTo: nil)
            glassBacking = backing
        }
        view.needsLayout = true
    }

    /// **Both strips go back on top every time a section is installed.**
    ///
    /// `viewDidLoad` adds them before any section exists, so every `install()`
    /// buried them under a scroll view and a heading. Cursor rects do not consult
    /// the view order and hit testing does, which is the whole signature this was
    /// found by: the pointer turned into a resize arrow over a strip that could not
    /// be clicked.
    ///
    /// The sidebar's own edge hid it by half. Its right half lies over `tree.view`,
    /// which is added before it and stays below, so dragging the column worked as
    /// long as the grab started on the pane's side of the hairline and did nothing
    /// on the sidebar's. The split between the two sections has no such half: the
    /// changes list is above it on one side and the files heading on the other, so
    /// all seven points of it were dead.
    private func raiseGrabStrips() {
        for strip in [sectionDivider, widthDivider] {
            view.addSubview(strip, positioned: .above, relativeTo: nil)
        }
    }

    /// Laid out by hand rather than with constraints, the way the panel's three
    /// bands are: a column of stacked rects recomputed on resize is the case
    /// autolayout costs more than it saves.
    override func viewDidLayout() {
        super.viewDidLayout()

        let bounds = view.bounds
        let sidebarWidth = sections.isEmpty
            ? 0
            : min(width, max(0, bounds.width - Self.minimumPaneWidth))

        // Read from the width that was actually used, not from the sidebar's
        // existence. A window too narrow to give the sidebar any width leaves the
        // tree touching the left edge, and a tree told otherwise would keep its
        // leftmost footers square against a corner the window really does have.
        tree.edgesCoveredByHost = sidebarWidth > 0 ? [.left] : []
        divider.isHidden = sidebarWidth == 0

        // The glass column, sized to exactly the sidebar's own width and
        // nothing else. `bounds` spans the whole host — sidebar column plus the
        // pane tree beside it — and a glass view sized to all of it would
        // sample and composite pixels behind the panes too, which have their
        // own material (each pane's `backgroundOpacity` well) and need no
        // second glass layer over them. `isHidden` rather than a zero frame at
        // width 0: a `CGRect` of zero size is still a valid frame to hand
        // `NSGlassEffectView`, and hiding is the explicit statement that there
        // is no sidebar to back right now, matching `divider.isHidden` and
        // `widthDivider.isHidden` immediately around it.
        if let glassBacking {
            glassBacking.isHidden = sidebarWidth == 0
            glassBacking.frame = NSRect(
                x: bounds.minX,
                y: bounds.minY,
                width: sidebarWidth,
                height: bounds.height
            )
        }

        // The session header and the bottom action row are chrome around the
        // sections rather than sections themselves: fixed height, drawn even
        // when the sidebar has nothing in it. Hidden with the column, the same
        // rule the width divider follows, since a closed sidebar has no room
        // for either. `sessionHeader.status` is left as it was even while
        // hidden, so it needs no repopulating the moment the column reopens.
        let hasSidebar = sidebarWidth > 0
        sessionHeader.isHidden = !hasSidebar
        actionRow.isHidden = !hasSidebar
        sessionHeader.frame = NSRect(
            x: bounds.minX,
            y: bounds.maxY - Self.sessionHeaderHeight,
            width: sidebarWidth,
            height: Self.sessionHeaderHeight
        )
        actionRow.frame = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: sidebarWidth,
            height: Self.actionRowHeight
        )

        layoutSections(in: NSRect(
            x: bounds.minX,
            y: bounds.minY + (hasSidebar ? Self.actionRowHeight : 0),
            width: sidebarWidth,
            height: max(0, bounds.height - (hasSidebar ? Self.sessionHeaderHeight + Self.actionRowHeight : 0))
        ))

        let gutter = sidebarWidth > 0 ? Self.dividerWidth : 0
        // Centred on the hairline rather than beside it, so the pointer finds the
        // edge it can see. Hidden with the sidebar: there is no edge to drag when
        // the column is closed, and an invisible grab strip over the leftmost pane
        // would swallow clicks meant for the terminal.
        widthDivider.isHidden = sidebarWidth == 0
        widthDivider.frame = NSRect(
            x: bounds.minX + sidebarWidth - Self.grabHeight / 2,
            y: bounds.minY,
            width: Self.grabHeight,
            height: bounds.height
        )
        divider.frame = NSRect(
            x: bounds.minX + sidebarWidth,
            y: bounds.minY,
            width: gutter,
            height: bounds.height
        )
        tree.view.frame = NSRect(
            x: bounds.minX + sidebarWidth + gutter,
            y: bounds.minY,
            width: max(0, bounds.width - sidebarWidth - gutter),
            height: bounds.height
        )
    }

    /// Stacks the sections from the top down.
    ///
    /// Every section but the last is capped rather than given an equal share. The
    /// two surfaces are not symmetrical: a changes list is a handful of rows and a
    /// file tree is a whole repository, so splitting the column evenly would leave
    /// half of it holding three lines and the tree scrolling in the rest. The last
    /// section takes whatever is left, which is why the tree goes last.
    private func layoutSections(in column: NSRect) {
        sectionDivider.isHidden = sections.count < 2
        guard !sections.isEmpty else { return }

        firstSectionHeight = clampedSplit(firstSectionHeight, in: column)
        var top = column.maxY

        for (index, section) in sections.enumerated() {
            let isLast = index == sections.count - 1
            let available = top - column.minY
            let bodyHeight: Double = if isLast {
                max(0, available - SurfaceTitleView.height)
            } else {
                min(firstSectionHeight, max(0, available - SurfaceTitleView.height))
            }

            section.heading.frame = NSRect(
                x: column.minX,
                y: top - SurfaceTitleView.height,
                width: column.width,
                height: SurfaceTitleView.height
            )
            section.surface.view.frame = NSRect(
                x: column.minX,
                y: top - SurfaceTitleView.height - bodyHeight,
                width: column.width,
                height: bodyHeight
            )
            top -= SurfaceTitleView.height + bodyHeight

            if !isLast {
                sectionDivider.frame = NSRect(
                    x: column.minX,
                    y: top - Self.grabHeight / 2,
                    width: column.width,
                    height: Self.grabHeight
                )
            }
        }
    }

    /// Keeps both sections usable however far the drag went.
    ///
    /// A split that let either side reach zero would leave a heading with nothing
    /// under it, which reads as a surface that broke rather than one that was
    /// dragged shut.
    private func clampedSplit(_ height: Double, in column: NSRect) -> Double {
        guard sections.count > 1 else { return height }
        let chrome = SurfaceTitleView.height * Double(sections.count)
        let usable = max(0, column.height - chrome)
        return min(max(Self.minimumSectionHeight, height), max(Self.minimumSectionHeight, usable - Self.minimumSectionHeight))
    }

    /// Down is negative in this coordinate space, and dragging down should make the
    /// top section taller, so the delta is subtracted rather than added.
    /// Right is positive, and dragging right widens, so the delta is added.
    ///
    /// Clamped at both ends by the layout that follows: the sidebar never takes the
    /// panes below `minimumPaneWidth`, and it never goes below a width that can show
    /// a path.
    private func dragWidth(by delta: Double) {
        width = max(Self.minimumWidth, width + delta)
    }

    private func dragSplit(by delta: Double) {
        firstSectionHeight -= delta
        view.needsLayout = true
        onGeometryChange?()
    }

    private func nsColor(_ rgb: RGB) -> NSColor {
        NSColor(
            srgbRed: CGFloat(rgb.red),
            green: CGFloat(rgb.green),
            blue: CGFloat(rgb.blue),
            alpha: 1
        )
    }

    /// The sidebar yields rather than squeezing the panes to nothing. A window
    /// narrower than this plus the sidebar would otherwise leave a cell grid with
    /// no columns, which ghostty renders as an empty pane with no error.
    private static let minimumPaneWidth: Double = 320

    /// A hairline, the same one the tree draws between panes.
    private static let dividerWidth: Double = 1

    /// Named locally rather than read off ``SidebarSessionHeaderView/height``
    /// at every call site above, which is what every other geometry constant
    /// in this file already does for its own view.
    private static let sessionHeaderHeight = SidebarSessionHeaderView.height
    private static let actionRowHeight = SidebarActionRowView.height

    /// How little a stacked section may be dragged to.
    private static let minimumSectionHeight: Double = 48

    /// How narrow the column may be dragged.
    ///
    /// Below this a path is all ellipsis and the column says nothing, which is worse
    /// than a closed sidebar because it still costs the panes their width.
    private static let minimumWidth: Double = 120

    /// How tall the invisible grab area over the split is. Wider than the hairline
    /// it sits on, because a 1 pt target is one nobody can hit.
    private static let grabHeight: Double = 7
}
