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
            scrollView.backgroundColor = NSColor(
                srgbRed: CGFloat(theme.panelBackground.red),
                green: CGFloat(theme.panelBackground.green),
                blue: CGFloat(theme.panelBackground.blue),
                alpha: 1
            )
        }
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

    /// Called with a repository-relative path when a row's name is clicked.
    ///
    /// The surface knows nothing about what happens next. Whether that path is
    /// quoted, sent relative or absolute, or refused outright is `PromptPath`'s
    /// business, and where it goes is the owner's.
    var onSelect: ((String) -> Void)? {
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
        append(tree, depth: 0)
        resize()
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
        nsColor(theme.panelBackground).setFill()
        bounds.fill()

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

        if row.node.isDirectory {
            let chevron = expanded.contains(row.node.path) ? "▾" : "▸"
            NSAttributedString(
                string: chevron,
                attributes: [.font: Self.font, .foregroundColor: nsColor(theme.inkFaint)]
            ).draw(at: NSPoint(x: x, y: y + Self.textOrigin))
        }

        NSAttributedString(
            string: row.node.name,
            attributes: [
                .font: Self.font,
                .foregroundColor: nsColor(row.node.isDirectory ? theme.inkContext : theme.foreground),
            ]
        ).draw(at: NSPoint(x: x + Self.chevronColumn, y: y + Self.textOrigin))
    }

    private func draw(message: String) {
        NSAttributedString(
            string: message,
            attributes: [.font: Self.font, .foregroundColor: nsColor(theme.inkFaint)]
        ).draw(at: NSPoint(x: Self.inset, y: Self.textOrigin))
    }

    var onSelect: ((String) -> Void)?

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
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(point.y / Self.rowHeight)
        guard rows.indices.contains(index) else { return }
        let node = rows[index].node

        guard node.isDirectory else { return onSelect?(node.path) ?? () }

        if expanded.contains(node.path) {
            expanded.remove(node.path)
        } else {
            expanded.insert(node.path)
        }
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
