import AppKit
import GitWorkspace
import PaneChrome

/// The focused pane's repository, as a tree.
///
/// Everything git considers to be in the repository and nothing it ignores, which
/// is `git ls-files --cached --others --exclude-standard` rather than a walk of our
/// own. `FileTree` records why at length: honouring an ignore file means honouring
/// negations, nested ignore files, `info/exclude` and the global, and a tree that
/// disagrees with git about what is in the repository is worse than one that omits
/// an ignored file.
///
/// **Nothing here ever becomes first responder.** This is the clickable list the
/// whole housing argument was about: `AppTerminalView.performKeyEquivalent` opens
/// with `guard window?.firstResponder === self`, and that is the *window's* first
/// responder, so a row taking focus on click would disable every ghostty binding in
/// every pane of this window. Rows are hit-tested in `mouseDown` and focus is never
/// requested. The scroll view is safe for the same reason: `NSScrollView` and
/// `NSClipView` do not take first responder either.
@MainActor
final class FilesSurface: NSObject, WorkspaceSurface {
    var view: NSView { scrollView }

    let title = "Files"

    var theme: PaneTheme = .darkPastel {
        didSet {
            rows.theme = theme
            fill()
        }
    }

    var backgroundOpacity: Double = 1 {
        didSet { fill() }
    }

    /// The column's body, drawn once by the scroll view and never by the rows on
    /// top of it. See ``ChangesSurface/fill()``, which says what filling twice
    /// costs now that the fill has an alpha.
    private func fill() {
        scrollView.backgroundColor = ChangesSurface.nsColor(
            theme.background,
            alpha: backgroundOpacity
        )
    }

    /// The tree to draw. A *different* tree collapses everything below the top
    /// level, because an expansion set from one repository means nothing in the
    /// next.
    ///
    /// **An equal tree is not a different one, and the guard is what makes the
    /// surface usable.** `refreshSidebar(of:)` assigns on every focus change and
    /// every git poll that reports something new, so without it a command run in
    /// the pane collapsed whatever the owner had opened, several times a minute.
    /// Caught on 2026-07-29, in the first live check of the path picker.
    var tree: [FileTreeNode] = [] {
        didSet {
            guard tree != oldValue else { return }
            rows.expanded = []
            rows.tree = tree
        }
    }

    var hasRepository = true {
        didSet { rows.hasRepository = hasRepository }
    }

    /// None. How many files a repository contains is not a question anyone has,
    /// and a four-digit number beside `FILES` would read as an error. Design v3
    /// §4.1.
    var headingCount: Int? { nil }

    /// Called with a repository-relative path when a row's name is clicked.
    ///
    /// The surface knows nothing about what happens next. Whether that path is
    /// quoted, sent relative or absolute, or refused outright is `PromptPath`'s
    /// business, and where it goes is the owner's.
    /// Answers `true` when the path landed on the prompt and `false` when it was
    /// refused, which is the one bit the row needs to know which flash to draw.
    /// `PromptPath.Resolution` already carries that distinction, so the surface
    /// stays as ignorant of quoting as it was. Design v3 §2.3.
    var onSelect: ((String) -> Bool)? {
        get { rows.onSelect }
        set { rows.onSelect = newValue }
    }

    private let scrollView = NSScrollView()
    private let rows = FileTreeRowsView()

    override init() {
        super.init()
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = rows
        rows.theme = theme
    }
}

/// The rows themselves, drawn rather than tabulated.
///
/// No `NSTableView`, for the reason `PaneStatusBarView` gives and one more: a table
/// view brings a selection that wants the keyboard, and wanting the keyboard is the
/// one thing a view in this window must never do.
@MainActor
final class FileTreeRowsView: NSView {
    var theme: PaneTheme = .darkPastel { didSet { needsDisplay = true } }

    var hasRepository = true { didSet { needsDisplay = true } }

    var tree: [FileTreeNode] = [] { didSet { rebuild() } }

    /// Paths of the directories that are open.
    ///
    /// Paths rather than node references, so the set survives the tree being read
    /// again: a poll that returns an equal tree must not collapse what the owner
    /// opened, and node identity would not survive it.
    var expanded: Set<String> = [] { didSet { rebuild() } }

