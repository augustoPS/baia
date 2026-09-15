import AppKit
import BaiaSettings
import GitWorkspace
import PaneChrome

/// A borderless panel that is still allowed to take the keyboard.
///
/// `NSPanel` refuses key by default when it has no title bar, and a palette that
/// cannot take key is a palette you cannot type into. `canBecomeMain` stays
/// false so the workspace window remains the main window underneath: main is
/// what the menu bar validates against, and handing it to the palette would grey
/// out every command while it is open.
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { false }
}

/// `NSGlassEffectView`, with the same refusals `PaneGlassPlaneView` makes.
///
/// The palette is a separate panel rather than a view inside a pane, so
/// nothing here guards a ghostty key binding the way the pane's plane
/// does; the refusals still matter because the glass view hit-tests itself by
/// AppKit's default and would otherwise intercept clicks meant for the query
/// field or a row underneath it.
private final class PaletteGlassBacking: NSGlassEffectView {
    override var acceptsFirstResponder: Bool { false }

    override var canBecomeKeyView: Bool { false }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// The ⌘K project palette.
///
/// Owns the panel and the keyboard, and nothing else. Discovery, ranking and the
/// recency store all live in `GitWorkspace` and were built and tested long before
/// this existed; what was missing was only the surface. The palette hands the
/// chosen project back through ``onOpen`` rather than opening it itself, because
/// only the app delegate knows what a tab is.
@MainActor
final class CommandPaletteController: NSObject, NSTextFieldDelegate {
    /// Raised with the chosen project, the action, and the window the palette
    /// was summoned over.
    var onOpen: ((Project, PaletteAction, NSWindow?) -> Void)?

    /// Whether a project can open from the window the palette was summoned
    /// over. Asked before dismissal, for the same reason ``prepareVerb`` is:
    /// summoned from Settings or a system panel there is no workspace to open
    /// into, and a palette that dismissed first would leave the owner with a
    /// beep and no list. False leaves the palette open.
    var canOpenProject: (NSWindow?) -> Bool = { _ in true }

    /// Validates a chosen verb against the workspace captured before this panel
    /// became key and returns the action to run after that workspace regains key.
    /// Nil is an explicit refusal and leaves the palette open.
    var prepareVerb: (Int, NSWindow?) -> (() -> Bool)? = { _, _ in nil }

    /// Every verb available right now, supplied by the app target because
    /// availability is a fact about the app rather than about this panel.
    ///
    /// Re-read on each open rather than held across opens: `Close Tab` is
    /// available with two tabs and not with one, and a list captured when the
    /// palette was built would offer a verb that has since become impossible.
    var availableVerbs: (NSWindow?) -> [PaletteVerb] = { _ in [] }

    var theme: PaneTheme = .darkPastel {
        didSet {
            // The same guard ``resolvedChrome`` directly below carries, and the
            // only one of this class's pushed properties that was missing it.
            // `AppDelegate.settingsDidChange()` writes this unconditionally on
            // every announcement, so without the guard an unmoved theme still
            // ran three `needsDisplay` assignments and an `applyResolvedChrome()`
            // that rewrites the backing layer's colour under glass. That was one
            // wasted repaint per settings-file save; under the design panel it
            // becomes one per control event, since a dial that moves only
            // `backgroundOpacity` still fires the same announcement.
            guard theme != oldValue else { return }
            queryView.theme = theme
            listView.theme = theme
            hintsView.theme = theme
            // Routed through the same switch `applyResolvedChrome()` uses
            // rather than writing `panelBackground` unconditionally: a theme
            // change while glass is active must not restore the opaque fill
            // `applyResolvedChrome()` just cleared, which is exactly what the
            // old unconditional write here did the first time the two crossed.
            applyResolvedChrome()
        }
    }

