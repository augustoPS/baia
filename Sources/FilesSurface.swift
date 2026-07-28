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

    /// The tree to draw. Assigning collapses everything below the top level, because
    /// an expansion set from one repository means nothing in the next.
    var tree: [FileTreeNode] = [] {
        didSet {
            rows.expanded = []
            rows.tree = tree
        }
    }

    var hasRepository = true {
        didSet { rows.hasRepository = hasRepository }
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
        frame = NSRect(
            x: 0,
            y: 0,
            width: max(frame.width, superview?.bounds.width ?? 0),
            height: max(Double(rows.count) * Self.rowHeight, superview?.bounds.height ?? 0)
        )
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
            ).draw(at: NSPoint(x: x, y: y + Self.baseline))
        }

        NSAttributedString(
            string: row.node.name,
            attributes: [
                .font: Self.font,
                .foregroundColor: nsColor(row.node.isDirectory ? theme.inkContext : theme.foreground),
            ]
        ).draw(at: NSPoint(x: x + Self.chevronColumn, y: y + Self.baseline))
    }

    private func draw(message: String) {
        NSAttributedString(
            string: message,
            attributes: [.font: Self.font, .foregroundColor: nsColor(theme.inkFaint)]
        ).draw(at: NSPoint(x: Self.inset, y: Self.baseline))
    }

    /// Opens or closes a directory, and never asks for focus.
    ///
    /// `mouseDown` rather than a control or a table selection, and with no
    /// `becomeFirstResponder` anywhere near it. That is the whole safety argument
    /// for a clickable surface living in this window.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(point.y / Self.rowHeight)
        guard rows.indices.contains(index) else { return }
        let node = rows[index].node
        guard node.isDirectory else { return }
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

    private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let rowHeight: Double = 18
    private static let baseline: Double = 3
    private static let inset: Double = 10
    private static let indent: Double = 12
    private static let chevronColumn: Double = 14
}
