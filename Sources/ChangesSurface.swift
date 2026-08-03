import AppKit
import GitWorkspace
import PaneChrome

/// The changed files of the focused pane's repository.
///
/// What the footer cannot say. The footer reports `*3 ?1` on one line that must not
/// wrap; this names the three and the one. Neither replaces the other, which is why
/// the footer stands nothing down when this is on screen.
///
/// Scrolls, because a refactor is a hundred changed files and a column that simply
/// stopped drawing at its own bottom edge would hide the rest with nothing on screen
/// to say so. `NSScrollView` and `NSClipView` take no first responder, so the safety
/// argument below survives the scroller.
@MainActor
final class ChangesSurface: NSObject, WorkspaceSurface {
    var view: NSView { scrollView }

    let title = "Changes"

    var theme: PaneTheme = .darkPastel {
        didSet {
            rows.theme = theme
            fill()
        }
    }

    var backgroundOpacity: Double = 1 {
        didSet { fill() }
    }

    /// The column's body, drawn once by the scroll view.
    ///
    /// **Once, not twice.** The rows used to fill their own bounds as well, which
    /// was invisible while the fill was opaque and would be a second 0.85 layer
    /// over the first now that it is not: two composites of the same colour land
    /// at 0.9775 and the column would sit a shade above every pane beside it.
    private func fill() {
        scrollView.backgroundColor = Self.nsColor(theme.background, alpha: backgroundOpacity)
    }

    /// What to draw. Assigning re-sorts, so the caller hands over git's order and
    /// gets the panel's.
    var changes: [RepositoryFileChange] = [] {
        didSet { rows.changes = changes }
    }

    /// True when the focused pane is not in a repository at all.
    ///
    /// Separate from an empty list, because "nothing changed" and "no repository" are
    /// different answers and a blank column says neither.
    var hasRepository = true {
        didSet { rows.hasRepository = hasRepository }
    }

    /// Where the pane is anchored, which the absent state names beneath its
    /// message. The message alone says what this is not; the path says what it is.
    var anchorPath: String? {
        didSet { rows.anchorPath = anchorPath }
    }

    /// How many files are waiting, which is what this list is for. Nothing to count
    /// outside a repository, where the section is answering a different question.
    var headingCount: Int? { hasRepository ? changes.count : nil }

    /// Called with the changed file's path when a row is clicked.
    ///
    /// The same callback the tree has, because a changed file and a file in the
    /// tree do the same thing when clicked. That is what makes the sidebar one
    /// idea rather than two pictures.
    ///
    /// Answers `true` when the path landed on the prompt and `false` when it was
    /// refused, which is the one bit the row needs to know which flash to draw.
    /// `PromptPath.Resolution` already carries that distinction, so the surface
    /// stays as ignorant of quoting as it was. Design v3 §2.3.
    var onSelect: ((RepositoryPath) -> Bool)? {
        get { rows.onSelect }
        set { rows.onSelect = newValue }
    }

    private let scrollView = NSScrollView()
    private let rows = ChangesRowsView()

    override init() {
        super.init()
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = rows
        rows.theme = theme
    }

    static func nsColor(_ rgb: RGB, alpha: Double = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat(rgb.red),
            green: CGFloat(rgb.green),
            blue: CGFloat(rgb.blue),
            alpha: CGFloat(alpha)
        )
    }
}

/// The rows themselves, drawn rather than tabulated.
///
/// **Refuses first responder, and that is not a detail.**
/// `AppTerminalView.performKeyEquivalent` opens with
/// `guard window?.firstResponder === self`, and that is the *window's* first
/// responder. A row here that took focus would disable every ghostty binding in
/// every pane of this window, silently, with nothing on screen to explain it. An
/// `NSTableView` brings a selection that wants the keyboard, and wanting the
/// keyboard is the one thing a view in this window must never do.
@MainActor
final class ChangesRowsView: NSView {
    var theme: PaneTheme = .darkPastel { didSet { needsDisplay = true } }

    var hasRepository = true { didSet { needsDisplay = true } }

    /// Where the pane is anchored, for the absent state to name. Nil while the
    /// anchor is a repository, where it is never drawn.
    var anchorPath: String? { didSet { needsDisplay = true } }