    /// Flat, unchanged, or glass with the material set the theme's own darkness
    /// picked, pushed from `AppDelegate` the same way it reaches the sidebar
    /// (`configuration.resolvedChrome`, read on presenting and again on every
    /// settings or appearance change).
    ///
    /// Under glass the panel wears the menu material — `ChromeMaterials`'
    /// `fillMenu` role plus an `NSGlassEffectView` backing, design v5 §6's
    /// "same pattern as the footer's" (that view is gone; the pattern is not).
    /// Flat keeps the opaque `panelBackground`
    /// fill this panel has always drawn.
    var resolvedChrome: ResolvedChrome = .flat {
        didSet {
            guard resolvedChrome != oldValue else { return }
            queryView.resolvedChrome = resolvedChrome
            listView.resolvedChrome = resolvedChrome
            hintsView.resolvedChrome = resolvedChrome
            applyResolvedChrome()
        }
    }

    /// Which of the four fill roles this palette's glass is tinted with, or nil
    /// for the untinted glass that ships.
    ///
    /// Nil unless the debug design panel has pointed this surface somewhere, and
    /// in Release it can hold nothing else. See ``SurfaceFill`` for the dormancy
    /// this re-activates.
    var fillMaterial: DesignOverrides.Chrome.Material? {
        didSet {
            guard fillMaterial != oldValue else { return }
            updateGlassMaterial()
        }
    }

    /// Whether this panel's window-level appearance is dark — what AppKit reads
    /// when it renders the `NSGlassEffectView` under the three bands, the focus
    /// ring on the query field, and anything else drawn from
    /// `NSWindow.appearance` rather than from a colour this controller sets.
    ///
    /// **Follows the theme, never the system**, the same rule and the same one
    /// line ``WorkspaceWindowController/isDark`` states at length: chrome
    /// matches the theme, and this panel is chrome. Fed from
    /// `ConfigurationCenter.windowIsDark`, the same derivation the workspace
    /// window's own titlebar and the glass material set below both take, so the
    /// panel cannot render its material for one appearance and its glass for the
    /// other. Before this, the panel inherited `NSApp.effectiveAppearance` and a
    /// dark theme under a light system drew light system chrome around dark
    /// glass.
    ///
    /// Window-scoped rather than `NSApp.appearance` for the reason the workspace
    /// window gives: nothing here has an opinion about the settings window's
    /// live preview or the find panel, and `NSWindow.appearance` is the
    /// platform's own way to scope the override to one window.
    ///
    /// Applied on creation as well as on change, so a panel summoned once and
    /// never re-themed is not the one that renders wrong.
    ///
    /// Defaults `true` rather than `false` to agree with ``theme``'s own
    /// `.darkPastel` default one property up — that theme's background *is*
    /// dark, and a pair of defaults that disagreed would put the panel in the
    /// mismatched state this property exists to remove, for the one instant
    /// before `AppDelegate` writes both. ``WorkspaceWindowController/isDark``
    /// stores `false` instead only because it takes its value as an `init`
    /// parameter and so never renders on the stored one.
    var isDark: Bool = true {
        didSet {
            guard isDark != oldValue else { return }
            applyAppearance()
        }
    }

    private let panel: PalettePanel

    /// Held because it carries the tint and the rounded corners both. The window
    /// behind it stays clear: an `NSWindow` fills its whole frame rect with
    /// `backgroundColor` underneath the content view, so an opaque window colour
    /// refilled the corners `masksToBounds` had just clipped away, in the same
    /// colour, and the panel rendered square with the border curving inward into
    /// a filled wedge. `isOpaque = false` permits transparency, it does not
    /// suppress that fill.
    private let content = NSView(
        frame: NSRect(x: 0, y: 0, width: CommandPaletteController.width, height: 300)
    )
    private let queryView = PaletteQueryView(frame: .zero)
    private let listView = PaletteListView(frame: .zero)
    private let hintsView = PaletteHintsView(frame: .zero)

    /// The glass material under the three bands, or nil under flat. Created and
    /// torn down by ``applyResolvedChrome()``, not merely hidden, for the same
    /// "absence of the view is part of what byte-identical means" reason
    /// `TerminalPaneController.applyResolvedGlassPlane()` builds and removes
    /// the pane's ``PaneGlassPlaneView`` outright rather than hiding it.
    ///
    /// The backing's refusals answer a separate question, and their source is
    /// ``PaneGlassPlaneView``'s own `hitTest` returning nil: a glass view that
    /// hit-tests swallows the click meant for what sits under it, which in a
    /// pane is the click that focuses it and here is the click on the query
    /// field or a row.
    private var glassBacking: PaletteGlassBacking?