    override var acceptsFirstResponder: Bool { false }

    override var isFlipped: Bool { true }

    /// One visible row: a node and how deep it sits.
    private struct Row {
        let node: FileTreeNode
        let depth: Int
    }

    private var rows: [Row] = []

    private func rebuild() {
        rows = []
        // A fade in flight belongs to the row that was at that index, and after a
        // rebuild that index is a different file.
        feedback.reset()
        append(tree, depth: 0)
        resize()
        // See `ChangesRowsView.changes`: a frame that does not move marks no layout
        // pass, so the areas would stay built against the list that was there
        // before.
        updateTrackingAreas()
        needsDisplay = true
    }

    /// **Sized on every layout pass, not only when the tree changes.**
    ///
    /// The tree had the same failure the changes list had, one degree worse. A
    /// freshly installed surface has a clip view that has not been laid out, so
    /// the width came out zero: the rows drew into nothing *and* the document
    /// view could not be hit, which is why clicking a directory did nothing at
    /// all rather than merely looking blank. It also could not recover the way
    /// the changes list did, since an equal tree is deliberately not re-assigned.
    override func layout() {
        super.layout()
        resize()
        // See `ChangesRowsView.layout()`: areas built against an unlaid clip view
        // cover nothing and are never rebuilt.
        updateTrackingAreas()
    }

    /// The equality guard is what makes calling this from `layout()` safe:
    /// assigning `frame` marks the view for layout again.
    private func resize() {
        let wanted = NSRect(
            x: 0,
            y: 0,
            width: max(superview?.bounds.width ?? 0, 1),
            height: max(Double(rows.count) * Self.rowHeight, superview?.bounds.height ?? 0)
        )
        guard frame != wanted else { return }
        frame = wanted
    }

    private func append(_ nodes: [FileTreeNode], depth: Int) {
        for node in nodes {
            rows.append(Row(node: node, depth: depth))
            if node.isDirectory, expanded.contains(node.path) {
                append(node.children, depth: depth + 1)
            }
        }
    }

    override func draw(_ dirty: NSRect) {
        // No fill of its own: the scroll view behind it is the column's material.
        guard hasRepository else { return draw(message: "not a repository") }
        guard !rows.isEmpty else { return draw(message: "no files") }

        // Only the rows the dirty rect touches. A repository of ten thousand files
        // is ten thousand rows, and drawing them all on every scroll would make the
        // column stutter for output nobody can see.
        let first = max(0, Int(dirty.minY / Self.rowHeight))
        let last = min(rows.count - 1, Int(dirty.maxY / Self.rowHeight))
        guard first <= last else { return }

        for index in first ... last {
            draw(rows[index], atIndex: index)
        }
    }

    private func draw(_ row: Row, atIndex index: Int) {
        let y = Double(index) * Self.rowHeight
        let x = Self.inset + Double(row.depth) * Self.indent

        if let fill = feedback.fill(index, in: theme) {
            ChangesSurface.nsColor(fill.colour, alpha: fill.alpha).setFill()
            NSRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight).fill()
        }

        if row.node.isDirectory {
            let chevron = expanded.contains(row.node.path) ? "▾" : "▸"
            NSAttributedString(
                string: chevron,
                attributes: [.font: Self.font, .foregroundColor: nsColor(theme.inkFaint)]
            ).draw(at: NSPoint(x: x, y: y + Self.textOrigin))
        }

