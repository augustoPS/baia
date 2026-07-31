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

    /// The tree to draw.
    ///
    /// **A new tree no longer collapses anything.** It used to clear the open set,
    /// on the argument that an expansion set from one repository means nothing in
    /// the next, and that argument is right about repositories and wrong about
    /// trees: a tree also changes when a file is added to the repository already
    /// showing. What the set belongs to is the anchor, so ``anchorPath`` is where
    /// it is now switched, and this assigns the rows and nothing else.
    ///
    /// **An equal tree is still not a different one.** `refreshSidebar(of:)`
    /// assigns on every focus change and every git poll that reports something
    /// new, and a rebuild resets the press feedback and the tracking areas, so the
    /// guard keeps a command run in the pane from doing that several times a
    /// minute. Caught on 2026-07-29, in the first live check of the path picker.
    var tree: [FileTreeNode] = [] {
        didSet {
            guard tree != oldValue else { return }
            rows.tree = tree
        }
    }

    /// Whether there is a root to list at all.
    ///
    /// Not "is this a repository", which is what it used to be and what the name
    /// still said after a plain anchor gained a tree of its own. Files lists a
    /// repository through `git ls-files` and a plain directory through a walk, so
    /// the only state with nothing to draw is a pane with no anchor.
    var hasRoot = true {
        didSet { rows.hasRoot = hasRoot }
    }

    /// Where the pane is anchored, which the absent state names beneath its
    /// message. The message alone says what this is not; the path says what it is.
    ///
    /// **Also the key the open directories are remembered under**, because the
    /// anchor is what an expansion set means anything relative to: every path in
    /// the set is a path under this one. Moving the sidebar to another repository
    /// puts the current set away and brings back that repository's, so a glance at
    /// a second pane and back returns the tree the way it was left.
    ///
    /// The order this arrives in relative to ``tree`` does not matter. Both land
    /// in one pass of `refreshSidebar(of:)` before anything is drawn, and whichever
    /// is second leaves the rows correct: the set is put away under the anchor it
    /// was open in either way, since ``tree`` no longer touches it.
    var anchorPath: String? {
        didSet {
            rows.anchorPath = anchorPath
            rows.expanded = expansions.retarget(to: anchorPath, keeping: rows.expanded)
        }
    }

    /// What each anchor was left showing. Session-scoped by construction: it lives
    /// on the surface, and the surface dies with its window. Carrying it across a
    /// relaunch would mean a field in `SessionSnapshot` and a rule for pruning it,
    /// which is a larger question than the loss this fixes.
    private var expansions = FileTreeExpansions()

    /// The same change list the Changes section is given, which the tree reduces to
    /// one glyph per row. The two are not alternatives: a list ordered for
    /// `git commit` answers a question a tree ordered by path cannot, and a tree
    /// says where in the repository the work is.
    var changes: [RepositoryFileChange] = [] {
        didSet {
            guard changes != oldValue else { return }
            rows.marks = FileChangeMarks(changes)
        }
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

    var hasRoot = true { didSet { needsDisplay = true } }

    /// Where the pane is anchored, for the absent state to name. Nil while the
    /// anchor is a repository, where it is never drawn.
    var anchorPath: String? { didSet { needsDisplay = true } }

    /// What each path has to say for itself, files and the directories above them.
    /// Empty outside a repository and while nothing has changed.
    var marks = FileChangeMarks([]) {
        didSet {
            guard marks != oldValue else { return }
            needsDisplay = true
        }
    }

    var tree: [FileTreeNode] = [] { didSet { rebuild() } }

    /// Paths of the directories that are open.
    ///
    /// Paths rather than node references, so the set survives the tree being read
    /// again: a poll that returns an equal tree must not collapse what the owner
    /// opened, and node identity would not survive it.
    ///
    /// Guarded on equality like `tree` and `marks`, and for the same reason.
    /// `FilesSurface` re-asserts this set every time the sidebar is repointed,
    /// which is several times a second while someone arrows across a grid, and a
    /// rebuild throws away the press feedback and the tracking areas.
    var expanded: Set<String> = [] {
        didSet {
            guard expanded != oldValue else { return }
            rebuild()
        }
    }

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
        // A frame change does not repaint on its own, and the empty and absent
        // states are drawn centred in the visible rect rather than at a row
        // origin. So a column the owner narrowed kept the centring it had before,
        // and the message ran on under the divider: at the 120 pt floor "not a
        // repository" showed as "not a r". The rows themselves never exposed it,
        // because a row draws from a left inset that does not move.
        //
        // Fourth of the same shape, after the document view drawn into one point,
        // the tree that could not be hit, and the tracking areas that covered
        // nothing. Each was a view whose size changed without the thing built
        // from that size being rebuilt.
        needsDisplay = true
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
        guard hasRoot else {
            return SurfaceMessage.drawAbsent(path: anchorPath, in: self, theme: theme)
        }
        guard !rows.isEmpty else {
            return SurfaceMessage.drawEmpty("no files", in: self, theme: theme)
        }

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

        drawGuides(of: row, atIndex: index, y: y)

        if row.node.isDirectory {
            let chevron = expanded.contains(row.node.path) ? "▾" : "▸"
            NSAttributedString(
                string: chevron,
                attributes: [.font: Self.font, .foregroundColor: nsColor(theme.inkFaint)]
            ).draw(at: NSPoint(x: x, y: y + Self.textOrigin))
        }

        // The trailing status, drawn before the name so the name knows what room is
        // left. Design v3 §5.2: leading is where indentation lives, so a status
        // column on that side would either push every name right by a quarter of
        // the depth budget or collide with the guides. Trailing costs the name
        // 14 pt at any depth and never moves as the tree expands.
        let mark = marks[row.node.path]
        if let mark {
            NSAttributedString(
                string: String(mark.glyph),
                attributes: [.font: Self.font, .foregroundColor: nsColor(colour(of: mark))]
            ).draw(at: NSPoint(
                x: bounds.width - Self.inset - Self.statusColumn,
                y: y + Self.textOrigin
            ))
        }

        // A directory keeps its trailing slash whatever else it loses. A collapsed
        // directory and a file with no extension are otherwise the same row with a
        // chevron that may or may not be there, and the slash is what every shell
        // prints for the same reason.
        let nameX = x + Self.chevronColumn
        let trailing = Self.inset + (mark == nil ? 0 : Self.statusColumn)
        let available = max(0, bounds.width - nameX - trailing)
        let slash = row.node.isDirectory ? "/" : ""
        let budget = Int(available / ChangesRowsView.advance) - slash.count
        let name = RowPath.fit(row.node.name, budget: max(0, budget)).name + slash

        let rest = row.node.isDirectory ? theme.inkContext : theme.foreground
        let refusal = feedback.ink(index, in: theme)
        NSAttributedString(
            string: name,
            attributes: [
                .font: Self.font,
                .foregroundColor: nsColor(
                    refusal.map { rest.blended(with: $0.colour, fraction: $0.alpha) } ?? rest
                ),
            ]
        ).draw(at: NSPoint(x: nameX, y: y + Self.textOrigin))
    }

    /// One vertical line per ancestor level, so depth is read rather than counted.
    ///
    /// Design v3 §5.1. Drawn in ``PaneTheme/divider``, the same colour and weight
    /// as the line between two panes, because each nesting level is literally a
    /// plank and that is the app's own name for itself.
    ///
    /// The hovered directory's own level is drawn in the focus ink across its
    /// descendants and nowhere else, so the extent of what a click is about to
    /// collapse is visible before it collapses. §5.3. One guide and never the
    /// ancestors: the row fill already says which row.
    private func drawGuides(of row: Row, atIndex index: Int, y: Double) {
        guard row.depth > 0 else { return }
        for depth in 0 ..< row.depth {
            let lit = hoverGuide.map { $0.depth == depth && $0.rows.contains(index) } ?? false
            nsColor(lit ? theme.inkFocus : theme.divider).setFill()
            NSRect(
                x: Self.inset + Double(depth) * Self.indent + Self.guideInset,
                y: y,
                width: 1,
                height: Self.rowHeight
            ).fill()
        }
    }

    private func colour(of mark: FileChangeMark) -> RGB {
        switch mark {
        case .conflict: theme.alert
        case .unstaged: theme.warn
        case .staged: theme.staged
        case .untracked: theme.inkFaint
        }
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
    /// Both notifications, and `resize()` alongside the areas. See
    /// ``ChangesRowsView/viewDidMoveToWindow()``: `layout()` does not run on a live
    /// width drag, so without this the tree fitted every name to the width the
    /// column opened at and drew its status glyphs past the divider.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let clip = enclosingScrollView?.contentView, clipObservers.isEmpty else { return }
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            // `queue: nil` for the reason ``ChangesRowsView`` records: an enqueued
            // block follows the clip a runloop turn late.
            clipObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: clip,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.resize()
                    self?.updateTrackingAreas()
                }
            })
        }
    }

    private var clipObservers: [any NSObjectProtocol] = []

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
        updateHoverGuide()
    }

    /// Only when the row leaving is the row that was hovered. Areas are adjacent,
    /// so moving down a list delivers the next row's enter before this row's exit,
    /// and clearing unconditionally would drop the hover that had just arrived.
    override func mouseExited(with event: NSEvent) {
        guard feedback.hovered == RowFeedback.row(of: event) else { return }
        feedback.hovered = nil
        updateHoverGuide()
    }

    /// The level and the span the hovered directory owns, or nil for a file, a
    /// collapsed directory, or an empty one: there is no extent to show for a row
    /// with nothing under it.
    private var hoverGuide: (depth: Int, rows: Range<Int>)?

    private func updateHoverGuide() {
        let previous = hoverGuide
        hoverGuide = guide(for: feedback.hovered)
        guard previous?.depth != hoverGuide?.depth || previous?.rows != hoverGuide?.rows else {
            return
        }
        for span in [previous?.rows, hoverGuide?.rows].compactMap(\.self) {
            setNeedsDisplay(NSRect(
                x: 0,
                y: Double(span.lowerBound) * Self.rowHeight,
                width: bounds.width,
                height: Double(span.count) * Self.rowHeight
            ))
        }
    }

    private func guide(for index: Int?) -> (depth: Int, rows: Range<Int>)? {
        guard let index, rows.indices.contains(index) else { return nil }
        let row = rows[index]
        guard row.node.isDirectory, expanded.contains(row.node.path) else { return nil }
        var end = index + 1
        while end < rows.count, rows[end].depth > row.depth { end += 1 }
        guard end > index + 1 else { return nil }
        return (depth: row.depth, rows: (index + 1) ..< end)
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
    /// One indent step, so a child's name lands under its parent's chevron. It was
    /// 14, which put every name a fraction off the level above it. Design v3 §5.1.
    private static let chevronColumn: Double = 12
    /// Where the guide sits inside its level, chosen so the line runs under the
    /// middle of the chevron above it rather than against the name.
    private static let guideInset: Double = 5
    /// One glyph and the gap before it, trailing. §5.2.
    private static let statusColumn: Double = 14
}