    private var projects: [Project] = []
    private var recency: [String: Int] = [:]

    /// What the list is currently showing.
    ///
    /// An enum rather than two arrays with a `Bool` beside them, so the three
    /// places that read a selected row cannot reach the wrong population. The
    /// git read in particular takes a `Project.url` and forks a subprocess; with
    /// parallel arrays, a verb row selected at an index a project also occupies
    /// would have run `git status` against whatever project sat there.
    private enum Results {
        case projects([Project])
        case verbs([PaletteVerb])

        var count: Int {
            switch self {
            case let .projects(projects): projects.count
            case let .verbs(verbs): verbs.count
            }
        }

        var isEmpty: Bool { count == 0 }
    }

    private var results: Results = .projects([])

    /// Bumped on every selection change, so a git read that comes back for a row
    /// the user has already moved off is discarded rather than drawn. Holding an
    /// arrow key starts one read per row and they do not return in order.
    private var gitGeneration = 0

    private var resignObserver: (any NSObjectProtocol)?

    /// The window the palette was summoned over.
    ///
    /// Held rather than looked up, because the obvious lookups are both wrong the
    /// moment the palette is on screen: `NSApp.keyWindow` is the palette itself,
    /// so repositioning against it walks the panel down the screen by its own
    /// height on every keystroke, and `panel.parent` is nil because the palette
    /// is a sibling rather than a child window. Weak, so a window closed behind
    /// the palette is not kept alive by it.
    private weak var hostWindow: NSWindow?

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // `isMovable = true` deliberately, against the 26.2 regression in §6.8:
        // glass inside a borderless *non-movable* transparent window stops
        // re-sampling as content moves beneath it (forums 810314), and the
        // documented partial workaround is exactly this flag — the same one the
        // glass-backdrop spike's probe set on all three window types
        // (`Diagnostics/glass-backdrop/backdroptest.swift`). This panel wears
        // glass under `resolvedChrome == .glass`, so it needs the workaround.
        //
        // `isMovableByWindowBackground` is never set and so stays AppKit's
        // `false` default, and `content` has no title bar and no
        // `mouseDown`/`performDrag` of its own (`PaletteListView.mouseDown`
        // only sets the row selection) — so a user still cannot drag this
        // panel by clicking its background or any row. `isMovable = true` on
        // its own only permits a drag that some view has to initiate; nothing
        // here does, and `position()` re-anchors the panel under the summoning
        // window on every open regardless.
        panel.isMovable = true
        panel.animationBehavior = .none
        // The `didSet` on ``isDark`` cannot have run — a property's observer is
        // silent during initialisation — so the stored default has to be written
        // onto the panel by hand once here. `AppDelegate` overwrites it with
        // `configuration.windowIsDark` a moment later, the same way it does
        // `theme` and `resolvedChrome`; this only ensures the panel is never in
        // an appearance nothing chose.
        applyAppearance()

        content.wantsLayer = true
        content.layer?.backgroundColor = nsColor(theme.panelBackground).cgColor
        content.layer?.cornerRadius = 6
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1
        content.layer?.borderColor = nsColor(theme.hairline).cgColor
        for view in [queryView, listView, hintsView] { content.addSubview(view) }
        panel.contentView = content

        // `⌘K` is what summons this panel, unlike the find panel that shares
        // this same header view and is never captioned with a keycap.
        queryView.trailingKeycap = "\u{2318}K"

        queryView.field.delegate = self
        queryView.field.onCommand = { [weak self] selector in
            self?.handle(selector) ?? false
        }
        listView.onActivate = { [weak self] index, action in
            self?.open(at: index, action: action)
        }
        listView.onSelectionChange = { [weak self] in
            self?.refreshSelectedGitState()
        }
    }