        let rest = row.node.isDirectory ? theme.inkContext : theme.foreground
        let refusal = feedback.ink(index, in: theme)
        NSAttributedString(
            string: row.node.name,
            attributes: [
                .font: Self.font,
                .foregroundColor: nsColor(
                    refusal.map { rest.blended(with: $0.colour, fraction: $0.alpha) } ?? rest
                ),
            ]
        ).draw(at: NSPoint(x: x + Self.chevronColumn, y: y + Self.textOrigin))
    }

    private func draw(message: String) {
        NSAttributedString(
            string: message,
            attributes: [.font: Self.font, .foregroundColor: nsColor(theme.inkFaint)]
        ).draw(at: NSPoint(x: Self.inset, y: Self.textOrigin))
    }

    var onSelect: ((String) -> Bool)?

    private lazy var feedback = RowFeedback { [weak self] row in
        self?.redraw(row)
    }

    /// A directory toggles, a file sends, and neither ever asks for focus.
    ///
    /// `mouseDown` rather than a control or a table selection, and with no
    /// `becomeFirstResponder` anywhere near it. That is the whole safety argument
    /// for a clickable surface living in this window.
    ///
    /// **The whole row, not the chevron.** The first version split the row on x
    /// and gave the name to the picker, so a directory sent its path and only the
    /// chevron expanded. That lost in the first live check, on 2026-07-29: the
    /// chevron is a seven point target in an eighteen point row, the name is what
    /// the hand goes to, and expanding is what a tree is *for*. A directory path
    /// is still one click away through the changes list or by clicking the file
    /// under it, and it was never the case the picker was built for.
    /// **Held rather than fired on the way down**, so the press is a state the eye
    /// can see and a drag off the row cancels. Design v3 §2.3.
    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: event)
        guard rows.indices.contains(row) else { return }
        feedback.pressed = row
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed = feedback.pressed else { return }
        feedback.pressed = row(at: event) == pressed ? pressed : nil
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = feedback.pressed else { return }
        feedback.pressed = nil
        guard rows.indices.contains(index), row(at: event) == index else { return }
        let node = rows[index].node

        // A directory answers by opening, which is answer enough: the rows below it
        // change. Only a send has an outcome the column has to state.
        guard node.isDirectory else {
            return feedback.answer(onSelect?(node.path) == true ? .landed : .refused, at: index)
        }

        if expanded.contains(node.path) {
            expanded.remove(node.path)
        } else {
            expanded.insert(node.path)
        }
    }

    private func row(at event: NSEvent) -> Int {
        Int(convert(event.locationInWindow, from: nil).y / Self.rowHeight)
    }

    private func redraw(_ row: Int) {
        setNeedsDisplay(NSRect(
            x: 0,
            y: Double(row) * Self.rowHeight,
            width: bounds.width,
            height: Self.rowHeight
        ))
    }

    // MARK: - Pointing

    /// Rebuilt on scroll as well as on layout: the areas cover the rows the clip
    /// view can show, and scrolling changes which rows those are without changing
    /// this view's frame, which is the only thing AppKit calls this for by itself.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let clip = enclosingScrollView?.contentView, scrollObserver == nil else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTrackingAreas() }
        }
    }

    private var scrollObserver: (any NSObjectProtocol)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        for area in RowFeedback.trackingAreas(
            rows: rows.count,
            rowHeight: Self.rowHeight,
            in: self,
            owner: self
        ) { addTrackingArea(area) }
    }

    override func mouseEntered(with event: NSEvent) {
        feedback.hovered = RowFeedback.row(of: event)
    }

    /// Only when the row leaving is the row that was hovered. Areas are adjacent,
    /// so moving down a list delivers the next row's enter before this row's exit,
    /// and clearing unconditionally would drop the hover that had just arrived.
    override func mouseExited(with event: NSEvent) {
        guard feedback.hovered == RowFeedback.row(of: event) else { return }
        feedback.hovered = nil
    }

    override func resetCursorRects() {
        addCursorRect(
            NSRect(x: 0, y: 0, width: bounds.width, height: Double(rows.count) * Self.rowHeight),
            cursor: .pointingHand
        )
    }

    private func nsColor(_ rgb: RGB) -> NSColor {
        NSColor(
            srgbRed: CGFloat(rgb.red),
            green: CGFloat(rgb.green),
            blue: CGFloat(rgb.blue),
            alpha: 1
        )
    }

    private static let font = ChangesRowsView.font

    /// Both surfaces read one set of row metrics, so a row in the tree and a row
    /// in the changes list sit on the same baseline at the same inset when the two
    /// are stacked. The tree used to inset at 10 against everything else's 12,
    /// which put it 2 pt out from the heading directly above it, and it placed its
    /// text by its own constant. Design v3 §8/02 and §8/03.
    private static let rowHeight = ChangesRowsView.rowHeight
    private static let textOrigin = ChangesRowsView.textOrigin
    private static let inset = ChangesRowsView.inset
    private static let indent: Double = 12
    private static let chevronColumn: Double = 14
}
