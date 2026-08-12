import AppKit
import GitWorkspace

/// The changes card: what springs from the capsule's changes segment (design
/// v6, Task 5). The paths behind the pill's `↑1*?3`, each one a click away
/// from its diff, and a `Full diff` action row that is there from the first
/// frame.
///
/// Spinner-free by design. The card opens with only the action row, the pane
/// controller runs the poller's own porcelain read off the main actor, and
/// the file rows appear when the answer lands: ``changes`` is set, the rows
/// rebuild, and the card grows downward in place. No spinner, because the
/// read is the same one that answers in a poll tick and a card that flashed
/// a wait state for it would be louder than the wait.
///
/// Every row is a handoff, not a viewer. A click names a change and the
/// caller's closure turns it into a split running its diff (built by
/// `PaneChrome.DiffSplitCommand`); the card renders nothing of
/// the diff itself, which keeps it as dumb as ``ClusterPlaceCardView`` and
/// leaves the reading to the terminal, where diffs already live.
///
/// Drawing follows ``ClusterPlaceCardView``: system colours over the panel's
/// appearance, hand-drawn rows, no materials.
@MainActor
final class ClusterChangesCardView: NSView {
    /// The changed paths, in the order the parser answered. Setting it
    /// rebuilds the rows and resizes the card's window in place, top edge
    /// pinned, so growth extends the card downward from the segment it hangs
    /// under rather than crawling up over the capsule.
    var changes: [RepositoryFileChange] = [] {
        didSet { rebuild() }
    }

    /// A file row's handoff: the caller turns the change into a split
    /// running its diff.
    var onFileDiff: ((RepositoryFileChange) -> Void)?

    var onFullDiff: (() -> Void)?

    /// Raised by ⎋. The card cannot dismiss itself; only its controller
    /// knows the panel.
    var onClose: (() -> Void)?

    private var rows: [ClusterCardRowView] = []

    /// Where the hairline between file rows and the action row draws, or nil
    /// while there are no file rows to separate.
    private var separatorY: Double?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("baia does not use nibs")
    }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func cancelOperation(_: Any?) { onClose?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == Self.escapeKeyCode {
            onClose?()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Tears the rows down and lays the card out again: file rows first (a
    /// long list capped, with the remainder counted rather than scrolled),
    /// then the hairline, then `Full diff`.
    private func rebuild() {
        for row in rows { row.removeFromSuperview() }
        rows = []
        separatorY = nil

        var y = Self.padding

        let shown = changes.prefix(Self.maxFileRows)
        for change in shown {
            let row = makeRow(at: &y)
            // `RowStatusLetter`, with its own precedence rule (worktree over
            // index), leading a monospaced path so the letter column aligns by
            // itself. The sidebar's CHANGED rows drew the same letter until the
            // owner's 2026-08-12 ruling removed that section and left this card
            // as the one place a changed file is listed.
            row.text = "\(Self.glyph(for: RowStatusLetter(change)))  \(change.path)"
            row.font = Self.fileFont
            row.onClick = { [weak self] in self?.onFileDiff?(change) }
        }
        if changes.count > shown.count {
            // Counted, not scrolled: a card is a glance, and the rows it
            // cannot fit are one click away in the full diff below.
            let row = makeRow(at: &y)
            row.caption = "\(changes.count - shown.count) more in the full diff"
        }

        if !rows.isEmpty {
            separatorY = y + Self.separatorGap / 2
            y += Self.separatorGap
        }

        let action = makeRow(at: &y)
        action.text = "Full diff"
        action.font = Self.actionFont
        action.onClick = { [weak self] in self?.onFullDiff?() }

        apply(size: NSSize(width: Self.width, height: y + Self.padding))
        needsDisplay = true
    }

    private func makeRow(at y: inout Double) -> ClusterCardRowView {
        let row = ClusterCardRowView(frame: NSRect(
            x: 0, y: y, width: Self.width, height: ClusterCardRowView.height
        ))
        addSubview(row)
        rows.append(row)
        y += ClusterCardRowView.height
        return row
    }

    /// Resizes in place. Before presentation the card only sets its own
    /// frame, which is what ``ClusterCardController/show(content:anchoredTo:in:onDismiss:)``
    /// sizes the panel from; once up, the panel is resized with its top edge
    /// held (AppKit frames grow upward from a fixed origin, and a card
    /// anchored under a segment must not), clamped so growth cannot walk off
    /// the bottom of the screen.
    private func apply(size: NSSize) {
        guard let window else {
            setFrameSize(size)
            return
        }
        var frame = window.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        if let screen = window.screen ?? NSScreen.main {
            frame.origin.y = max(frame.origin.y, screen.visibleFrame.minY)
        }
        window.setFrame(frame, display: true)
    }

    override func draw(_: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        if let separatorY {
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: separatorY, width: bounds.width, height: 1).fill()
        }

        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Self.cornerRadius,
            yRadius: Self.cornerRadius
        )
        path.lineWidth = 1
        NSColor.separatorColor.setStroke()
        path.stroke()
    }

    // The commands a row hands off live in `PaneChrome.DiffSplitCommand`,
    // not here: they are pure, security-adjacent string composition, and a
    // view file is the one place in this project where nothing can test
    // them. The pane controller builds them, because only it knows the two
    // git facts a row cannot (untracked, unborn HEAD).

    private static func glyph(for letter: RowStatusLetter) -> Character {
        switch letter {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .conflict: "!"
        }
    }

    static let width: Double = 300

    /// The most rows a card shows before counting the rest. Fourteen rows is
    /// about a third of a screen, which is as tall as a glanceable card gets
    /// before it stops being one.
    private static let maxFileRows = 14

    private static let cornerRadius: Double = 10
    private static let padding: Double = 8
    private static let separatorGap: Double = 9

    private static let fileFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let actionFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    private static let escapeKeyCode: UInt16 = 0x35
}