    // No `deinit` removing `resignObserver`, for the same reason the trackers do
    // not invalidate their timers there: Swift 6 forbids touching non-`Sendable`
    // state from a nonisolated deinit. It costs nothing here. The observer is
    // registered against `panel`, which this object owns, and the palette is held
    // by the app delegate for the process's whole life, so the two die together
    // and only at termination.

    // MARK: - Presenting

    /// Shows the palette over `host`, or hides it when it is already up.
    ///
    /// ⌘K is a toggle rather than a one-way open, because the key that summons a
    /// thing is the key a hand reaches for to dismiss it.
    func toggle(over host: NSWindow?, projects: [Project], recency: [String: Int]) {
        guard !panel.isVisible else {
            dismiss()
            return
        }
        present(over: host, projects: projects, recency: recency)
    }

    func present(over host: NSWindow?, projects: [Project], recency: [String: Int]) {
        self.projects = projects
        self.recency = recency
        hostWindow = host

        queryView.field.stringValue = ""
        refilter()

        position()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(queryView.field)

        // Dismissed when it stops being key, which covers clicking back into a
        // pane, switching tabs, and ⌘Tab. Nothing here needs a click monitor:
        // losing key is the only way to leave the palette without choosing.
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
    }

    /// Replaces the project list, refiltering in place when the palette is up.
    ///
    /// Discovery walks the workspace and forks one `git worktree list` per
    /// repository, so it cannot happen between ⌘K and the first drawn frame. The
    /// palette opens on whatever is cached, empty on a cold launch, and this
    /// fills it in when the walk lands. The query is preserved rather than
    /// cleared, because the results arriving is not a reason to discard what the
    /// user has already typed.
    func setProjects(_ projects: [Project], recency: [String: Int]) {
        self.projects = projects
        self.recency = recency
        guard panel.isVisible else { return }
        refilter()
        position()
    }

    func dismiss() {
        guard panel.isVisible else { return }
        // Read before ordering out, and only honoured when the palette itself
        // still held the keyboard. The resign-key observer is delivered through
        // `OperationQueue.main`, so it runs a turn *after* AppKit has already
        // handed key to whatever the user clicked. Restoring unconditionally
        // then yanked the keyboard back to the host window while a different
        // window sat in front of it, which is the exact case the observer's own
        // comment says it covers.
        let hadKey = panel.isKeyWindow
        panel.orderOut(nil)
        // Key goes back to the window the palette was summoned over rather than
        // to nothing, so the focused pane gets its keyboard back and every pane
        // comes out of the inactive scrim.
        if hadKey { hostWindow?.makeKey() }
    }

