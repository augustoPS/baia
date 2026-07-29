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
    var onSelect: ((String) -> Bool)? {
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

    var changes: [RepositoryFileChange] = [] {
        didSet {
            sorted = Self.sort(changes)
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

    var onSelect: ((String) -> Bool)?

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
        feedback.answer(onSelect?(sorted[index].path) == true ? .landed : .refused, at: index)
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
    }

    override func draw(_ dirty: NSRect) {
        // No fill of its own: the scroll view behind it is the column's material,
        // and filling here as well would composite it twice.
        guard hasRepository else { return draw(message: "not a repository") }
        guard !sorted.isEmpty else { return draw(message: "no changes") }

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

    private func draw(message: String) {
        NSAttributedString(
            string: message,
            attributes: [
                .font: Self.font,
                .foregroundColor: ChangesSurface.nsColor(theme.inkFaint),
            ]
        ).draw(at: NSPoint(x: Self.inset, y: Self.textOrigin))
    }

    /// Conflicts first, then staged, then unstaged, then untracked, and by path
    /// within each group.
    ///
    /// The order is what a `git commit` needs answered, in the order it needs it: a
    /// conflict blocks the commit, a staged change is going into it, an unstaged one
    /// is not, and an untracked file is the one most easily forgotten. Git's own
    /// order is by path across all of them, which buries a conflict among fifty
    /// modified files.
    private static func sort(_ changes: [RepositoryFileChange]) -> [RepositoryFileChange] {
        changes.sorted { left, right in
            let leftRank = rank(left)
            let rightRank = rank(right)
            return leftRank == rightRank ? left.path < right.path : leftRank < rightRank
        }
    }

    private static func rank(_ change: RepositoryFileChange) -> Int {
        switch change.kind {
        case .unmerged: 0
        case .untracked: 3
        case .ordinary, .renamedOrCopied: change.index != nil ? 1 : 2
        }
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

        enum Role { case staged, unstaged, untracked, conflict }

        /// Borrowed from the footer's own vocabulary rather than invented: the same
        /// colours already mean the same things one line below.
        static func colour(_ role: Role, in theme: PaneTheme) -> RGB {
            switch role {
            // Not `ok`, whose own documentation says it is never used for text.
            // `staged` is that green given `warn`'s construction, so the pair a
            // reader has to tell apart is one vocabulary rather than two.
            case .staged: theme.staged
            case .unstaged: theme.warn
            case .untracked: theme.inkFaint
            case .conflict: theme.alert
            }
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