    var changes: [RepositoryFileChange] = [] {
        didSet {
            sorted = changes.inCommitOrder()
            // The list under the pointer is a different list now, so a fade in
            // flight belongs to a row that may not be the same file. Design v3's
            // states are about *this* row answering.
            feedback.reset()
            resize()
            // **The rows the areas cover just changed, and nothing else will say
            // so.** `resize()` only marks a layout pass when the frame actually
            // moves, and a list that grows inside a document view already as tall
            // as its clip does not move it, so the areas stayed as they were built
            // on an empty list: zero of them, for the life of the surface.
            updateTrackingAreas()
            needsDisplay = true
        }
    }

    private var sorted: [RepositoryFileChange] = []

    var onSelect: ((RepositoryPath) -> Bool)?

    private lazy var feedback = RowFeedback { [weak self] row in
        self?.redraw(row)
    }

    /// Sends the row's path, and takes no focus doing it.
    ///
    /// No test on x, unlike the tree: there is nothing else on this row to hit.
    ///
    /// A rename sends ``RepositoryFileChange/path`` and never `originalPath`,
    /// because `path` is where the file is now and a staged rename's original no
    /// longer exists. A deleted file sends its path too: `git checkout -- <path>`
    /// is exactly what the owner is reaching for, and this view asks the
    /// filesystem nothing.
    ///
    /// **Held rather than fired on the way down.** The send happens on mouse up
    /// and only over the row the press began on, which is what makes the press a
    /// state the eye can see and a drag off the row a cancellation rather than an
    /// action. Design v3 §2.3.
    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: event)
        guard sorted.indices.contains(row) else { return }
        feedback.pressed = row
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed = feedback.pressed else { return }
        feedback.pressed = row(at: event) == pressed ? pressed : nil
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = feedback.pressed else { return }
        feedback.pressed = nil
        guard sorted.indices.contains(index), row(at: event) == index else { return }
        // `rawPath` rather than `path`: the latter is the lossy spelling the row
        // draws, and what is being sent here is a name rather than a label.
        feedback.answer(onSelect?(sorted[index].rawPath) == true ? .landed : .refused, at: index)
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
    ///
    /// **The size follows from here too, and that is the fifth instance of the
    /// shape `Diagnostics/clip-layout` was built for.** `layout()` calls `resize()`
    /// and never runs on a live width drag: the host assigns the scroll view's
    /// frame from inside `viewDidLayout`, by which point the window's pass has
    /// already descended past this view, and nothing marks it for layout again
    /// because its own frame is what `resize()` was going to change. So a sidebar
    /// dragged to its 120 pt floor left every row fitting itself to the 260 pt
    /// the column opened at: `RowPath` was handed a budget of 31 characters,
    /// returned whole names it believed fitted, and the clip view cut them with no
    /// ellipsis. The file tree's status glyphs went with them, drawn 240 pt out.
    ///
    /// Both notifications, because only one of them is guaranteed. A clip view's
    /// bounds *size* follows its frame, and AppKit documents the bounds
    /// notification as firing when bounds change independently of the frame, so a
    /// resize may announce itself as one, the other, or both. `resize()` is
    /// guarded on the frame it wants, so hearing it twice costs a comparison.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let clip = enclosingScrollView?.contentView, clipObservers.isEmpty else { return }
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            // `queue: nil`, so the block runs on the posting thread rather than as
            // an operation on the main queue. Both are the main thread, and the
            // difference is when: an enqueued block lands a runloop turn later, so
            // the size would follow the clip one frame behind through a drag, and
            // the pass that just resized the clip would draw once at the old width
            // before the new one arrived.
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
            rows: sorted.count,
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
        // Only over the rows. A pointing hand over the empty half of a short list
        // would promise a click that has nothing to land on.
        addCursorRect(
            NSRect(x: 0, y: 0, width: bounds.width, height: Double(sorted.count) * Self.rowHeight),
            cursor: .pointingHand
        )
    }

    override var acceptsFirstResponder: Bool { false }

    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        resize()
    }

    /// **Sized on every layout pass, not only when the rows change.**
    ///
    /// This is the whole of the sidebar bug found on 2026-07-29 and it took a
    /// trace to see, because every value involved was right: switching the
    /// sidebar on built a fresh surface, `refreshSidebar(of:)` pushed thirteen
    /// changes into it, and the column stayed blank. `resize()` reads the clip
    /// view's width, the clip view has not been laid out when a surface is first
    /// installed, so the width fell to the `1` floor and every row drew into a
    /// document view one point wide. Any command afterwards made the poller
    /// re-assign `changes`, by which time the clip view had a real width, which
    /// is why it looked like the sidebar needed a command to wake up.
    override func layout() {
        super.layout()
        resize()
        // The tracking areas too, and for the same reason: they cover the rows the
        // clip view can show, and a freshly installed surface has a clip view that
        // has not been laid out, so building them once from `updateTrackingAreas`
        // built them against an empty visible rect and there was nothing to enter
        // for the rest of the surface's life.
        updateTrackingAreas()
    }

    /// The document view is exactly as tall as its rows, which is what tells the
    /// scroll view whether there is anything to scroll to.
    ///
    /// The equality guard is what makes calling this from `layout()` safe:
    /// assigning `frame` marks the view for layout again, and an unguarded write
    /// would be a loop rather than a settled size.
    private func resize() {
        let width = max(superview?.bounds.width ?? 0, 1)
        let height = max(Double(sorted.count) * Self.rowHeight, superview?.bounds.height ?? 0)
        let wanted = NSRect(x: 0, y: 0, width: width, height: height)
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
        // No fill of its own: the scroll view behind it is the column's material,
        // and filling here as well would composite it twice.
        guard hasRepository else {
            return SurfaceMessage.drawAbsent(path: anchorPath, in: self, theme: theme)
        }
        guard !sorted.isEmpty else {
            return SurfaceMessage.drawEmpty("no changes", in: self, theme: theme)
        }

        // Only the rows the dirty rect touches, the same reason the file tree does
        // it: a hundred-file refactor is a hundred rows and a scroll must not redraw
        // the ones nobody can see.
        let first = max(0, Int(dirty.minY / Self.rowHeight))
        let last = min(sorted.count - 1, Int(dirty.maxY / Self.rowHeight))
        guard first <= last else { return }

        for index in first ... last {
            draw(sorted[index], atIndex: index)
        }
    }

    private func draw(_ change: RepositoryFileChange, atIndex index: Int) {
        if let fill = feedback.fill(index, in: theme) {
            ChangesSurface.nsColor(fill.colour, alpha: fill.alpha).setFill()
            NSRect(
                x: 0,
                y: Double(index) * Self.rowHeight,
                width: bounds.width,
                height: Self.rowHeight
            ).fill()
        }

        // One origin for both strings. The marker used to draw at `y + 3` and the
        // path at `y + 1`, both top-origin in a flipped view, so the marker sat
        // 2 pt below the path it labels. Design v3 §8/02.
        let y = Double(index) * Self.rowHeight + Self.textOrigin
        let marker = Self.marker(for: change)
        let columns = NSMutableAttributedString()
        for column in [marker.index, marker.worktree] {
            columns.append(NSAttributedString(
                string: column.text,
                attributes: [
                    .font: Self.font,
                    .foregroundColor: column.role.map {
                        ChangesSurface.nsColor(Marker.colour($0, in: theme))
                    } ?? .clear,
                ]
            ))
        }
        columns.draw(at: NSPoint(x: Self.inset, y: y))

        // The last component in the foreground ink and the directory ahead of it
        // faint, so a column of paths reads as a column of file names with context
        // rather than as a column of shared prefixes. Which half gives way when the
        // row is too narrow follows from that, and ``RowPath`` is the rule.
        let x = Self.inset + Self.markerColumn
        let available = max(0, bounds.width - x - Self.inset)
        let fitted = RowPath.fit(change.path, budget: Int(available / Self.advance))

        // A refusal takes the path's ink with it, blended by how far through the
        // fade it is so the text rides the same clock as the fill under it.
        let refusal = feedback.ink(index, in: theme)
        let directoryInk = refusal.map { theme.inkFaint.blended(with: $0.colour, fraction: $0.alpha) }
        let nameInk = refusal.map { theme.foreground.blended(with: $0.colour, fraction: $0.alpha) }

        let line = NSMutableAttributedString()
        if !fitted.directory.isEmpty {
            line.append(NSAttributedString(
                string: fitted.directory,
                attributes: [
                    .font: Self.font,
                    .foregroundColor: ChangesSurface.nsColor(directoryInk ?? theme.inkFaint),
                ]
            ))
        }
        line.append(NSAttributedString(
            string: fitted.name,
            attributes: [
                .font: Self.font,
                .foregroundColor: ChangesSurface.nsColor(nameInk ?? theme.foreground),
            ]
        ))

        // `draw(at:)`, never `draw(in:)`. A rect wraps, `/` is a break opportunity,
        // and the second line falls outside an 18 pt row, so what a rect clipped
        // away was the file name the row exists to show. The width is answered
        // before the string is built rather than by the drawing.
        line.draw(at: NSPoint(x: x, y: y))
    }

    /// The two-column `XY` git itself prints, so the marker is one the owner already
    /// reads in `git status` rather than a vocabulary of baia's own.
    ///
    /// **Each column carries its own ink.** `X` is the index and `Y` is the working
    /// tree, two independent facts, and one colour for the pair threw away the half
    /// that matters: a file staged and since modified prints `MM`, and rendering
    /// both letters as staged said the commit would contain the second `M` when it
    /// will not. Coloured separately the marker teaches itself, left is in the
    /// commit and right is not. Design v3 §2.1.
    ///
    /// An absent column is a space rather than a dot. The font is monospaced, so
    /// position already says which of the two is missing, and a dot is a character
    /// git does not print here.
    private static func marker(for change: RepositoryFileChange) -> Marker {
        switch change.kind {
        case .untracked:
            // Git prints a pair of the same glyph here rather than two states, and
            // `RepositoryFileChange` carries none for an untracked file, so this is
            // the one marker spelled out rather than read off the record.
            Marker(index: .init("?", .untracked), worktree: .init("?", .untracked))
        case .unmerged:
            // The real letters rather than a hardcoded `UU`. Both columns are the
            // conflict, so both are red, but a `DU` is a delete against an update
            // and calling it `UU` is the same class of lie as colouring `MM` once.
            Marker(
                index: .init(change.index.map(\.rawValue) ?? "U", .conflict),
                worktree: .init(change.worktree.map(\.rawValue) ?? "U", .conflict)
            )
        case .ordinary, .renamedOrCopied:
            Marker(
                index: change.index.map { .init($0.rawValue, .staged) } ?? .absent,
                worktree: change.worktree.map { .init($0.rawValue, .unstaged) } ?? .absent
            )
        }
    }

    private struct Marker {
        let index: Column
        let worktree: Column

        struct Column {
            let text: String
            let role: Role?

            init(_ character: Character, _ role: Role) {
                text = String(character)
                self.role = role
            }

            private init(absent: Bool) {
                text = " "
                role = nil
            }

            static let absent = Column(absent: true)
        }

        /// The theme's own vocabulary: see ``PaneChrome/PaneTheme/ChangeMark``,
        /// which is what actually resolves a colour. Kept as a local alias
        /// rather than named directly, so the columns above read as this
        /// surface's own concept.
        typealias Role = PaneTheme.ChangeMark

        static func colour(_ role: Role, in theme: PaneTheme) -> RGB {
            theme.colour(for: role)
        }
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    /// The advance of one character, which is a number only because the font is
    /// monospaced. Every width budget in the sidebar is derived from it.
    ///
    /// Measured rather than written down as 6.62: the constant is what the font
    /// happens to report at size 11, and a font or size change has to move the
    /// budget with it.
    static let advance = ("0" as NSString).size(withAttributes: [.font: font]).width

    /// Where a row's text starts, so that its baseline lands on `rowBaseline`.
    ///
    /// The same rule the footer follows with `PaneStatusBarMetrics.baselineFromTop`:
    /// one baseline for everything on the line, rather than each string placed by
    /// its own idea of centre. Two strings centred independently sit a fraction of
    /// a point apart, which does not read as a difference, it reads as a mistake.
    static let textOrigin = rowBaseline - Double(font.ascender)

    static let rowHeight: Double = 18
    /// Cap-centred in the row: (18 + 7.8) / 2, where 7.8 is the cap height.
    static let rowBaseline: Double = 13
    /// One inset for both surfaces and the heading above them. The tree used to
    /// use 10, so stacked it sat 2 pt out from everything else. Design v3 §8/03.
    static let inset: Double = 12
    private static let markerColumn: Double = 26
}