    /// Centres the panel horizontally over the host window and sits it in the
    /// upper third.
    ///
    /// Not vertically centred. A list that grows downwards from a fixed top edge
    /// keeps its first row in one place as results come and go, and the first row
    /// is the one being read while typing.
    private func position() {
        let height = Self.height(forRowCount: results.count)
        panel.setContentSize(NSSize(width: Self.width, height: height))
        layoutContent(height: height)

        guard let frame = hostWindow?.frame ?? NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - Self.width / 2,
            y: frame.maxY - height - Self.topInset
        ))
    }

    private func layoutContent(height: Double) {
        // Laid out by hand rather than with constraints. Three stacked bands of
        // fixed height in a panel that is resized programmatically is the case
        // autolayout costs more than it saves.
        let listHeight = height - PaleteMetrics.query - PaleteMetrics.hints
        queryView.frame = NSRect(
            x: 0, y: height - PaleteMetrics.query,
            width: Self.width, height: PaleteMetrics.query
        )
        listView.frame = NSRect(
            x: 0, y: PaleteMetrics.hints,
            width: Self.width, height: listHeight
        )
        hintsView.frame = NSRect(x: 0, y: 0, width: Self.width, height: PaleteMetrics.hints)
        for view in [queryView, listView, hintsView] { view.needsDisplay = true }
        // `content.layer.masksToBounds` already clips this to the panel's own
        // rounded corners, so the backing needs no mask of its own the way the
        // footer's did against the window's variable-corner squircle.
        glassBacking?.frame = content.bounds
    }

    // MARK: - Chrome material

    /// Writes ``isDark`` onto the panel.
    ///
    /// `.darkAqua` / `.aqua` and nothing else, for the reason
    /// `WorkspaceWindowController.applyAppearance()` gives on its own identical
    /// line: the vibrant and high-contrast variants are accessibility choices
    /// this panel has no opinion on, and these two are what
    /// `AppearanceObserver.readCurrentAppearance()` already resolves a system
    /// read down to.
    private func applyAppearance() {
        panel.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    /// Creates or tears down ``glassBacking`` to match ``resolvedChrome``.
    ///
    /// Verified against the installed SDK the same way `PaneStatusBarView`'s
    /// own copy was (Plan 2's Task 4 gate): `NSGlassEffectView.tintColor` and
    /// `.style` compile against macOS 26, unguarded, matching `project.yml`'s
    /// deployment target.
    ///
    /// **Untinted glass (Task 2) is still what ships.** `backing.tintColor` used
    /// to carry `set.fillMenu`; it is left nil now, the same untinted glass the
    /// pane's own plane (`PaneGlassPlaneView`) ships with, at the native style
    /// the resolved set names (`.regular` for `liquidGlass`, `.clear` for
    /// `sheer`). The three bands above
    /// (``PaletteQueryView``, ``PaletteListView``, ``PaletteHintsView``) used to
    /// draw `fillMenu` a second time as their own fill; Task 2 removed that too,
    /// so nothing downstream of this method paints `fillMenu` any more — see
    /// each band's own `draw(_:)`.
    ///
    /// ``fillMaterial`` can put the tint back, and only the debug design panel
    /// can set it (see ``SurfaceFill``). One tint, on the backing alone: the
    /// bands' own second fill is not restored, since it was the *stacked* copy
    /// the spike objected to hardest.
    private func applyResolvedChrome() {
        switch resolvedChrome {
        case .flat:
            glassBacking?.removeFromSuperview()
            glassBacking = nil
            content.layer?.backgroundColor = nsColor(theme.panelBackground).cgColor
        case let .glass(set):
            // Cleared rather than left at `panelBackground`: `content`'s own
            // layer sits behind `glassBacking` in the same window, and an
            // opaque colour there is exactly what the glass view would sample
            // and composite, which reproduces the panel's old opaque fill
            // underneath a blur nobody can see past. The three bands above
            // still tile `content`'s bounds exactly (`layoutContent` sizes
            // them to sum to the full height), so nothing is left unpainted.
            content.layer?.backgroundColor = NSColor.clear.cgColor
            let backing: PaletteGlassBacking
            if let existing = glassBacking {
                backing = existing
            } else {
                backing = PaletteGlassBacking(frame: content.bounds)
                backing.style = NSGlassEffectView.Style(set.nativeStyle)
                backing.wantsLayer = true
                // Below the three bands, and untinted the same way they draw
                // no fill of their own any more (Task 2) — see
                // ``PaletteQueryView/draw(_:)`` and its siblings. Nothing
                // between this backing and the terminal beneath paints
                // `fillMenu`, or any fill, on the glass path.
                content.addSubview(backing, positioned: .below, relativeTo: queryView)
                glassBacking = backing
            }
        }
        updateGlassMaterial()
    }

    /// Writes the set's native style and ``fillMaterial``'s colour onto the
    /// backing; the colour is nil in what ships and in every Release build.
    ///
    /// Called from ``applyResolvedChrome()`` as well as from ``fillMaterial``'s
    /// own `didSet`, so a tint set before the backing existed still lands when
    /// it is created, and a stale one cannot survive a flat/glass round trip.
    /// The style write on every pass is what lets a live `liquidGlass`/`sheer`
    /// switch reach a backing the early-return above kept.
    private func updateGlassMaterial() {
        guard let glassBacking, case let .glass(set) = resolvedChrome else { return }
        glassBacking.style = NSGlassEffectView.Style(set.nativeStyle)
        glassBacking.tintColor = SurfaceFill.colour(fillMaterial, in: set)
    }

    // MARK: - Filtering

    func controlTextDidChange(_: Notification) {
        refilter()
        position()
    }

    private func refilter() {
        let query = queryView.field.stringValue

        // `>` switches populations. Checked before anything is ranked, because
        // the two rankers score different things and neither can answer for the
        // other: `ProjectRanker` breaks ties on a recency count keyed by path,
        // and a verb has no path.
        if let verbQuery = VerbRanker.verbQuery(from: query) {
            refilterVerbs(matching: verbQuery)
            return
        }

        let ranked = ProjectRanker.rank(projects, query: query, recency: recency)
        results = .projects(ranked)
        // The row follows the result set, because both actions it can name return
        // immediately when there is nothing matched.
        hintsView.hints = PaletteHints.palette(hasResults: !ranked.isEmpty)

        // Matched against `relativePath`, which is also what the row draws, so
        // the offsets `FuzzyMatcher` reports land on the characters the reader is
        // looking at with no translation in between.
        listView.rows = ranked.map { project in
            PaletteRow.make(
                relativePath: project.relativePath,
                matchedIndices: FuzzyMatcher.match(
                    query: query,
                    candidate: project.relativePath
                )?.matchedIndices ?? [],
                kind: PaletteRow.kind(of: project.kind)
            )
        }
        listView.selection = 0
        queryView.countText = countText(query: query)
        refreshSelectedGitState()
    }

    /// The verb half, which draws the same row type and reads no git state.
    ///
    /// A verb row has no repository behind it, so `refreshSelectedGitState` is
    /// not called here and the previous row's runs are cleared instead. Leaving
    /// them would draw the last selected project's branch beside a verb.
    private func refilterVerbs(matching query: String) {
        let ranked = VerbRanker.rank(availableVerbs(hostWindow), query: query)
        results = .verbs(ranked)
        hintsView.hints = PaletteHints.verbs(hasResults: !ranked.isEmpty)

        listView.rows = ranked.map { verb in
            PaletteRow.verb(
                title: verb.title,
                shortcut: verb.shortcut,
                matchedIndices: FuzzyMatcher.match(
                    query: query,
                    candidate: verb.title
                )?.matchedIndices ?? [],
                unavailableReason: verb.unavailableReason
            )
        }
        // Cleared after the selection moves, not before. Setting `selection`
        // raises `onSelectionChange`, and while `refreshSelectedGitState` does
        // nothing in verb mode today, ordering the clear last means this stays
        // right even if that stops being true.
        listView.selection = 0
        listView.selectedGitRuns = []
        queryView.countText = verbCountText(query: query, shown: ranked.count)
    }

    /// `3 of 12` while filtering, a bare total before the first keystroke. The
    /// second number is what says how much of the workspace is out of view.
    private func countText(query: String) -> String {
        guard !query.isEmpty else { return "\(projects.count)" }
        return "\(results.count) of \(projects.count)"
    }

    /// The same shape for verbs, counted against the verbs available rather than
    /// against the project list.
    ///
    /// Its own function rather than a parameter on the one above, because the
    /// denominators are different facts: how much of the workspace is out of
    /// view, and how much of what the app can do right now is out of view.
    private func verbCountText(query: String, shown: Int) -> String {
        let total = availableVerbs(hostWindow).count
        guard !query.isEmpty else { return "\(total)" }
        return "\(shown) of \(total)"
    }

    // MARK: - Keyboard

    private func handle(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1)
        // Return opens in a new tab, Shift-Return splits right, and the
        // difference is read off the event rather than off the selector.
        //
        // Shift-Return arrives here as `insertNewline:`, not as
        // `insertNewlineIgnoringFieldEditor:`. AppKit's
        // `StandardKeyBinding.dict` binds `\r`, `\n` and `\x03` to
        // `insertNewline:` and carries no `$\r` entry at all, so shift falls
        // through to the plain binding; the selector below is `~\r`, which is
        // Option-Return. Believing otherwise made this gesture silently open a
        // tab, since that is what the case above does.
        case #selector(NSResponder.insertNewline(_:)):
            let splitting = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            open(at: listView.selection, action: splitting ? .splitRight : .newTab)
        // Option-Return, kept as an alias now that shift is handled above.
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            open(at: listView.selection, action: .splitRight)
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
        default:
            return false
        }
        return true
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        handle(selector)
    }

    /// Moves the selection, stopping at both ends rather than wrapping.
    ///
    /// Wrapping is wrong for a ranked list. The top row is the best match, so
    /// pressing up from it and landing on the worst one moves the eye the whole
    /// length of the list to reach the thing furthest from what was asked for.
    private func move(by delta: Int) {
        guard !results.isEmpty else { return }
        // Clamped first, and a no-op returns before the git read. Holding an
        // arrow key at either end kept re-selecting the same row, and each of
        // those re-selections forked another `git status` at the key-repeat
        // rate for a row that had not changed.
        let next = max(0, min(results.count - 1, listView.selection + delta))
        guard next != listView.selection else { return }
        // The git read follows from `onSelectionChange` rather than from a call
        // here, so the arrows and the pointer refresh through one path. Calling
        // it here as well would fork two subprocesses per arrow key.
        listView.selection = next
    }

    /// Commits the selected row, which means different things in the two modes.
    ///
    /// A verb ignores `action` rather than honouring it. Shift-Return means
    /// "split right" for a project, and there is no second way to run Equalize
    /// Panes; silently treating the modifier as a variant would invent a
    /// behaviour nothing asked for.
    private func open(at index: Int, action: PaletteAction) {
        switch results {
        case let .projects(projects):
            guard projects.indices.contains(index) else { return }
            let project = projects[index]
            guard canOpenProject(hostWindow) else {
                NSSound.beep()
                return
            }
            dismiss()
            onOpen?(project, action, hostWindow)
        case let .verbs(verbs):
            guard verbs.indices.contains(index) else { return }
            let verb = verbs[index]
            // An unavailable verb is listed so it can be found, not so it can be
            // run. Committing it would dismiss the palette and do nothing, which
            // is the worst of both: the reason it gave is gone from the screen
            // before the reader can act on it.
            guard verb.isAvailable else { return }
            guard let execute = prepareVerb(verb.id, hostWindow) else {
                NSSound.beep()
                return
            }
            dismiss()
            if !execute() { NSSound.beep() }
        }
    }

    // MARK: - Git state for the selected row

    /// Reads git state for the selected row only, off the main thread.
    ///
    /// One repository rather than all of them. Every read is a `git` subprocess,
    /// so a branch on every row would be one per project on every open, before a
    /// key is pressed. Off the main thread because holding an arrow key would
    /// otherwise run one subprocess per row inside the event that moved the
    /// selection, and the list would stutter under the finger doing the moving.
    private func refreshSelectedGitState() {
        gitGeneration += 1
        let generation = gitGeneration
        listView.selectedGitRuns = []

        // A verb has no repository behind it, so there is nothing to read and
        // the cleared runs above are the whole answer.
        guard case let .projects(projects) = results else { return }
        guard projects.indices.contains(listView.selection) else { return }
        let project = projects[listView.selection]
        guard project.kind != .directory else { return }
        let root = project.url

        Task.detached(priority: .userInitiated) {
            let status = GitCommand().status(ofRepositoryRoot: root)
            await MainActor.run { [weak self] in
                guard let self, generation == gitGeneration else { return }
                listView.selectedGitRuns = status.map(PaneGitRuns.runs(for:)) ?? []
            }
        }
    }

    private func nsColor(_ rgb: RGB, alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: CGFloat(alpha))
    }

    private enum PaleteMetrics {
        static let query = PaletteQueryView.height
        static let hints = PaletteHintsView.height
    }

    private static func height(forRowCount count: Int) -> Double {
        PaletteListView.height(forRowCount: count) + PaleteMetrics.query + PaleteMetrics.hints
    }

    /// Design v5 §6, `--w-palette` in `metrics.css`. Was 620.
    private static let width: Double = 640

    /// How far below the window's top edge the panel sits. Clear of the titlebar
    /// and the tab bar, so the palette never covers the tabs it is about to add
    /// one to.
    private static let topInset: Double = 96
}
