import AppKit
import PaneChrome
import PaneSearch

/// What the panel searches.
enum FindScope: Equatable {
    /// The pane that had focus when the panel opened.
    case focusedPane
    /// Every pane in every tab.
    case workspace
}

/// One match, with enough context for the app to act on it.
///
/// A pane id and never a pane. libghostty exposes no way to close a surface, so
/// a pane's pty dies only when its controller deallocates, and
/// `PaneTreeController` is the only thing allowed to own one. A result holding a
/// pane would keep a closed pane's shell running with no window to reach it,
/// visible only as a stray `login -flp` in `ps`.
struct FindResult {
    let paneID: UUID
    let project: String
    let match: LineMatch
    /// The lines the match came from, kept so the row can be resolved without a
    /// second read of a pane whose output may have moved on since. Strings, so
    /// this holds no pane either.
    let lines: [String]
}

/// The ⌘F panel.
///
/// An `NSPanel` and not a bar inside the pane, for the same reason the command
/// palette is: `AppTerminalView.performKeyEquivalent` opens with
/// `guard window?.firstResponder === self`, so an `NSTextField` anywhere inside
/// a pane disables every ghostty binding in that pane, silently and with nothing
/// on screen to explain it. A separate panel is allowed to take the keyboard,
/// and ``dismiss()`` hands it back.
@MainActor
final class FindPanelController: NSObject, NSTextFieldDelegate {
    /// Asked for the panes to search. Returns the pane id, its project name and
    /// its lines, so the controller never reaches into a pane itself.
    ///
    /// Values only, for the reason ``FindResult`` carries an id: a closure that
    /// handed back panes would put a pane reference inside this object, and this
    /// object outlives every window.
    var onCollect: ((FindScope) -> [(id: UUID, project: String, lines: [String])])?

    /// Raised when the owner goes to a match.
    var onGo: ((FindResult) -> Void)?

    var theme: PaneTheme = .darkPastel {
        didSet {
            queryView.theme = theme
            listView.theme = theme
            hintsView.theme = theme
            content.layer?.backgroundColor = nsColor(theme.panelBackground).cgColor
        }
    }

    private let panel: PalettePanel

    /// Held for the tint and the rounded corners both, exactly as the palette
    /// holds its own: an `NSWindow` fills its whole frame rect underneath the
    /// content view, so the corners have to be clipped on a view rather than
    /// coloured on the window.
    private let content = NSView(
        frame: NSRect(x: 0, y: 0, width: FindPanelController.width, height: 300)
    )
    private let queryView = PaletteQueryView(frame: .zero)
    private let listView = PaletteListView(frame: .zero)
    private let hintsView = PaletteHintsView(frame: .zero)

    private var scope: FindScope = .focusedPane
    private var results: [FindResult] = []

    /// The panes the current search runs against, read when the panel opens and
    /// again only when the scope widens.
    ///
    /// A snapshot, and read once rather than per keystroke. `readScreenLines`
    /// copies a pane's whole scrollback, which ghostty lets reach 10 MB, and
    /// splits it into one string per line; doing that inside
    /// `controlTextDidChange` is the work-inside-the-keystroke that the widened
    /// scope was guarded against, and the focused pane was paying it too. It is
    /// also what lets ``FindResult/lines`` be the lines that were really
    /// searched, since a second read would answer with output that has moved on.
    private var panes: [(id: UUID, project: String, lines: [String])] = []

    /// Whether the last search stopped at ``resultLimit`` with more to find, so
    /// the count line can say `200+` rather than claim 200 is all there is.
    private var isTruncated = false

    /// How many panes the last search covered, kept because the count line is
    /// rebuilt when the selection moves and re-deriving it there would report
    /// zero panes.
    private var searchedPaneCount = 0

    private var resignObserver: (any NSObjectProtocol)?

    /// The window the panel was summoned over. Weak, so a window closed behind
    /// the panel is not kept alive by it, and read from here rather than from
    /// `NSApp.keyWindow`, which is the panel itself while it is up.
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

