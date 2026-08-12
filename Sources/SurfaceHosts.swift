import AppKit
import BaiaSettings
import PaneChrome
import WorkspaceLayout

/// `NSGlassEffectView`, with the same three refusals ``PaneGlassPlaneView``
/// makes.
///
/// A plain `NSGlassEffectView` hit-tests itself by AppKit's own default, and
/// every section's rows, headings and the two draggable strips already handle
/// their own `mouseDown`. Sitting this glass behind them (see
/// `SidebarHost.applyResolvedChrome()`) is only safe if it never intercepts a
/// click meant for one of them, the same reasoning `PaneGlassPlane.swift`
/// gives for the pane: glass that hit-tests swallows the click aimed past it.
private final class SidebarGlassBacking: NSGlassEffectView {
    override var acceptsFirstResponder: Bool { false }

    override var canBecomeKeyView: Bool { false }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// The glass filling the titlebar band beside the column, so the band is one
/// panel with the column rather than a second plane stepping against it.
///
/// **The same view `WorkspaceWindowController` used to own, moved here on
/// 2026-08-12 and for one reason: the container.**
/// `NSGlassEffectContainerView` merges the glass views that are its own
/// subviews, so the band's plane and the column's have to share a hierarchy, and
/// `Diagnostics/titlebar-merge`'s arm 2 establishes that no container can span
/// the frame-view/`contentView` split the band's plane used to live across.
///
/// **Refusing every click matters more here than it does one class up.** This
/// view lies under the traffic lights, the title, the toolbar and the tab bar —
/// every one of them a control AppKit owns and this app must not intercept. The
/// probe measured all three lights hit-testable over route A's arrangement
/// anyway, because the planes go in `positioned: .below`, and this override is
/// the second guarantee rather than the first: z-order is what makes it work and
/// this is what makes it not depend on z-order.
private final class TitlebarBandGlass: NSGlassEffectView {
    override var acceptsFirstResponder: Bool { false }

