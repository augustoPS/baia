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

    /// Flat or glass, per Task 5. See ``WorkspaceSurface/resolvedChrome``.
    var resolvedChrome: ResolvedChrome = .flat {
        didSet {
            guard resolvedChrome != oldValue else { return }
            fill()
        }
    }

    /// The column's body, drawn once by the scroll view and never by the rows on
    /// top of it. Filling in both places would composite the same colour twice,
    /// which was invisible while the fill was opaque and is a shade too light now
    /// that it has an alpha.
    ///
    /// The flat/glass branch is the sidebar's own rather than a shape mirrored
    /// from a neighbour: the 2026-08-12 ruling left one surface in this column.
    /// `SidebarHost` owns a real `NSGlassEffectView` behind this surface's view,
    /// and an opaque scroll view background between that glass and the window it
    /// samples would defeat it, so glass draws no fill at all rather than the
    /// same fill flat uses.
    private func fill() {
        switch resolvedChrome {
        case .flat:
            scrollView.drawsBackground = true
            scrollView.backgroundColor = SidebarRowMetrics.nsColor(theme.background, alpha: backgroundOpacity)
        case .glass:
            scrollView.drawsBackground = false
        }
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

    /// What each anchor was left showing.
    private var expansions = FileTreeExpansions()

    /// The same, in the shape the session file carries, and the two directions a
    /// relaunch needs it in.
    ///
    /// **The getter takes the live set from the rows**, which is where an
    /// expansion actually lands: `FileTreeExpansions` is only handed a set when the
    /// surface is repointed, so the anchor on screen at quit is the one it has
    /// never been told about.
    ///
    /// **The setter assigns back into the rows** rather than only filling the map.
    /// A window's sidebar is refreshed as it opens and the session's expansions are
    /// applied once every window exists, so by the time this is set the surface has
    /// usually already been pointed at an anchor and shown it empty. Seeding
    /// without redisplaying is how a persisted field gets written, read back, and
    /// changes nothing on screen.
    var fileTreeExpansions: [String: [String]] {
        get { expansions.recording(rows.expanded) }
        set { rows.expanded = expansions.seed(newValue, showing: rows.expanded) }
    }

    /// The pane's changed files, which the tree reduces to one glyph per row.
    ///
    /// **The tree's own annotation on a row it was already drawing, and not a
    /// list.** The sidebar's CHANGES section took the same value and drew a row
    /// per changed file, and the owner's 2026-08-12 ruling removed it as a second
    /// copy of the capsule's changes card. This is what that ruling explicitly
    /// keeps: a mark beside a name says the file in front of you is dirty, which
    /// is a fact about a row rather than an enumeration of the repository.
    var changes: [RepositoryFileChange] = [] {
        didSet {
            guard changes != oldValue else { return }
            rows.marks = FileChangeMarks(changes)
        }
    }

    /// Called with a repository-relative path when a row's name is clicked.
    ///
    /// The surface knows nothing about what happens next. Whether that path is
    /// quoted, sent relative or absolute, or refused outright is `PromptPath`'s
    /// business, and where it goes is the owner's.
    /// Answers `true` when the path landed on the prompt and `false` when it was
    /// refused, which is the one bit the row needs to know which flash to draw.
    /// `PromptPath.Resolution` already carries that distinction, so the surface
    /// stays as ignorant of quoting as it was. Design v3 §2.3.
    var onSelect: ((RepositoryPath) -> Bool)? {
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
    var expanded: Set<RepositoryPath> = [] {
        didSet {
            guard expanded != oldValue else { return }
            rebuild()
        }
    }

    override var acceptsFirstResponder: Bool { false }

    override var isFlipped: Bool { true }

    private var rows: [FileTree.VisibleRow] = []

    private func rebuild() {
        // A fade in flight belongs to the row that was at that index, and after a
        // rebuild that index is a different file.
        feedback.reset()
        rows = FileTree.visibleRows(of: tree, expanded: expanded)
        resize()
        // A frame that does not move marks no layout
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
        // Areas built against an unlaid clip view
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

    private func draw(_ row: FileTree.VisibleRow, atIndex index: Int) {
        let y = Double(index) * Self.rowHeight
        let x = Self.inset + Double(row.depth) * Self.indent

        // Radius 6, design v5 §5: the row-selection surface the palette rows
        // draw too, so a selected row reads the same wherever it is.
        if let fill = feedback.fill(index, in: theme) {
            SidebarRowMetrics.nsColor(fill.colour, alpha: fill.alpha).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight),
                xRadius: SidebarRowMetrics.rowRadius,
                yRadius: SidebarRowMetrics.rowRadius
            ).fill()
        }

        drawGuides(of: row, atIndex: index, y: y)

        if row.node.isDirectory {
            // 8pt tertiary, design v5 §5: was the row's own 11pt body size,
            // which read as text rather than as a disclosure control.
            let chevron = expanded.contains(row.node.rawPath) ? "▾" : "▸"
            NSAttributedString(
                string: chevron,
                attributes: [.font: Self.disclosureFont, .foregroundColor: nsColor(theme.inkFaint)]
            ).draw(at: NSPoint(x: x, y: y + Self.disclosureTextOrigin))
        }

        // The trailing status, drawn before the name so the name knows what room is
        // left. Design v3 §5.2: leading is where indentation lives, so a status
        // column on that side would either push every name right by a quarter of
        // the depth budget or collide with the guides. Trailing costs the name
        // 14 pt at any depth and never moves as the tree expands.
        //
        // Design v5 §5 collapses ``FileChangeMark/staged``/`.unstaged` to one
        // trailing `•`, the same vocabulary the footer's `*` already spends on a
        // dirty tree, so the two read as one signal rather than two dot-shaped
        // ones: caution ink for the ordinary case, ok-green only when a
        // collapsed directory's rolled-up mark says nothing under it is still
        // owed. `.untracked` keeps its own `?`, a fact ``FileChangeMark`` already
        // distinguishes from a modification and one the dot's binary caution/
        // ok-green vocabulary cannot carry; `.conflict` keeps `!` in attention
        // ink outright, the state design v5 nowhere asks this column to quiet.
        let mark = marks[row.node.rawPath]
        if let mark {
            let (glyph, ink) = Self.trailingGlyph(for: mark, in: theme)
            NSAttributedString(
                string: String(glyph),
                attributes: [.font: Self.font, .foregroundColor: nsColor(ink)]
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
        let budget = Int(available / SidebarRowMetrics.advance) - slash.count
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

    /// The glyph and ink design v5 §5 draws for one tree mark.
    private static func trailingGlyph(for mark: FileChangeMark, in theme: PaneTheme) -> (Character, RGB) {
        switch mark {
        case .staged: ("•", theme.colour(for: .added))
        case .unstaged: ("•", theme.colour(for: .unstaged))
        case .untracked: ("?", theme.colour(for: .untracked))
        case .conflict: ("!", theme.alert)
        }
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
    private func drawGuides(of row: FileTree.VisibleRow, atIndex index: Int, y: Double) {
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

    var onSelect: ((RepositoryPath) -> Bool)?

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
            // `rawPath` rather than `path`: the latter is the lossy spelling the
            // row draws, and what is being sent here is a name rather than a label.
            return feedback.answer(onSelect?(node.rawPath) == true ? .landed : .refused, at: index)
        }

        // `rawPath` for the same reason the send above uses it: keyed on the drawn
        // spelling, two sibling directories that draw alike shared one entry and
        // one chevron moved both.
        if expanded.contains(node.rawPath) {
            expanded.remove(node.rawPath)
        } else {
            expanded.insert(node.rawPath)
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
    /// `layout()` does not run on a live width drag, so without this the tree
    /// fitted every name to the width the column opened at and drew its status
    /// glyphs past the divider.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let clip = enclosingScrollView?.contentView, clipObservers.isEmpty else { return }
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            // `queue: nil` rather than the main queue: an enqueued block follows
            // the clip a runloop turn late, so a drag would draw one frame behind.
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
        hoverGuide = FileTree.descendants(ofRowAt: feedback.hovered, in: rows)
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

    private static let font = SidebarRowMetrics.font

    /// Design v5 §5: 8pt, down from the row's own 11pt body size. A disclosure
    /// glyph at body size reads as a character in the name; at 8pt it reads as
    /// the control it is.
    private static let disclosureFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
    /// The same cap-centring rule ``SidebarRowMetrics/textOrigin`` documents,
    /// worked out for ``disclosureFont`` rather than ``font``: two glyphs of
    /// different sizes centred by their own idea of middle sit off the shared
    /// baseline by a fraction of a point, which reads as a mistake.
    private static let disclosureTextOrigin = SidebarRowMetrics.rowBaseline - Double(disclosureFont.ascender)

    /// Both surfaces read one set of row metrics, so a row in the tree and a row
    /// in the changes list sit on the same baseline at the same inset when the two
    /// are stacked. The tree used to inset at 10 against everything else's 12,
    /// which put it 2 pt out from the heading directly above it, and it placed its
    /// text by its own constant. Design v3 §8/02 and §8/03.
    private static let rowHeight = SidebarRowMetrics.rowHeight
    private static let textOrigin = SidebarRowMetrics.textOrigin
    private static let inset = SidebarRowMetrics.inset
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