        // The hints are the panel's own. Left at the palette's defaults they
        // would offer "new tab" and "split right" under a list of search hits,
        // which is a footer describing a different window.
        hintsView.hints = Self.hints

        queryView.field.delegate = self
        queryView.field.onCommand = { [weak self] selector in
            self?.handle(selector) ?? false
        }
        listView.onActivate = { [weak self] index, _ in
            self?.go(to: index)
        }
    }

    // No `deinit` removing `resignObserver`, for the reason the palette has
    // none: Swift 6 forbids touching non-`Sendable` state from a nonisolated
    // deinit, the observer is registered against a panel this object owns, and
    // the app delegate holds this for the process's whole life.

    // MARK: - Presenting

    /// Shows the panel over `host`, or hides it when it is already up.
    ///
    /// Reopening always narrows back to the focused pane. A widened scope is an
    /// answer to one question, and carrying it into the next ⌘F would search
    /// every tab for a needle the owner typed while looking at one pane.
    func toggle(over host: NSWindow?) {
        guard !panel.isVisible else { return dismiss() }
        scope = .focusedPane
        hostWindow = host
        queryView.field.stringValue = ""
        results = []
        collect()
        refresh()
        position()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(queryView.field)

        // Dismissed when it stops being key, which covers clicking back into a
        // pane, switching tabs, and ⌘Tab.
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

    func dismiss() {
        guard panel.isVisible else { return }
        // Read before ordering out, and honoured only when the panel still held
        // the keyboard. The observer above is delivered through
        // `OperationQueue.main`, so it runs a turn after AppKit has handed key
        // to whatever was clicked; restoring unconditionally yanks it back.
        //
        // Handing key back is the whole of invariant 1 on the way out: the
        // window's first responder is still the terminal, and it is the window
        // being key again that makes ghostty's bindings live.
        let hadKey = panel.isKeyWindow
        panel.orderOut(nil)
        if hadKey { hostWindow?.makeKey() }

        // The snapshot goes with the panel. Kept past the close it is a copy of
        // every searched pane's scrollback, megabytes of it, held for the life
        // of a controller the app delegate never releases. `go(to:)` reads its
        // result before calling this, so the jump still has the lines it needs.
        panes = []
        results = []
        listView.rows = []
    }

    // MARK: - Searching

    /// Every scope re-matches on every keystroke, which is what the widened
    /// scope used to be excluded from.
    ///
    /// Excluding it left the list showing the previous needle's hits while the
    /// field said something else, and Return then went to one of them: type
    /// `err`, widen, type `or`, press Return, and the pane jumps to a line
    /// holding `err` while the field reads `error`. Nothing here reads a pane,
    /// so there is no longer a cost to exclude it from.
    func controlTextDidChange(_: Notification) {
        refresh()
        position()
    }

    /// Reads the panes in scope. The only place a pane's scrollback is touched.
    private func collect() {
        panes = onCollect?(scope) ?? []
        searchedPaneCount = panes.count
    }

    private func refresh() {
        let query = SearchQuery(needle: queryView.field.stringValue)

        // One past the cap, so the count knows whether anything was cut without
        // matching the rest of the scrollback to find out.
        let found = panes.flatMap { pane in
            PaneSearch.matches(in: pane.lines, query: query, limit: Self.resultLimit + 1).map {
                FindResult(paneID: pane.id, project: pane.project, match: $0, lines: pane.lines)
            }
        }
        isTruncated = found.count > Self.resultLimit
        results = Array(found.prefix(Self.resultLimit))

        listView.rows = results.map {
            PaletteRow.match(
                line: $0.match.line,
                highlight: $0.match.range,
                project: $0.project
            )
        }
        listView.selection = 0
        queryView.countText = countText()
    }

    /// `3 of 17` in a single pane, `17 in 4 panes` across the workspace. The
    /// second number is the one that says whether the answer is somewhere the
    /// owner is not looking.
    private func countText() -> String {
        guard !results.isEmpty else {
            return scope == .workspace ? "0 in \(searchedPaneCount) panes" : "0"
        }
        // `200+` when the scan stopped at the cap. A cut-off count is still an
        // answer, and it is the honest one: the alternative is a number that
        // took a second to produce and describes rows nobody can reach.
        let total = isTruncated ? "\(results.count)+" : "\(results.count)"
        if scope == .workspace {
            let panes = Set(results.map(\.paneID)).count
            return "\(total) in \(panes) pane\(panes == 1 ? "" : "s")"
        }
        return "\(listView.selection + 1) of \(total)"
    }

    // MARK: - Keyboard

    private func handle(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1)
        // Return goes to the selection, in either scope. It used to re-run a
        // widened search instead when that search had no results, which was the
        // other half of excluding the widened scope from `controlTextDidChange`:
        // both are gone, and the list now always describes what the field says.
        //
        // Shift-Return widens instead, and the difference is read off the event
        // rather than off the selector, because Shift-Return arrives here as
        // `insertNewline:` too. AppKit's `StandardKeyBinding.dict` binds `\r`,
        // `\n` and `\x03` to `insertNewline:` and carries no `$\r` entry at
        // all, so shift falls through to the plain binding; the selector below
        // is `~\r`, which is Option-Return. Believing otherwise cost the
        // gesture entirely: it dispatched to `go(to:)`, which returns on an
        // empty result set, so widening from a pane with no hits did nothing at
        // all, which is exactly the case it exists for.
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                widen()
            } else {
                go(to: listView.selection)
            }
        // Option-Return, kept as an alias now that shift is handled above.
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            widen()
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

    /// Widens to every pane in every tab, the one gesture that has to work from
    /// an empty result set: the answer not being in this pane is exactly when
    /// the owner wants the rest of them.
    private func widen() {
        scope = .workspace
        collect()
        refresh()
        position()
    }

    /// Moves the selection, stopping at both ends rather than wrapping, for the
    /// palette's reason: the list is in reading order and wrapping from the
    /// first hit to the last moves the eye the length of the scrollback.
    private func move(by delta: Int) {
        guard !results.isEmpty else { return }
        let next = max(0, min(results.count - 1, listView.selection + delta))
        guard next != listView.selection else { return }
        listView.selection = next
        queryView.countText = countText()
    }

    /// Dismissed before the callback, so the pane the owner is being sent to is
    /// the key window by the time it scrolls rather than a moment afterwards.
    private func go(to index: Int) {
        guard results.indices.contains(index) else { return }
        let result = results[index]
        dismiss()
        onGo?(result)
    }

    // MARK: - Layout

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
        // Laid out by hand rather than with constraints, as the palette is:
        // three stacked bands of fixed height in a panel resized in code is the
        // case autolayout costs more than it saves.
        let listHeight = height - PaletteQueryView.height - PaletteHintsView.height
        queryView.frame = NSRect(
            x: 0, y: height - PaletteQueryView.height,
            width: Self.width, height: PaletteQueryView.height
        )
        listView.frame = NSRect(
            x: 0, y: PaletteHintsView.height, width: Self.width, height: listHeight
        )
        hintsView.frame = NSRect(
            x: 0, y: 0, width: Self.width, height: PaletteHintsView.height
        )
        for view in [queryView, listView, hintsView] { view.needsDisplay = true }
    }

    private func nsColor(_ rgb: RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
    }

    private static func height(forRowCount count: Int) -> Double {
        PaletteListView.height(forRowCount: count)
            + PaletteQueryView.height + PaletteHintsView.height
    }

    /// Wider than the palette, because a row here is a line of terminal output
    /// rather than a project path, and a truncated line hides the context the
    /// hit is being judged by.
    private static let width: Double = 720

    private static let topInset: Double = 96

    /// How many hits a search keeps. The list draws eight of them and the
    /// arrows move one at a time, so the hits past this were unreachable in
    /// practice while costing what they cost: a needle of `e` on a 3.9 MB
    /// scrollback found 420,000 of them, and building a row for each took a
    /// second of blocked main thread and 175 MB to draw nothing.
    private static let resultLimit = 200

    private static let hints: [(key: String, label: String)] = [
        ("\u{21A9}", "go"),
        ("\u{21E7}\u{21A9}", "all panes"),
        ("esc", "close"),
    ]
}
