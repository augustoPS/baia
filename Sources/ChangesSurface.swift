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
            scrollView.backgroundColor = Self.nsColor(theme.panelBackground)
        }
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

    static func nsColor(_ rgb: RGB) -> NSColor {
        NSColor(
            srgbRed: CGFloat(rgb.red),
            green: CGFloat(rgb.green),
            blue: CGFloat(rgb.blue),
            alpha: 1
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
            resize()
            needsDisplay = true
        }
    }

    private var sorted: [RepositoryFileChange] = []

    override var acceptsFirstResponder: Bool { false }

    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        resize()
    }

    /// The document view is exactly as tall as its rows, which is what tells the
    /// scroll view whether there is anything to scroll to.
    private func resize() {
        let width = max(superview?.bounds.width ?? 0, 1)
        let height = max(Double(sorted.count) * Self.rowHeight, superview?.bounds.height ?? 0)
        frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    override func draw(_ dirty: NSRect) {
        ChangesSurface.nsColor(theme.panelBackground).setFill()
        bounds.fill()

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
        let y = Double(index) * Self.rowHeight
        let marker = Self.marker(for: change)
        NSAttributedString(
            string: marker.text,
            attributes: [
                .font: Self.font,
                .foregroundColor: ChangesSurface.nsColor(marker.colour(in: theme)),
            ]
        ).draw(at: NSPoint(x: Self.inset, y: y + Self.baseline))

        // The last component in the foreground ink and the directory ahead of it
        // faint, so a column of paths reads as a column of file names with context
        // rather than as a column of shared prefixes.
        let path = change.path
        let split = path.lastIndex(of: "/").map { path.index(after: $0) }
        let directory = split.map { String(path[path.startIndex ..< $0]) } ?? ""
        let name = split.map { String(path[$0...]) } ?? path

        let line = NSMutableAttributedString()
        if !directory.isEmpty {
            line.append(NSAttributedString(
                string: directory,
                attributes: [
                    .font: Self.font,
                    .foregroundColor: ChangesSurface.nsColor(theme.inkFaint),
                ]
            ))
        }
        line.append(NSAttributedString(
            string: name,
            attributes: [
                .font: Self.font,
                .foregroundColor: ChangesSurface.nsColor(theme.foreground),
            ]
        ))

        let x = Self.inset + Self.markerColumn
        line.draw(in: NSRect(
            x: x,
            y: y + 1,
            width: max(0, bounds.width - x - Self.inset),
            height: Self.rowHeight
        ))
    }

    private func draw(message: String) {
        NSAttributedString(
            string: message,
            attributes: [
                .font: Self.font,
                .foregroundColor: ChangesSurface.nsColor(theme.inkFaint),
            ]
        ).draw(at: NSPoint(x: Self.inset, y: Self.baseline))
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
    private static func marker(for change: RepositoryFileChange) -> Marker {
        switch change.kind {
        case .untracked:
            Marker(text: "??", role: .untracked)
        case .unmerged:
            Marker(text: "UU", role: .conflict)
        case .ordinary, .renamedOrCopied:
            Marker(
                text: String(change.index?.rawValue ?? ".") + String(change.worktree?.rawValue ?? "."),
                role: change.index != nil ? .staged : .unstaged
            )
        }
    }

    private struct Marker {
        enum Role { case staged, unstaged, untracked, conflict }
        let text: String
        let role: Role

        /// Borrowed from the footer's own vocabulary rather than invented: the same
        /// colours already mean the same things one line below.
        func colour(in theme: PaneTheme) -> RGB {
            switch role {
            case .staged: theme.ok
            case .unstaged: theme.warn
            case .untracked: theme.inkFaint
            case .conflict: theme.alert
            }
        }
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let rowHeight: Double = 18
    private static let baseline: Double = 3
    private static let inset: Double = 12
    private static let markerColumn: Double = 26
}
