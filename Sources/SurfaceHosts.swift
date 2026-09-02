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
// `backgroundOpacity` therefore reaches the surface and nothing else on the
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

    /// The column's one surface, or none.
    ///
    /// **A single optional since Task 6, and a list holding at most one since
    /// 2026-08-12 before that.** It stacked a short glanceable changes list above
    /// the long browsable tree until the owner's ruling that day removed the
    /// CHANGES section, the capsule's changes card having already listed the same
    /// files, which left the list shape carrying an invariant — at most one — that
    /// nothing in the type enforced. `SidebarContent` names exactly two states,
    /// `.files` and `.off`, and `FilesSurface` is the column's only surface, so
    /// the protocol this held against and the fan-out it needed both went with the
    /// second section: what a column shows now is `Optional<FilesSurface>`, not a
    /// list some caller happens to keep at length one.
    private(set) var files: FilesSurface?

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
    /// column's surface is the host's business. Nothing outside gets to go
    /// hunting through it for a surface to cast.
    var fileTreeExpansions: [String: [String]] {
        get { files?.fileTreeExpansions ?? [:] }
        set { files?.fileTreeExpansions = newValue }
    }

    var theme: PaneTheme {
        didSet {
            // The same guard ``resolvedChrome`` below carries. Written
            // unconditionally by `AppDelegate.settingsDidChange()` on every
            // announcement, and this didSet fans out to the surface and the
            // divider layer, so an unmoved theme was doing all of that for
            // nothing once per settings-file save — and would do it once per
            // control event under the design panel. The header, the action row
            // and the headings were the other fan-out targets until 2026-08-12.
            guard theme != oldValue else { return }
            files?.theme = theme
            divider.layer?.backgroundColor = nsColor(theme.hairline).cgColor
        }
    }

    // The session header row stood here until 2026-08-12. It named the anchor
    // and the branch at the top of the column, which the window title, the
    // shell prompt and the capsule each already said, so the owner's ruling
    // that day made the capsule the one home for repo facts and removed it.
    // Nothing took its place: the FILES heading is the column's top row now.

    // The bottom action row stood here too, until the same day. It drew "New
    // session" and a `⌘T` keycap and its click called
    // `openWindow(tree:joining:)` on the clicked window, which is what
    // `AppDelegate.newTab(_:)` does under the `New Tab` item the keycap was
    // reading its own caption off. A row that has to look up the menu's binding
    // to caption itself is a second button for the menu's command, so the owner
    // ruled it out and the tree took its 32 pt. `onNewSession` and
    // `newSessionKeycap` were this host's two passthroughs to it and went with
    // it; `AppDelegate` keeps `newTab(_:)`, which is the surviving path.

    /// The repository the column is describing.
    ///
    /// **Written by `AppDelegate.refreshSidebar(of:)` and read by nothing in this
    /// host, which is the settled state rather than a loose end.** Design v3 §4.2
    /// had the first heading draw it trailing, "the connector between the footer
    /// and the sidebar"; design v5 §5 replaced that connector with the session
    /// header's own row; the owner's 2026-08-12 rulings removed that row and then
    /// the heading itself (option C). The property stays because
    /// ``SettingsPreviewColumn`` still sets `SurfaceTitleView.anchorName`
    /// directly to show how a heading is themed, and the delegate keeps one place
    /// that knows the focused pane's anchor name.
    ///
    /// Assigning it did call `refreshHeadings()` until 2026-08-12, which read
    /// nothing this value fed. That call went with the CHANGES section (owner's
    /// ruling that day) and with the two heading properties the section was the
    /// only surface ever to answer.
    var anchorName: String?

    // `isWindowActive` stood here until the FILES ruling (2026-08-12, option C).
    // It gated the anchor name's accent on the window being key, watched through
    // the two notification observers `viewDidAppear` still installs, and the one
    // thing it ever reached was `section.heading.isWindowActive`. With no heading
    // in this column there is no accent to gate, so the property went and the
    // observers now keep only the key state ``SurfaceTitleView`` reads when
    // `SettingsPreviewColumn` drives one.

    // `refreshHeadings()` stood here until 2026-08-12. It pushed
    // `headingCount` and `headingTotals` from each surface into the heading
    // above it, and CHANGES was the only surface that ever answered either with
    // a number: FILES answered nil to both by design. The owner's ruling that
    // day removed the section, so the function had two nils to copy and was
    // removed with it. The heading itself followed later the same day.

    /// What the column's surface fills its body at, so the column is the same
    /// material as the panes it sits beside. Design v3 §1.
    ///
    /// Held here rather than read by the surface itself, because it is a
    /// property of the window's material and not of a list of files.
    var backgroundOpacity: Double = 1 {
        didSet {
            // Guarded like its two neighbours, and like
            // `WorkspaceWindowController.backgroundOpacity`, which is the same
            // key one surface over and has always had it.
            guard backgroundOpacity != oldValue else { return }
            // The surface and nothing else. Under glass it draws no fill, so
            // this key reaches no sidebar pixel at all on that path — which is
            // the settled answer rather than an oversight. The wash that used to
            // carry it here retired on the owner's 2026-08-08 ruling; see the
            // note where `SidebarGlassWash` stood, at the top of this file.
            files?.backgroundOpacity = backgroundOpacity
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
    /// Pushed straight through to ``files`` exactly as before, the same shape as
    /// ``theme`` and ``backgroundOpacity`` immediately above: the surface still
    /// decides its own fill (now: none at all under glass, so nothing opaque
    /// sits between this glass and what it samples — see
    /// ``FilesSurface/fill()``), this host only carries the resolution down and
    /// now also owns the glass itself.
    var resolvedChrome: ResolvedChrome = .flat {
        didSet {
            guard resolvedChrome != oldValue else { return }
            files?.resolvedChrome = resolvedChrome
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
    /// is what goes in below `tree.view` and the surface, so this still sits
    /// behind the whole hierarchy in z-order — `NSGlassEffectView.style =
    /// .regular` samples what the window server has already composited beneath
    /// it, which for a transparent window is the desktop, not this app's own
    /// views, so being behind them in z-order is what "sampling the desktop"
    /// actually requires; a glass view stacked *above* the surface would
    /// sample the surface instead and read as an opaque tint over it.
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
    /// the rest of the band to a second plane regardless.
    ///
    /// **It spans the window's full width and OVERLAPS the column's plane, and
    /// this comment claimed the opposite until 2026-08-12.** The line it used to
    /// carry — that the container merges shapes of different widths "with no
    /// untested boundary at the column's right edge" — described an edge that was
    /// both untested and visible. `titlebar-merge`'s arm 7 is that edge measured:
    /// the two planes sample identically (0.00 as a step) and the shipped app
    /// still drew a rim 40 to 54 luminance units bright down the join, through the
    /// band's whole height, tracking `sidebarWidth` when the column was dragged.
    ///
    /// `NSGlassEffectContainerView` merges the sampling pass, not the shapes. Two
    /// planes that abut have two borders meeting and the container cannot dissolve
    /// them, so the fix is to remove the abutment: this plane takes the full width
    /// and sits over the column's in the band region rather than beside it. See
    /// ``viewDidLayout()``, where the frame is written and the reasoning kept.
    private var bandGlass: TitlebarBandGlass?

    /// What merges the two planes into one panel.
    ///
    /// `spacing = 0`, which `glass-backdrop`'s finding 5 measured on the capsule
    /// and `titlebar-merge`'s finding 4 re-measured on these two much larger
    /// shapes: adjacent glass stays distinct in shape while sharing one sampling
    /// pass, and the shared pass is the whole point. A non-zero spacing would
    /// dissolve the band and the column into one blob.
    ///
    /// The *horizontal* boundary between them measured **0.00** under this
    /// arrangement, against **34.33** for the two planes this replaced.
    ///
    /// **What the shared pass does not do is dissolve a shared edge**, and arm 7
    /// is where that was measured rather than assumed. `spacing = 0` keeps
    /// adjacent shapes distinct by design — that is the property this merge relies
    /// on — so two planes that abut still draw two borders at the join however
    /// well they sample together. The band plane therefore overlaps the column's
    /// rather than abutting it; see ``bandGlass``.
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
            // **And down into the surface, since 2026-08-12.** `FilesSurface`
            // used to own no glass, so this key stopped at the column's own
            // plane. The owner's tinted-glass ruling gave its floating `git
            // init` pill a real `NSGlassEffectView`, and ruled that it follows
            // the sidebar's tint rather than taking a key of its own — so the
            // same value reaches both, from one property, and the pill cannot
            // disagree with the plane it floats over.
            files?.fillMaterial = fillMaterial
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

    /// How tall the first section was when two were stacked.
    ///
    /// Started at a value rather than at a share of the column, from when two
    /// asymmetrical surfaces stacked here: a changes list was a handful of rows
    /// against a whole repository, so an even split left half the column holding
    /// three lines. Dead since the 2026-08-12 ruling left one section in the
    /// column and dead again, structurally, since Task 6 made the column's
    /// surface a plain `FilesSurface?` rather than a list a second entry could
    /// ever join. Kept only because ``geometry`` round-trips it through the
    /// session file's `splitHeight` key, which predates both rulings; nothing
    /// reads it for layout any more, and no drag writes it.
    private(set) var firstSectionHeight: Double = SidebarGeometry.default.splitHeight

    init(
        tree: PaneTreeController,
        surfaces: FilesSurface?,
        theme: PaneTheme,
        backgroundOpacity: Double,
        resolvedChrome: ResolvedChrome
    ) {
        self.tree = tree
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        self.resolvedChrome = resolvedChrome
        super.init(nibName: nil, bundle: nil)
        files = surfaces
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Replaces what the column is showing. `nil` closes it.
    ///
    /// Closing is a width of zero rather than a host that goes away. A host that came
    /// and went would have to swap the window's `contentViewController`, and that
    /// reparents every ghostty surface, which resizes every grid and signals every
    /// process. At zero width nothing is reparented and the cost is the ordinary
    /// reflow a width change already carries, which was measured clean.
    func show(_ surfaces: FilesSurface?) {
        files?.view.removeFromSuperview()
        files = surfaces
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

        widthDivider.wantsLayer = true
        view.addSubview(widthDivider)

        install()
    }

    // `viewDidAppear` and `viewWillDisappear` stood here until the FILES ruling
    // (2026-08-12, option C), holding two `NSWindow` key-state observers and the
    // teardown that matched them. They existed for one line: pushing the window's
    // key state into each heading, which gated the anchor name's accent so a
    // window that is not key would not compete with the one that is. The heading
    // went, the accent went with it, and an observer with no reader is a
    // subscription this column pays for on every key change and spends on
    // nothing. The pane tree still watches the same notifications for the
    // footers, which is where that argument was always load-bearing.

    private func install() {
        if let files {
            files.theme = theme
            files.backgroundOpacity = backgroundOpacity
            files.resolvedChrome = resolvedChrome
            // Alongside the three above rather than only in the `didSet`, for the
            // reason each of them is here: `show(_:)` installs a surface that was
            // constructed at its own defaults, and missing this would carry an
            // untinted pill under a dialled column until the next time the dial
            // moved.
            files.fillMaterial = fillMaterial
            view.addSubview(files.view)
        }
        raiseGrabStrips()
        // `show(_:)` calls `install()` after `viewDidLoad` has already built
        // `glassContainer`, and a newly installed surface view is added above it
        // in z-order by the `addSubview` call just above — no restack needed
        // here for the glass to keep reading as what is behind the column
        // rather than as a layer painted over it. The container is the one
        // subview of `view` that holds glass now, so raising the surface above
        // it raises it above both planes at once.
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
            // **The column first, the band second, and the order is load-bearing
            // since the band went full width.** The band's plane now overlaps the
            // column's in the band region rather than abutting it, which is what
            // removes the visible join; an overlap only reads as the band's
            // material if the band's plane is the one on top. Added second is
            // added above.
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

    /// **The strip goes back on top every time the surface is installed.**
    ///
    /// `viewDidLoad` adds it before the surface exists, so every `install()`
    /// buried it under the scroll view. Cursor rects do not consult the view
    /// order and hit testing does, which is the whole signature this was found
    /// by: the pointer turned into a resize arrow over a strip that could not
    /// be clicked.
    ///
    /// The sidebar's own edge hid it by half. Its right half lies over `tree.view`,
    /// which is added before it and stays below, so dragging the column worked as
    /// long as the grab started on the pane's side of the hairline and did nothing
    /// on the sidebar's.
    private func raiseGrabStrips() {
        view.addSubview(widthDivider, positioned: .above, relativeTo: nil)
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
        // - `content` (band excluded): everything else. The surface, both
        //   dividers and the pane tree all lay out inside it and
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
        let sidebarWidth = files == nil
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

        // **The band, and it takes the window's FULL WIDTH whether or not there
        // is a column under it.**
        //
        // It started at `bounds.minX + sidebarWidth`, so that the band's plane
        // began exactly where the column's ended and the two abutted down a
        // vertical line through the band. That arrangement is what the merge
        // commit shipped, on the reasoning that the container's shared sampling
        // pass would make the two read as one panel. **The sampling did merge and
        // the join was still visible**, which is the correction this line carries.
        //
        // `Diagnostics/titlebar-merge`'s arm 7 is the measurement. Read as a step
        // between the mean luminance either side, the join is 0.00: the two planes
        // genuinely sample alike, so the container did its job. Read as a *rim* —
        // the brightest sample at the join against the shoulders either side — the
        // shipped app draws a line **40 to 54 luminance units** above its
        // surroundings, through the band's whole height, ending exactly where the
        // band does. Dragging the column moves that line with it, from x = 236 to
        // x = 336 for a 100 pt drag, which is what identifies it as this join
        // rather than as ``divider`` (which stops below the band) or as anything
        // in ``WorkspaceWindowController``.
        //
        // **`NSGlassEffectContainerView` merges the SAMPLING, not the SHAPES.**
        // Each `NSGlassEffectView` draws a refractive edge treatment wherever it
        // terminates, and two shapes that abut have two such edges meeting. The
        // container has no way to dissolve them, and no `spacing` value can: at
        // `spacing = 0` the shapes stay distinct by design, which is the property
        // finding 4 measured and relied on. So the fix cannot be a better merge.
        // It has to remove the abutment.
        //
        // Full width does exactly that. In the band region this plane now sits
        // *over* the column's rather than beside it, so there is no interior edge
        // in the band at all — an overlap has no border where two rectangles meet
        // because they do not meet. The column's plane still runs the host's full
        // height underneath, so the column below the band is one continuous shape
        // and the horizontal boundary the merge was commissioned to remove stays
        // removed: arms 2 and 5 still measure 0.00 down the strip.
        //
        // The two planes are still both needed and still both in the container.
        // The column's is what backs the sidebar below the band, where this one
        // does not reach; this one is what backs the band across its whole width.
        // Their sampling is shared, which is why the overlap reads as one material
        // rather than as two thicknesses of glass stacked.
        //
        // Never hidden, unlike the column's. The band exists whether or not the
        // sidebar does, and a window whose titlebar loses its glass when the
        // column closes would show the bare wallpaper
        // ``WorkspaceWindowController/applyTitlebarGlass()`` sets
        // `titlebarAppearsTransparent` to reveal. With `sidebarWidth == 0` this
        // frame is unchanged from what it always was, so a closed sidebar renders
        // exactly the band it did before.
        if let bandGlass {
            bandGlass.frame = NSRect(
                x: bounds.minX,
                y: content.maxY,
                width: bounds.width,
                height: bandHeight
            )
        }

        // The container is only a coordinate space for the two planes and never
        // draws on its own, so it takes the full `bounds` and lets them place
        // themselves inside it.
        glassContainer?.frame = bounds

        // The surface, and this is where holding the band back is visible: the
        // tree's first row lands at `content.maxY`, rather than up in the band
        // beside the window title.
        //
        // **The column is `content` and nothing else since 2026-08-12, and now
        // the column is the tree.** Three strips of chrome bracketed it over that
        // day: a 28 pt session header at the top, a 32 pt action row at the
        // bottom, and a 28 pt FILES heading between the header and the rows. The
        // owner's rulings removed all three, and each closed by subtraction
        // rather than by rebalancing a term. `layoutSections` puts the first
        // section flush against the top of what it is given and gives the last
        // whatever is left at the bottom, so with one section the tree takes the
        // whole of `content`. That the top edge is `content`'s rather than
        // `bounds`'s is the merge's doing and what keeps the rows out of the
        // titlebar band; the bottom edge the two rects share, so the tree reaches
        // the window's floor either way.
        layoutSections(in: NSRect(
            x: content.minX,
            y: content.minY,
            width: sidebarWidth,
            height: content.height
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

    /// Sizes the column's one surface to fill it.
    ///
    /// **A single surface takes the whole column, always.** Stacking two
    /// surfaces at a split needed a "last section takes what is left" rule; a
    /// lone `FilesSurface?` needs no rule at all, since there is only ever the
    /// one term. That was already true the moment the 2026-08-12 ruling left one
    /// section in the column — the space the CHANGES section vacated closed on
    /// its own then — and Task 6 is what removed the machinery that used to make
    /// it a special case of a general stack rather than the only case there is.
    ///
    /// **`SurfaceTitleView.height` came out of every term on the FILES ruling
    /// (2026-08-12, option C).** The surface used to be a 28 pt heading with a
    /// body under it, so the body was `column.height - 28`. With no heading the
    /// body *is* the surface: it now runs the full height of `column`, which is
    /// what "no gap and no empty strip above the tree" means arithmetically.
    private func layoutSections(in column: NSRect) {
        guard let files else { return }
        files.view.frame = column
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

    // `sessionHeaderHeight` and `actionRowHeight` stood here until 2026-08-12,
    // the two strips of chrome that bracketed the column. The owner's rulings
    // that day removed both rows, and a height naming a view that is gone is a
    // term the layout would carry forward without a subject.

    // `minimumSectionHeight` stood here until Task 6. It clamped a drag between
    // two stacked surfaces, through `clampedSplit`, which went with the last
    // reader that could ever call it: the strip that dragged the split between
    // them, removed along with the list a second surface would have joined. A
    // single `FilesSurface?` has nothing to clamp between.

    /// How narrow the column may be dragged.
    ///
    /// Below this a path is all ellipsis and the column says nothing, which is worse
    /// than a closed sidebar because it still costs the panes their width.
    private static let minimumWidth: Double = 120

    /// How tall the invisible grab area over the split is. Wider than the hairline
    /// it sits on, because a 1 pt target is one nobody can hit.
    private static let grabHeight: Double = 7
}
