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

    // `title` was "Files" here until the FILES ruling (2026-08-12, option C),
    // and the heading it captioned is what retired. The column draws no title of
    // its own now: the tree runs to the top of the content region, which is what
    // makes the panel read as one surface from the traffic lights down.

    var theme: PaneTheme = .darkPastel {
        didSet {
            rows.theme = theme
            offer.theme = theme
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

    /// Where this tree's rows came from, which is the one thing the column needs
    /// to know that a row count cannot tell it.
    ///
    /// **This replaced a `hasRoot` boolean on the owner's 2026-08-12 ruling about
    /// where the `git init` offer belongs, and the replacement is the whole fix.**
    /// That boolean was assigned `anchor != nil`, and a plain non-repository
    /// directory resolves an anchor perfectly well, so it answered `true` for a
    /// walked tree and the no-repository state fired only when the anchor could
    /// not resolve at all — a working directory deleted underneath the shell.
    /// The offer was therefore correct and nearly unreachable, and it was missing
    /// from the case the ruling was about.
    ///
    /// The question has three answers and the boolean had two, which is why one
    /// more flag beside it would have been the wrong shape: a surface holding
    /// `hasRoot` and `isRepository` can be set to a combination that means
    /// nothing (no root, but a repository), and every reader would then have to
    /// know which of the four pairs are real. Three cases can only ever be in one
    /// of the three states the column actually has.
    ///
    /// Nothing here is a new fact. ``Listing`` is `Anchor.Kind` plus the no-anchor
    /// case, which is exactly what `refreshSidebar(of:)` already branches on to
    /// decide between `git ls-files` and a directory walk. The surface is told the
    /// same thing that call site already knows rather than re-deriving it, and it
    /// is spelled here rather than imported so this file keeps its package list.
    enum Listing: Equatable {
        /// A repository, listed by git. No offer: it is already one.
        case repository
        /// A plain directory, walked. Its rows are real files and it gets the
        /// offer, which is the ruling.
        case directory
        /// No anchor at all, so there is nothing to list and nothing to walk.
        /// The absent state, which is the only one that draws a message instead
        /// of rows.
        case absent
    }

    var listing: Listing = .repository {
        didSet {
            rows.listing = listing
            guard listing != oldValue else { return }
            layOutOffer()
        }
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

    /// Called when the no-repository state's action is clicked.
    ///
    /// The owner's 2026-08-12 ruling, option E: kero offers Initialize Repository
    /// rather than naming a dead end, so this state stops being one. What the
    /// handler does with it is the app's business and deliberately not this
    /// surface's — the same split ``onSelect`` already has, where the column
    /// knows a row was clicked and `PromptPath` decides what may be sent.
    ///
    /// The "not a repository" and "no changes" distinction design v3 made is
    /// untouched: this action belongs to the absent state alone, and the empty
    /// state keeps its own message in its own ink with nothing added.
    var onInitialise: (() -> Void)? {
        get { rows.onInitialise }
        set { rows.onInitialise = newValue }
    }

    private let scrollView = NSScrollView()
    private let rows = FileTreeRowsView()
    private let offer = InitOfferView()

    override init() {
        super.init()
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = rows
        rows.theme = theme

        // **A floating subview, which is what makes the offer survive scrolling
        // without any of the tree's arithmetic moving.**
        //
        // The offer sits over a *walked tree*, so unlike the absent state it has
        // rows above it, and a control that scrolled away with them would be
        // reachable only by scrolling to the end of a directory of any size. The
        // two placements that do not scroll are a floating subview and a sibling
        // of the scroll view, and the sibling loses: `SidebarHost.layoutSections`
        // frames `surface.view` directly, so a container would change what
        // ``view`` is, and `Diagnostics/clip-layout` reads that view as an
        // `NSScrollView` to drive the tree. This keeps the surface's shape
        // exactly as it was.
        //
        // The other rejected placement is a last row in the list. Beyond
        // scrolling away, a row-shaped action in a list of files is the one thing
        // the ruling forbids: it would be pressed by someone reaching for a file.
        scrollView.addFloatingSubview(offer, for: .vertical)
        offer.onPress = { [weak self] in self?.rows.onInitialise?() }
        layOutOffer()

        // **The offer's rect has to follow the column, and nothing else here
        // delivers a layout pass.** `FilesSurface` is an `NSObject` rather than a
        // view, so `SidebarHost` reframing `surface.view` on a divider drag or a
        // window resize reaches the scroll view and never this object. Without
        // this the button would keep the rect the column opened at, which is the
        // derived-from-a-stale-size shape `Diagnostics/clip-layout` exists for,
        // and here it is both axes: an x that is no longer against the trailing
        // edge *and* a bottom edge that is no longer the bottom. A floating pill
        // makes this worse rather than better than the strip did: a full-width
        // strip at a stale width was merely too short, while a pill pinned to a
        // trailing edge that moved is a control sitting in the middle of the
        // column or off it entirely.
        //
        // The scroll view's own frame and not the clip's. The clip is what
        // `FileTreeRowsView` watches, because what the rows care about is the
        // region they are seen through; what this cares about is the surface's
        // outer rect, since ``layOutOffer()`` measures the bottom from
        // `scrollView.bounds`.
        scrollView.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layOutOffer() }
        }
    }

    private var frameObserver: (any NSObjectProtocol)?

    /// Floats the offer at the bottom of the column, sized to its caption, and
    /// tells the rows how much air to leave under the last one.
    ///
    /// **`NSScrollView` is flipped, which is why the bottom is `height - …`
    /// and not `0`.** Measured rather than assumed: `isFlipped` reports true, and
    /// a strip framed at `y: 0` converted to the *top* of the window. It drew
    /// there, over the first rows, which is exactly the "drawn in one place"
    /// failure this whole feature is written against, and only a live check
    /// caught it.
    ///
    /// **`contentInsets` was the first mechanism here and it does nothing**, also
    /// measured: with the scroll view configured the way this surface configures
    /// it, setting `contentInsets.bottom` left `contentSize`, the clip's frame and
    /// its bounds all at full height, so the rows would have sized themselves
    /// under the strip and the last file in a short directory would have sat
    /// behind it. ``FileTreeRowsView/reservedBottom`` is the mechanism that works:
    /// the rows view already computes its own minimum height from the clip, and
    /// this is the one number that computation was missing.
    ///
    /// **The rows still reserve, and the ruling is what changed about it.** The
    /// footer reserved its own full height because it was a plane the list ended
    /// above. A floating button reserves for a different reason and a smaller
    /// amount: nothing is ended, but the last row of a long directory would come
    /// to rest under the pill, and a file the owner can see and cannot read is
    /// worse than one scrolled past. Letting it float truly free was the
    /// alternative and it loses on the case that motivated the reservation in the
    /// first place — a directory of any length, scrolled to the end, where the
    /// occluded row is the *last* one and there is nothing below it to scroll up
    /// into view. So the reservation stays and shrinks to the pill's own
    /// footprint plus the air under it (``InitOfferView/reserved``), where the
    /// footer took a full row height plus a rule. What that buys is the whole
    /// visible difference: the tree fills the column, its last row clears the
    /// pill by the same margin the pill clears the column's edge, and the button
    /// sits over the tree's own plane rather than over a plane of its own.
    ///
    /// Trailing rather than leading. A pill at the leading edge starts where every
    /// row's text starts and reads as an odd row; against the trailing edge it is
    /// off the text column entirely, which is where nothing in this list ever
    /// begins.
    ///
    /// **Too narrow now hides the view rather than emptying it.** The strip spanned
    /// the column and dropped its caption below `SidebarHost.minimumWidth`; the
    /// pill is *sized from* that caption, so the same condition is a pill that
    /// cannot fit between the margins, and what it leaves behind is nothing at all
    /// rather than a blank capsule floating over the files. Same threshold, same
    /// reason, and one less thing drawn that cannot be identified. The offer
    /// returns intact when the column widens, because nothing here is remembered.
    private func layOutOffer() {
        let wanted = offer.fittingWidth()
        let available = scrollView.bounds.width - InitOfferView.margin * 2
        let showing = listing == .directory && wanted <= available
        offer.isHidden = !showing
        // Reserved on the listing alone and not on `showing`: a column narrowed
        // past the caption hides the button, and the air it leaves behind is the
        // air the tree already had. Keying the reservation on visibility would
        // reflow every row in the column on a divider drag across the threshold.
        rows.reservedBottom = listing == .directory ? InitOfferView.reserved : 0
        guard showing else { return }
        offer.frame = NSRect(
            x: scrollView.bounds.width - InitOfferView.margin - wanted,
            y: scrollView.bounds.height - InitOfferView.margin - InitOfferView.height,
            width: wanted,
            height: InitOfferView.height
        )
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

    /// Where the rows came from. See ``FilesSurface/Listing``: the rows view reads
    /// it only to tell the absent state from a list, and the offer that keys on
    /// ``FilesSurface/Listing/directory`` is a button floating outside this view.
    var listing: FilesSurface.Listing = .repository { didSet { needsDisplay = true } }

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

    /// How much of the bottom of the column the last row has to clear, which is
    /// ``InitOfferView/reserved`` on a walked directory and 0 everywhere else.
    ///
    /// **The floor below is the whole reason this exists.** A tree shorter than
    /// its column is stretched to the column's full height so the empty region
    /// below the last row still belongs to this view, and the offer floats over
    /// exactly that region. Without this the last file of a three-file directory
    /// would be laid out under the button: drawn behind it, and still hit-testable
    /// through it. `contentInsets` was tried for this first and measured to
    /// change nothing (see ``FilesSurface/layOutOffer()``), so the number is
    /// carried here, where the height is actually decided.
    ///
    /// The number shrank when the offer stopped being a footer: the pill's own
    /// footprint and its margin, rather than a full row and the rule that used to
    /// sit above it. The *mechanism* had to grow, and that was found live rather
    /// than reasoned — see ``resize()``. A footer's reservation only ever had to
    /// hold a short tree off the bottom, because the strip was opaque and a long
    /// tree scrolling under it showed nothing. The pill is floated over a list
    /// that runs full height, so the long tree is exactly where occlusion shows,
    /// and the reservation has to reach the document's height and not only its
    /// floor.
    var reservedBottom: Double = 0 {
        didSet {
            guard reservedBottom != oldValue else { return }
            resize()
        }
    }

    /// The equality guard is what makes calling this from `layout()` safe:
    /// assigning `frame` marks the view for layout again.
    ///
    /// **The reservation is added to the rows and not only to the floor**, and
    /// the difference is the whole of what the live check caught on 2026-08-12.
    /// The first version of this subtracted the reservation from the clip's
    /// height to get a floor and stopped there, which is correct for a tree
    /// *shorter* than its column and does nothing at all for one longer than it:
    /// past that point `rows.count * rowHeight` wins the `max`, so a 60-file
    /// directory scrolled to its end put the last row under the button with the
    /// name reading through the caption. That is the exact occlusion the
    /// reservation exists to prevent, surviving in the one case that motivated
    /// it, because the number was spent on the wrong term.
    ///
    /// So the rows carry it instead: the document view is as tall as its rows
    /// plus the air the button needs, which is what lets the last row scroll
    /// clear of it. The clip's own height stays the other term of the `max` and
    /// keeps its old meaning unreduced — a tree shorter than its column is still
    /// stretched to the full column, so the empty region below the last row
    /// belongs to this view and the button floats over this view's own plane
    /// rather than over the scroll view's background. Subtracting the
    /// reservation from *that* term was the first repair attempted here and it
    /// is wrong in the opposite direction: it shrinks a short tree's document
    /// below its clip, which un-owns the very region the button sits in.
    private func resize() {
        let clip = superview?.bounds.height ?? 0
        let wanted = NSRect(
            x: 0,
            y: 0,
            width: max(superview?.bounds.width ?? 0, 1),
            height: max(Double(rows.count) * Self.rowHeight + reservedBottom, clip)
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
        guard listing != .absent else {
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
        // **A file draws its status LETTER and a directory draws the rolled-up
        // dot, which is the owner's option B ruling (2026-08-12) and the answer
        // to what happens to the old mark.** The ruling gives a row the git
        // status letters, in the same vocabulary the capsule's changes card
        // draws — ``RowStatusLetter``, read from ``FileChangeMarks/letter(for:)``
        // so the letters are assembled once and drawn on two surfaces rather
        // than derived a second time here.
        //
        // The dot did not simply die, and it did not stay beside the letter
        // either. Two marks on one file row saying the same thing is the
        // duplication this whole line of rulings has been removing — the CHANGES
        // section against the capsule's card, the session header against the
        // window title, the action row against the menu — so on a *file* the
        // letter replaces the dot outright: `M` says everything `•` said and
        // says which kind of change it is. On a *directory* the letter is not
        // available and would be a lie if it were (see
        // ``FileChangeMarks/letters``), so the rollup keeps the column: a
        // collapsed `Sources/` still answers for what is under it, which is the
        // one thing the tree can say that the card cannot.
        //
        // What survives from design v5 §5 is therefore the directory half of it:
        // ``FileChangeMark/staged``/`.unstaged` collapse to one `•` in the
        // footer's own caution/ok-green vocabulary, `.untracked` keeps `?`, and
        // `.conflict` keeps `!` in attention ink. A conflicted *file* now draws
        // `!` through ``RowStatusLetter/glyph``, which is the same character in
        // the same ink, so the two vocabularies agree where they overlap rather
        // than merely coexisting.
        let mark = marks[row.node.rawPath]
        if let mark {
            let (glyph, ink) = Self.trailingGlyph(
                for: mark,
                letter: row.node.isDirectory ? nil : marks.letter(for: row.node.rawPath),
                in: theme
            )
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

    /// What one row draws in its trailing column: the file's own status letter
    /// where there is one, and the rolled-up mark where there is not.
    ///
    /// **The ink is the mark's either way, and that is deliberate.** A letter
    /// says which kind of change and the ink says how much to care, and
    /// ``PaneChrome/PaneTheme/colour(for:)`` is already the one policy the card
    /// and this column share — so an `M` on an unstaged file is `warn` and an `M`
    /// on a staged one is `staged`, the same two colours the dot spent, carrying
    /// a distinction the letter alone cannot. Grading the letter off
    /// ``RowStatusLetter`` instead would need a second colour policy for a
    /// vocabulary that has no urgency in it.
    ///
    /// `nil` for a directory, whose rollup has no honest letter (option B,
    /// 2026-08-12).
    private static func trailingGlyph(
        for mark: FileChangeMark,
        letter: RowStatusLetter?,
        in theme: PaneTheme
    ) -> (Character, RGB) {
        let ink: RGB = switch mark {
        case .staged: theme.colour(for: .added)
        case .unstaged: theme.colour(for: .unstaged)
        case .untracked: theme.colour(for: .untracked)
        case .conflict: theme.alert
        }
        // The directory rollup, design v5 §5 unchanged: staged and unstaged
        // collapse to one `•`, untracked keeps `?`, conflict keeps `!`.
        let rollup: Character = switch mark {
        case .staged, .unstaged: "•"
        case .untracked: "?"
        case .conflict: "!"
        }
        return (letter?.glyph ?? rollup, ink)
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

    /// Asks for the offer to be taken, which puts `git init` on the focused
    /// pane's prompt without a newline.
    ///
    /// **Nothing here runs git**, and the click that reaches this does not happen
    /// in this view: the offer is `InitOfferView`, a button floating over the
    /// bottom of the clip. It is held here because ``FilesSurface`` wires the
    /// button's press to it, so the surface has one handler to expose rather than
    /// two. See `AppDelegate.offerInit(of:)`.
    var onInitialise: (() -> Void)?

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
        guard let row = RowFeedback.row(of: event) else { return }
        feedback.hovered = row
        updateHoverGuide()
    }

    /// Only when the row leaving is the row that was hovered. Areas are adjacent,
    /// so moving down a list delivers the next row's enter before this row's exit,
    /// and clearing unconditionally would drop the hover that had just arrived.
    override func mouseExited(with event: NSEvent) {
        guard let row = RowFeedback.row(of: event) else { return }
        guard feedback.hovered == row else { return }
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

/// The offer to make a walked directory into a repository, as a button floating
/// over the bottom of the column.
///
/// **The owner's 2026-08-12 ruling put it here.** kero shows a directory's files
/// and offers to initialize it, and the first version of this offer keyed on a
/// `hasRoot` boolean that a plain directory answered `true` for, so it appeared
/// only when the anchor could not resolve at all. The state the ruling was about
/// is a pane sitting in a real directory, which has rows, so the offer needed a
/// place to sit that is not the centred empty-state treatment.
///
/// **A floating button and not a footer**, the owner's second ruling the same
/// day: "make the git init button float at the bottom of the sidebar, no footer".
/// The version before this one was a full-width strip in an opaque
/// `theme.background` with a hairline above it, and those two things together are
/// what a footer is: a plane bolted across the bottom of the column, ruled off
/// from the list as a different surface. All four of its footer signals are gone.
/// It no longer spans the column, it is sized to its caption and inset from both
/// edges; it carries no rule, because a rule is the statement that two planes
/// meet and this one floats over a single plane rather than terminating it; it
/// paints a pill rather than a rectangle, so its shape is a control's and not a
/// region's; and the rows now run the full height of the column underneath it.
///
/// **A button and not a last row, which is the part that had to be argued.** The
/// tree's rows are files and directories, and a click on one puts a path on the
/// prompt. An action drawn in that list at that row height reads as another
/// entry, and the hand reaching for the last file in a directory would find it.
/// So this is unmistakably not a row: it does not scroll with them, it is a pill
/// where a row is a full-width band, it is inset from the trailing edge where a
/// row runs to it, and its caption is a command in the mono face rather than a
/// filename.
///
/// Every safety property the first version established is kept, and none of them
/// were about where it sat:
///
/// 1. **The caption is the literal command.** ``SurfaceMessage/initCaption`` is
///    the same eight characters that land on the prompt, so what is read before
///    the click and what appears after it are the same string.
/// 2. **Nothing runs at draw time.** ``onPress`` fires from `mouseUp` and from
///    nowhere else, and what it reaches puts the command on the prompt line with
///    no newline: the keystroke that writes a `.git` directory is still the
///    owner's.
/// 3. **Press and release must both land on it.** A `mouseDown` elsewhere never
///    arms it and a press dragged off disarms, exactly as the rows behave.
/// 4. **It is hit-tested against the rect it was drawn in**, which here is
///    `bounds`: a view has one rect, it is the rect AppKit routed the click
///    through, and there is no second copy of any centring to go stale. This is
///    the property the first version needed a returned rect for, and giving the
///    offer its own view is what makes it structural instead.
/// 5. **It never takes first responder**, the constraint the whole column is
///    built under. ``acceptsFirstResponder`` is false, as on the rows view.
///
/// Nothing takes the keyboard and no `NSButton` is involved: the pill is drawn
/// from the column's own row metrics and the pane capsule's own backing, so the
/// offer reads as something this app already draws rather than a control dropped
/// into it.
@MainActor
final class InitOfferView: NSView {
    var theme: PaneTheme = .darkPastel { didSet { needsDisplay = true } }

    /// Fired on a completed press-and-release inside this view, and by nothing
    /// else. ``FilesSurface`` wires it to the tree's `onInitialise`.
    var onPress: (() -> Void)?

    override var acceptsFirstResponder: Bool { false }

    override var isFlipped: Bool { true }

    /// One row's height. The pill is a row's weight because it sits in a column of
    /// rows and a control heavier than the content it offers to act on reads as a
    /// panel; the rule that used to be added on top of this went with the footer.
    static let height: Double = SidebarRowMetrics.rowHeight

    /// The gap between the pill and the column's edges, on all three sides it has
    /// one. Half the row inset, which is what makes it read as floating *over* the
    /// column: a control at the full inset lines its leading edge up with the
    /// row text above it and reads as another row, and a control at zero is a
    /// footer again. At 6 it clears the text column visibly without drifting into
    /// the middle of the panel.
    static let margin: Double = SidebarRowMetrics.inset / 2

    /// What the rows leave clear at the bottom, which is the pill and the air
    /// under it. See ``FilesSurface/layOutOffer()`` for why the reservation
    /// survived the footer that used to justify it.
    static let reserved: Double = InitOfferView.height + InitOfferView.margin

    private var isPressed = false { didSet { needsDisplay = true } }
    private var isHovered = false { didSet { needsDisplay = true } }

    /// The caption, `+` and then the command, measured in one place because both
    /// the draw and ``fittingWidth`` need the same number and a second copy of it
    /// is a second chance to disagree.
    ///
    /// The glyph is what marks this as an offer to add something rather than a
    /// file called `git init`. ``SurfaceMessage/initCaption`` is the literal
    /// command and the same string that lands on the prompt.
    private func caption() -> NSAttributedString {
        NSAttributedString(
            string: "+  " + SurfaceMessage.initCaption,
            attributes: [
                .font: SidebarRowMetrics.font,
                .foregroundColor: SidebarRowMetrics.nsColor(theme.inkContext),
            ]
        )
    }

    /// How wide the pill wants to be: its caption plus a row inset of padding at
    /// each end, so the text sits in the pill the way a row's text sits in a row.
    ///
    /// **This is what replaces the full-column width**, and it is why the offer
    /// now needs a width of its own at all. ``FilesSurface/layOutOffer()`` asks
    /// for it and frames the view at exactly this, so the view's `bounds` is the
    /// pill and the pill is the view: the hit-test stays `bounds` and there is
    /// still no second copy of any geometry to go stale.
    func fittingWidth() -> Double {
        caption().size().width + SidebarRowMetrics.inset * 2
    }

    override func draw(_: NSRect) {
        // The pill, at half its height, so the ends are full semicircles — the
        // pane capsule's own shape rule, for the same reason: a control that is
        // not a region should not have a region's corners.
        let radius = bounds.height / 2
        let pill = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)

        // **The backing, and the whole legibility argument for floating at all.**
        // With the footer's opaque plane gone, the rows run the full height of the
        // column and a file name scrolls under this pill, so the offer has to
        // carry its own material or the caption reads over a filename. This is the
        // answer `PaneClusterView` reached on the owner's other 2026-08-12 ruling
        // (e468a01, "the pill stops letting text read through"), cited rather than
        // re-derived and deliberately not a second vocabulary: the shape's own
        // fill in `theme.background` at ``ChromeMaterials/PaneWash``'s floor,
        // whose doc carries the measured bound (`alpha >= (B - 75) / (B - 20)`,
        // 0.4712 on the brightest backdrop this repo has measured) that makes 0.5
        // a legibility floor rather than a taste.
        //
        // The floor and then the same colour again, which is opaque where the
        // capsule's stack is translucent, and the difference is what is beneath.
        // The capsule floats over live terminal output that the owner is meant to
        // keep seeing, so it stops at the floor and lets the material carry the
        // rest. Beneath this is a file list the offer is *not* about, and a name
        // ghosting through the command would be the "drawn in one place" failure
        // in a second form. So the floor is where this starts and not where it
        // stops: it is stated as the floor it is, and the second fill takes it the
        // rest of the way, so a future translucent treatment thins toward 0.5 and
        // can never go under it.
        SidebarRowMetrics.nsColor(theme.background, alpha: ChromeMaterials.PaneWash.floor).setFill()
        pill.fill()
        SidebarRowMetrics.nsColor(theme.background).setFill()
        pill.fill()

        // Hover and press take the capsule's vocabulary rather than the rows',
        // which is the one place this stops borrowing from the list. A row's
        // feedback is a fill appearing behind text that had no fill: it says
        // "this line of the list is the one you are pointing at". This is not a
        // line of the list, and it always has a fill, so the same treatment would
        // read as a row lighting up at the bottom of the column. What a floating
        // control has instead is its own surface to brighten, so the states are a
        // wash over the pill's own fill, at the capsule's active-segment alpha
        // and doubled under the press — the same white-over-fill step the capsule
        // makes, in the same shape as the thing it is washing.
        if isPressed || isHovered {
            NSColor(white: 1, alpha: isPressed ? 0.28 : 0.14).setFill()
            pill.fill()
        }

        // Dropped rather than truncated when the column cannot hold it, the rule
        // the heading's own trailing half follows: `SidebarHost.minimumWidth` is
        // 120, and a command clipped to `git in` is a control nobody can identify
        // and a string nobody should trust.
        //
        // **What "too narrow" means moved with the width**, and it is now decided
        // one step earlier. The strip was always the column's width and dropped
        // its own caption; the pill is sized *from* the caption, so a pill that
        // cannot hold its text is a pill that should not be there at all, and
        // ``FilesSurface/layOutOffer()`` hides the view rather than drawing an
        // empty capsule over the files. The guard stays here regardless: it is
        // cheap, and a view drawn at a width its caption does not fit is exactly
        // the disagreement this feature is written against.
        let caption = self.caption()
        guard caption.size().width + SidebarRowMetrics.inset * 2 <= bounds.width else { return }
        caption.draw(at: NSPoint(
            x: SidebarRowMetrics.inset,
            y: SidebarRowMetrics.textOrigin
        ))
    }

    // MARK: - Pointing

    override func mouseDown(with _: NSEvent) {
        isPressed = true
    }

    /// A press that leaves the pill disarms, and re-entering while held arms it
    /// again. The rows do exactly this, and here it is the whole of why a stray
    /// click cannot take the offer.
    override func mouseDragged(with event: NSEvent) {
        guard isPressed || hits(event) else { return }
        isPressed = hits(event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { isPressed = false }
        // Released outside is a cancel, which is what a press that can be dragged
        // off is for.
        guard isPressed, hits(event) else { return }
        onPress?()
    }

    /// Against `bounds`, which is the rect this view was drawn in and the rect the
    /// click was routed through. There is no second arithmetic to disagree with.
    private func hits(_ event: NSEvent) -> Bool {
        bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with _: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
