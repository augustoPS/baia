import AppKit
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

/// The ⌘K project palette.
///
/// Owns the panel and the keyboard, and nothing else. Discovery, ranking and the
/// recency store all live in `GitWorkspace` and were built and tested long before
/// this existed; what was missing was only the surface. The palette hands the
/// chosen project back through ``onOpen`` rather than opening it itself, because
/// only the app delegate knows what a tab is.
@MainActor
final class CommandPaletteController: NSObject, NSTextFieldDelegate {
    /// Raised with the chosen project and what to do with it.
    var onOpen: ((Project, PaletteAction) -> Void)?

    /// Raised with the chosen verb's `MenuCommand.tag`, for the same reason
    /// ``onOpen`` exists: only the app delegate can perform a menu command, and
    /// the palette's job ends at deciding which one was asked for.
    var onRunVerb: ((Int) -> Void)?

    /// Every verb available right now, supplied by the app target because
    /// availability is a fact about the app rather than about this panel.
    ///
    /// Re-read on each open rather than held across opens: `Close Tab` is
    /// available with two tabs and not with one, and a list captured when the
    /// palette was built would offer a verb that has since become impossible.
    var availableVerbs: () -> [PaletteVerb] = { [] }

    var theme: PaneTheme = .darkPastel {
        didSet {
            queryView.theme = theme
            listView.theme = theme
            hintsView.theme = theme
            content.layer?.backgroundColor = nsColor(theme.panelBackground).cgColor
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
        panel.isMovable = false
        panel.animationBehavior = .none

        content.wantsLayer = true
        content.layer?.backgroundColor = nsColor(theme.panelBackground).cgColor
        content.layer?.cornerRadius = 6
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1
        content.layer?.borderColor = nsColor(theme.hairline).cgColor
        for view in [queryView, listView, hintsView] { content.addSubview(view) }
        panel.contentView = content

        queryView.field.delegate = self
        queryView.field.onCommand = { [weak self] selector in
            self?.handle(selector) ?? false
        }
        listView.onActivate = { [weak self] index, action in
            self?.open(at: index, action: action)
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
        let ranked = VerbRanker.rank(availableVerbs(), query: query)
        results = .verbs(ranked)
        hintsView.hints = PaletteHints.verbs(hasResults: !ranked.isEmpty)

        listView.rows = ranked.map { verb in
            PaletteRow.verb(
                title: verb.title,
                shortcut: verb.shortcut,
                matchedIndices: FuzzyMatcher.match(
                    query: query,
                    candidate: verb.title
                )?.matchedIndices ?? []
            )
        }
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
        let total = availableVerbs().count
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
        listView.selection = next
        // No-op in verb mode, which is what the guard inside it answers. Left as
        // one call rather than a branch here, so the rule about which rows have
        // git state lives in one place.
        refreshSelectedGitState()
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
            dismiss()
            onOpen?(project, action)
        case let .verbs(verbs):
            guard verbs.indices.contains(index) else { return }
            let verb = verbs[index]
            dismiss()
            onRunVerb?(verb.id)
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
                listView.selectedGitRuns = status.map(PaneStatusSegments.runs(for:)) ?? []
            }
        }
    }

    private func nsColor(_ rgb: RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
    }

    private enum PaleteMetrics {
        static let query = PaletteQueryView.height
        static let hints = PaletteHintsView.height
    }

    private static func height(forRowCount count: Int) -> Double {
        PaletteListView.height(forRowCount: count) + PaleteMetrics.query + PaleteMetrics.hints
    }

    private static let width: Double = 620

    /// How far below the window's top edge the panel sits. Clear of the titlebar
    /// and the tab bar, so the palette never covers the tabs it is about to add
    /// one to.
    private static let topInset: Double = 96
}