    override var canBecomeKeyView: Bool { false }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}

// **The sidebar's glass wash was here, and it retired on 2026-08-08.**
//
// `SidebarGlassWash` laid `theme.background` at `backgroundOpacity` over
// ``SidebarGlassBacking``, so the column dimmed with the wells when the opacity
// slider moved. It was added because that slider had reached nothing in this
// column, and it was right about the defect; it was wrong about the remedy.
// That day the owner A/B'd the naked material against the wash on his own
// desktop, through the `chrome.bareGlass` override built for exactly this
// question, and ruled: naked native glass beats the hand-drawn wash. So the
// column now shows ``SidebarGlassBacking`` untinted with nothing painted over
// it, which is precisely what that flip showed him.
//
// `backgroundOpacity` therefore reaches the sections and nothing else on the
// glass path, deliberately: the material is what the column is, and a knob
// about the terminal's own background does not get to re-tint it. The flat
// path is untouched — the wash only ever existed above a glass view — and its
// rendering is byte-identical by construction.

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
    /// **A list, holding at most one since 2026-08-12.** It stacked a short
    /// glanceable changes list above the long browsable tree until the owner's
    /// ruling that day removed the CHANGES section, the capsule's changes card
    /// having already listed the same files. The list shape stays because the
    /// stacking arithmetic is what makes a column of sections a column rather
    /// than a special case: with one section the layout below hands it the whole
    /// height, and with none the column closes.
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
    /// the column can be switched off, and a closed column has no expansions to
    /// report rather than none to remember.
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
            // The same guard ``resolvedChrome`` below carries. Written
            // unconditionally by `AppDelegate.settingsDidChange()` on every
            // announcement, and this didSet fans out to every section, both
            // headings, the header, the action row and the divider layer, so an
            // unmoved theme was doing all of that for nothing once per
            // settings-file save — and would do it once per control event under
            // the design panel.
            guard theme != oldValue else { return }
            for section in sections {
                section.surface.theme = theme
                section.heading.theme = theme
            }
            actionRow.theme = theme
            divider.layer?.backgroundColor = nsColor(theme.hairline).cgColor
        }
    }

    // The session header row stood here until 2026-08-12. It named the anchor
    // and the branch at the top of the column, which the window title, the
    // shell prompt and the capsule each already said, so the owner's ruling
    // that day made the capsule the one home for repo facts and removed it.
    // Nothing took its place: the FILES heading is the column's top row now.

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
    /// between the footer and the sidebar". Design v5 §5 replaced that connector
    /// with the session header's own row, and the owner's 2026-08-12 ruling
    /// removed that row in turn, so this feeds no heading at all; the property
    /// stays because ``SettingsPreviewColumn`` still themes
    /// `SurfaceTitleView.anchorName` directly, and removing the value this host
    /// used to compute for it would be a change to that preview dressed up as a
    /// rename.
    ///
    /// Assigning it did call `refreshHeadings()` until 2026-08-12, which read
    /// nothing this value fed. That call went with the CHANGES section (owner's
    /// ruling that day) and with the two heading properties the section was the
    /// only surface ever to answer.
    var anchorName: String?

    /// Whether the window is key, which the anchor name's accent is gated on.
    private var isWindowActive = true {
        didSet {
            guard isWindowActive != oldValue else { return }
            for section in sections { section.heading.isWindowActive = isWindowActive }
        }
    }

    // `refreshHeadings()` stood here until 2026-08-12. It pushed
    // `headingCount` and `headingTotals` from each surface into the heading
    // above it, and CHANGES was the only surface that ever answered either with
    // a number: FILES answered nil to both by design. The owner's ruling that
    // day removed the section, so the function had two nils to copy and was
    // removed with it. A heading now draws its label and nothing else.

    /// What the sections fill their bodies at, so the column is the same material
    /// as the panes it sits beside. Design v3 §1.
    ///
    /// Held here rather than read by each surface, because it is a property of the
    /// window's material and not of a list of files, and because the two sections
    /// disagreeing about it is exactly the seam a design pass would then be asked
    /// to explain.
    var backgroundOpacity: Double = 1 {
        didSet {
            // Guarded like its two neighbours, and like
            // `WorkspaceWindowController.backgroundOpacity`, which is the same
            // key one surface over and has always had it.
            guard backgroundOpacity != oldValue else { return }
            // The sections and nothing else. Under glass they draw no fill, so
            // this key reaches no sidebar pixel at all on that path — which is
            // the settled answer rather than an oversight. The wash that used to
            // carry it here retired on the owner's 2026-08-08 ruling; see the
            // note where `SidebarGlassWash` stood, at the top of this file.
            for section in sections { section.surface.backgroundOpacity = backgroundOpacity }
        }
    }

    /// What each section is told to resolve its own chrome against, and what
    /// ``glassBacking`` is built or torn down to match.
    ///
    /// **This host now has real glass of its own (this task).** Task 2 found
    /// the sidebar had never had one — its "glass" was each surface swapping its
    /// scroll view's flat background colour for ``MaterialSet/fillSidebar``, an
    /// `rgba` fill with no `NSGlassEffectView` underneath it to reveal, and Task
    /// 2 dropped that fill along with the footer's tint. The glass-backdrop
    /// spike's sidebar arm (its README's finding 6) measured that an untinted
    /// `regular` glass column, positioned where the sidebar actually sits over
    /// the transparent window region, carries the file rows and (once repaired
    /// through ``PaneChrome/PaneTheme/sectionHeaderInk(on:)`` — see
    /// ``SurfaceTitleView/labelInk``) the heading above them both, and its
    /// verdict rejects the `NSSplitViewController` restructure this could have
    /// reached for instead.
    ///
    /// Pushed straight through to every ``Section/surface`` exactly as before,
    /// the same shape as ``theme`` and ``backgroundOpacity`` immediately above:
    /// the surfaces still decide their own fill (now: none at all under glass,
    /// so nothing opaque sits between this glass and what it samples — see
    /// ``FilesSurface/fill()``), this host only carries the resolution down and
    /// now also owns the glass itself.
    var resolvedChrome: ResolvedChrome = .flat {
        didSet {
            guard resolvedChrome != oldValue else { return }
            for section in sections { section.surface.resolvedChrome = resolvedChrome }
            for section in sections { section.heading.resolvedChrome = resolvedChrome }
            actionRow.resolvedChrome = resolvedChrome
            applyResolvedChrome()
        }
    }

    /// The glass material behind the sidebar's own column, or nil under flat,
    /// and since 2026-08-08 the whole of what the column's glass path draws.
    ///
    /// Created and torn down by ``applyResolvedChrome()``, not merely hidden —
    /// the same "absence is part of byte-identical" rule
    /// `TerminalPaneController.applyResolvedGlassPlane()` holds for the pane
    /// plane, and for the same reason: a hidden `NSGlassEffectView` still
    /// costs a compositing pass macOS runs whether or not it draws anything,
    /// and flat must not pay it.
    ///
    /// Inside ``glassContainer`` since 2026-08-12 rather than a direct subview
    /// of `view`, which is what lets it merge with ``bandGlass``. The container
    /// is what goes in below `tree.view` and every section, so this still sits
    /// behind the whole hierarchy in z-order — `NSGlassEffectView.style =
    /// .regular` samples what the window server has already composited beneath
    /// it, which for a transparent window is the desktop, not this app's own
    /// views, so being behind them in z-order is what "sampling the desktop"
    /// actually requires; a glass view stacked *above* the sections would
    /// sample the sections instead and read as an opaque tint over them.
    ///
    /// **It spans the band as well as the column**, which is the merge. Its
    /// frame takes the host's whole height while everything the column *draws*
    /// stays below the band; see ``viewDidLayout()``.
    private var glassBacking: SidebarGlassBacking?

    /// The band's glass, to the right of the column, merged with
    /// ``glassBacking`` through ``glassContainer``.
    ///
    /// **Two shapes rather than one, and the probe chose that.** An
    /// `NSGlassEffectView` is a rectangle and band-plus-column is an L, so one
    /// view can only cover both by taking the column's full height and leaving
    /// the rest of the band to a second plane regardless. `titlebar-merge`'s
    /// verdict prefers arm 2's container over arm 3's single plane for the
    /// reason that survives here: the container merges shapes of *different
    /// widths* (the band spans the window, the column is 260 pt) with no
    /// untested boundary at the column's right edge.
    private var bandGlass: TitlebarBandGlass?

    /// What merges the two planes into one panel.
    ///
    /// `spacing = 0`, which `glass-backdrop`'s finding 5 measured on the capsule
    /// and `titlebar-merge`'s finding 4 re-measured on these two much larger
    /// shapes: adjacent glass stays distinct in shape while sharing one sampling
    /// pass, and the shared pass is the whole point. A non-zero spacing would
    /// dissolve the band and the column into one blob.
    ///
    /// The boundary between them measured **0.00** under this arrangement,
    /// against **34.33** for the two planes this replaced.
    private var glassContainer: NSGlassEffectContainerView?

    /// Which fill role the *band's* plane is tinted with, written by
    /// ``WorkspaceWindowController`` and kept separate from ``fillMaterial``
    /// one property up.
    ///
    /// **One host holds both planes; the two design-panel surfaces stay two.**
    /// `chrome.surfaces.titlebar` and `chrome.surfaces.sidebar` point at
    /// different roles, and an owner tinting one to check it must not repaint
    /// the other. Nil unless the panel has pointed the titlebar somewhere, and
    /// in Release it can hold nothing else. See ``SurfaceFill``.
    var titlebarFillMaterial: DesignOverrides.Chrome.Material? {
        didSet {
            guard titlebarFillMaterial != oldValue else { return }
            updateGlassTint()
        }
    }

    /// How much height the window is spending on its titlebar band, or `0` when
    /// this host is not in a window yet.
    ///
    /// **The single number this host's split turns on.** The band's plane fills
    /// it at the top of ``view``, the column's plane runs the full height up
    /// through it, and everything the pane tree lays out is held below it. Read
    /// from the window every layout pass rather than cached, because it is not a
    /// constant: it changes when a tab bar joins or leaves, and
    /// ``WorkspaceWindowController`` asks for a fresh pass on resize for exactly
    /// that.
    ///
    /// Zero before the view is in a window, which is the correct answer rather
    /// than a fallback: with no window there is no band, and a layout pass that
    /// runs then lays out exactly as the pre-`fullSizeContentView` arrangement
    /// did. The first pass inside a window recomputes.
    private var bandHeight: Double {
        guard let window = view.window else { return 0 }
        return window.frame.height - window.contentLayoutRect.height
    }

    /// Which of the four fill roles this column's glass is tinted with, or nil
    /// for the untinted glass that ships.
    ///
    /// Nil unless the debug design panel has pointed this surface somewhere, and
    /// in Release it can hold nothing else. See ``SurfaceFill`` for the dormancy
    /// this re-activates — the sidebar's is the oldest of the five, since its
    /// `fillSidebar` was an `rgba` swap standing in for glass that did not exist
    /// yet, and the column has had real glass under it since.
    var fillMaterial: DesignOverrides.Chrome.Material? {
        didSet {
            guard fillMaterial != oldValue else { return }
            updateGlassTint()
        }
    }

    /// Writes ``fillMaterial``'s colour onto ``glassBacking``, or nil.
    ///
    /// **This host's tint was a write-once static until the design panel needed
    /// one.** The old spelling said, correctly, that nothing on this path ever
    /// has a reason to set a tint — unlike the bar's capsule, no element behind
    /// this glass is ever accented — and left `nil` explicit so a later change
    /// setting one would at least be a diff against a line saying why it must
    /// not. The panel is that change, made deliberately and reversibly: with it
    /// silent this resolves nil and the backing is exactly as untinted as it was.
    ///
    /// A method rather than the creation-time assignment it replaces, because
    /// ``applyResolvedChrome()`` returns early when the backing already exists,
    /// so a tint dialled while the column is open would otherwise never land.
    private func updateGlassTint() {
        guard case let .glass(set) = resolvedChrome else { return }
        glassBacking?.tintColor = SurfaceFill.colour(fillMaterial, in: set)
        // The band's own role, not the column's. See ``titlebarFillMaterial``
        // for why merging the planes did not merge the two overrides.
        bandGlass?.tintColor = SurfaceFill.colour(titlebarFillMaterial, in: set)
    }

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
    /// Starts at a value rather than at a share of the column, from when two
    /// asymmetrical surfaces stacked here: a changes list was a handful of rows
    /// against a whole repository, so an even split left half the column holding
    /// three lines. Unreachable while the column holds one section (the 2026-08-12
    /// ruling), and kept with the split machinery around it, which the session file
    /// still carries and a second section would need again.
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

        actionRow.theme = theme
        actionRow.resolvedChrome = resolvedChrome
        view.addSubview(actionRow)

        install()
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
        // `glassContainer`, and every newly installed section view is added
        // above it in z-order by the two `addSubview` calls just above — no
        // restack needed here for the glass to keep reading as what is behind
        // the column rather than as a layer painted over it. The container is
        // the one subview of `view` that holds glass now, so raising a section
        // above it raises it above both planes at once.
    }

    /// Creates or tears down ``glassBacking`` to match ``resolvedChrome``.
    ///
    /// The same shape `TerminalPaneController.applyResolvedGlassPlane()` takes
    /// for the pane: flat removes the view entirely rather than hiding it, and
    /// glass creates one only if none exists yet, so a chrome change that
    /// toggles glass-flat-glass does not tear down and rebuild a view that did
    /// not need to move.
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
            // The container goes with the planes rather than staying as an empty
            // host, for the reason `glassBacking` gives about hiding: flat must
            // not pay a compositing pass macOS runs whether or not anything in it
            // draws. An `NSGlassEffectContainerView` with no glass in it is
            // exactly that pass with nothing to show for it.
            glassContainer?.removeFromSuperview()
            glassContainer = nil
            glassBacking = nil
            bandGlass = nil
        case .glass:
            guard glassContainer == nil else { break }

            let backing = SidebarGlassBacking(frame: .zero)
            backing.style = .regular
            backing.cornerRadius = 0
            backing.wantsLayer = true

            let band = TitlebarBandGlass(frame: .zero)
            band.style = .regular
            band.cornerRadius = 0
            band.wantsLayer = true

            // **The merge, and it is the only arrangement that produces one.**
            // The container merges the glass views that are its own subviews, so
            // the two planes share a host view inside it; `spacing = 0` keeps
            // them distinct in shape while they share one sampling pass. See
            // ``glassContainer``.
            let container = NSGlassEffectContainerView(frame: view.bounds)
            container.spacing = 0
            let host = NSView(frame: view.bounds)
            host.addSubview(backing)
            host.addSubview(band)
            container.contentView = host

            // Below `tree.view` and every section, exactly where the column's
            // lone backing used to go and for the reason `glassBacking`'s doc
            // comment gives: glass that is not at the back samples this app's
            // own views instead of what is behind the window. It is also what
            // keeps the traffic lights clickable, since the band's plane now
            // passes under all three of them.
            view.addSubview(container, positioned: .below, relativeTo: nil)
            glassContainer = container
            glassBacking = backing
            bandGlass = band

            updateGlassTint()
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
    /// on the sidebar's. The split between two stacked sections had no such half,
    /// with a surface above it on one side and a heading on the other, so all seven
    /// points of it were dead.
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

        // **What used to be one `bounds` is two rects, and every consumer below
        // names which one it takes.** The window carries `.fullSizeContentView`
        // (see ``WorkspaceWindowController``'s style mask), so `view.bounds` now
        // reaches the window's top edge and includes the titlebar band. That is
        // what lets the column's glass run up under the band and merge with it;
        // it is also what would push every pane up by the band's height if it
        // were handed to the pane tree, resizing every ghostty grid.
        //
        // `Diagnostics/titlebar-merge`'s arm 5 is this split measured on a
        // stand-in, and `gridtest` is it measured on a real libghostty surface:
        // hold the tree's rect at the row it had and the grid stays 73 x 19 with
        // zero resize callbacks across the flip.
        //
        // - `bounds` (full, band included): the column's glass, which is the
        //   whole reason for the split, and the band's glass above it.
        // - `content` (band excluded): everything else. The action row, the
        //   sections, both dividers and the pane tree all lay out inside it and
        //   therefore sit exactly where they sat before the style-mask change.
        //   The column's *content* stays below the band even though its *glass*
        //   does not, which is the same line arm 5 draws and for the same reason:
        //   FILES drawn up into the band collides with the window title.
        let bounds = view.bounds
        let content = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: max(0, bounds.height - bandHeight)
        )
        let sidebarWidth = sections.isEmpty
            ? 0
            : min(width, max(0, content.width - Self.minimumPaneWidth))

        // Read from the width that was actually used, not from the sidebar's
        // existence. A window too narrow to give the sidebar any width leaves the
        // tree touching the left edge, and a tree told otherwise would keep its
        // leftmost footers square against a corner the window really does have.
        tree.edgesCoveredByHost = sidebarWidth > 0 ? [.left] : []
        divider.isHidden = sidebarWidth == 0

        // The glass column, sized to exactly the sidebar's own width and
        // nothing else horizontally. `bounds` spans the whole host — sidebar
        // column plus the pane tree beside it — and a glass view sized to all of
        // it would sample and composite pixels behind the panes too, which have
        // their own material (each pane's `backgroundOpacity` well) and need no
        // second glass layer over them.
        //
        // **Vertically it takes the whole of `bounds` rather than `content`,
        // and that is the merge.** It runs from the host's bottom edge to the
        // window's top edge, through the band, so the column and the band are
        // one continuous shape down the strip the probe measures. The column's
        // *content* is still laid out in `content` below.
        //
        // `isHidden` rather than a zero frame at width 0: a `CGRect` of zero
        // size is still a valid frame to hand `NSGlassEffectView`, and hiding is
        // the explicit statement that there is no sidebar to back right now,
        // matching `divider.isHidden` and `widthDivider.isHidden` around it.
        if let glassBacking {
            glassBacking.isHidden = sidebarWidth == 0
            glassBacking.frame = NSRect(
                x: bounds.minX,
                y: bounds.minY,
                width: sidebarWidth,
                height: bounds.height
            )
        }

        // **The band, and with the sidebar closed it is the whole band.** With a
        // column open this fills the band to the right of it, meeting the
        // column's plane at the column's right edge, which is where the
        // container's shared sampling pass makes the two read as one panel.
        //
        // With `sidebarWidth == 0` there is no column to merge with and the
        // question "what draws the band" has to be answered rather than left to
        // an empty region: this plane takes the window's full width, which is
        // the frame the retired `TitlebarGlassBacking` held in the frame view.
        // A closed sidebar therefore renders exactly the band the app shipped
        // before the merge, with one plane in it and nothing to seam against.
        //
        // Never hidden, unlike the column's. The band exists whether or not the
        // sidebar does, and a window whose titlebar loses its glass when the
        // column closes would show the bare wallpaper
        // ``WorkspaceWindowController/applyTitlebarGlass()`` sets
        // `titlebarAppearsTransparent` to reveal.
        if let bandGlass {
            bandGlass.frame = NSRect(
                x: bounds.minX + sidebarWidth,
                y: content.maxY,
                width: max(0, bounds.width - sidebarWidth),
                height: bandHeight
            )
        }

        // The container is only a coordinate space for the two planes and never
        // draws on its own, so it takes the full `bounds` and lets them place
        // themselves inside it.
        glassContainer?.frame = bounds

        // The bottom action row is chrome around the sections rather than a
        // section itself: fixed height, drawn even when the sidebar has nothing
        // in it. Hidden with the column, the same rule the width divider
        // follows, since a closed sidebar has no room for it.
        //
        // **The session header was the other half of this until 2026-08-12**,
        // a 28 pt strip at the column's top with the sections starting below it.
        // The owner's ruling removed it, and the space closes by subtraction:
        // the column the sections are laid out in now starts at `content.maxY`
        // and `layoutSections` puts the first heading at its top edge, so the
        // FILES heading is the column's top row with nothing above it. That top
        // edge is `content`'s rather than `bounds`'s since the merge, which is
        // what keeps the heading out of the titlebar band.
        // The action row sits at the column's bottom, which `content` and
        // `bounds` share, so the rect it takes is only visibly a choice at the
        // top. It takes `content` anyway, because "the column's chrome lays out
        // in `content`" is the rule and a consumer exempted for sharing an edge
        // is a consumer that breaks silently if the other edge ever moves.
        let hasSidebar = sidebarWidth > 0
        actionRow.isHidden = !hasSidebar
        actionRow.frame = NSRect(
            x: content.minX,
            y: content.minY,
            width: sidebarWidth,
            height: Self.actionRowHeight
        )

        // The sections, and this is where holding the band back is visible: the
        // first heading lands at `content.maxY`, which is the row it landed on
        // before the style-mask change, rather than up in the band beside the
        // window title.
        layoutSections(in: NSRect(
            x: content.minX,
            y: content.minY + (hasSidebar ? Self.actionRowHeight : 0),
            width: sidebarWidth,
            height: max(0, content.height - (hasSidebar ? Self.actionRowHeight : 0))
        ))

        let gutter = sidebarWidth > 0 ? Self.dividerWidth : 0
        // Centred on the hairline rather than beside it, so the pointer finds the
        // edge it can see. Hidden with the sidebar: there is no edge to drag when
        // the column is closed, and an invisible grab strip over the leftmost pane
        // would swallow clicks meant for the terminal.
        //
        // **`content`, so the strip stops below the band.** A grab strip run up
        // through the band would put a resize cursor and a drag over the region
        // AppKit uses to move the window, which is the one interaction the merge
        // must not cost.
        widthDivider.isHidden = sidebarWidth == 0
        widthDivider.frame = NSRect(
            x: content.minX + sidebarWidth - Self.grabHeight / 2,
            y: content.minY,
            width: Self.grabHeight,
            height: content.height
        )
        // The hairline stops below the band for the visible half of the same
        // reason: drawn through it, it would cut a 1 pt line across the merged
        // panel at exactly the boundary the merge exists to remove.
        divider.frame = NSRect(
            x: content.minX + sidebarWidth,
            y: content.minY,
            width: gutter,
            height: content.height
        )
        // **The rect this whole split exists to hold.** Identical to what it
        // computed before `.fullSizeContentView`, because `content` is `bounds`
        // minus the band and `bounds` grew by exactly the band. Arm 5 measures
        // the equality (`dx=dy=dw=dh=dtop=0`) and `gridtest` measures that it is
        // an unmoved grid rather than only an unmoved rectangle.
        tree.view.frame = NSRect(
            x: content.minX + sidebarWidth + gutter,
            y: content.minY,
            width: max(0, content.width - sidebarWidth - gutter),
            height: content.height
        )
    }

    /// Stacks the sections from the top down.
    ///
    /// Every section but the last is capped rather than given an equal share, and
    /// the last takes whatever is left. That rule is why the tree goes last, and
    /// since the 2026-08-12 ruling left it alone in the column it is also why the
    /// space the CHANGES section vacated closed on its own: one section is the
    /// last section, so the tree is handed the whole height below the heading with
    /// no arithmetic here changing at all.
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

    /// Named locally rather than read off ``SidebarActionRowView/height`` at
    /// every call site above, which is what every other geometry constant in
    /// this file already does for its own view. `sessionHeaderHeight` stood
    /// beside it until the 2026-08-12 ruling took the row it measured.
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
