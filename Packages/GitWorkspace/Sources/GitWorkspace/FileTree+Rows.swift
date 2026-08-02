extension FileTree {
    /// One visible row: a node and how deep it sits.
    ///
    /// The flattened form of the tree, which is what a list actually draws. A
    /// list holds an array of these and indexes into it; the nesting survives
    /// only as ``depth``, which is the one thing the drawing needs and the one
    /// thing a row's rectangle cannot say.
    public struct VisibleRow: Sendable, Equatable {
        public let node: FileTreeNode
        public let depth: Int

        public init(node: FileTreeNode, depth: Int) {
            self.node = node
            self.depth = depth
        }
    }

    /// The rows a list draws for this tree, given which directories are open.
    ///
    /// Depth-first and in tree order, so a directory is immediately followed by
    /// everything under it. That adjacency is not incidental: it is what lets
    /// ``descendants(ofRowAt:in:)`` answer a directory's extent by scanning
    /// forward from its own row instead of searching, and it is what makes a
    /// span of rows a contiguous rectangle on screen.
    ///
    /// Keyed on ``FileTreeNode/path``, the drawn spelling, because that is what
    /// the caller's expanded set holds. Two paths differing only outside UTF-8
    /// therefore open and close together, which is the same lossy-path limit the
    /// picker still has and is tracked with it rather than separately.
    public static func visibleRows(
        of nodes: [FileTreeNode],
        expanded: Set<String>
    ) -> [VisibleRow] {
        var rows: [VisibleRow] = []
        append(nodes, depth: 0, expanded: expanded, to: &rows)
        return rows
    }

    private static func append(
        _ nodes: [FileTreeNode],
        depth: Int,
        expanded: Set<String>,
        to rows: inout [VisibleRow]
    ) {
        for node in nodes {
            rows.append(VisibleRow(node: node, depth: depth))
            if node.isDirectory, expanded.contains(node.path) {
                append(node.children, depth: depth + 1, expanded: expanded, to: &rows)
            }
        }
    }

    /// The level and the span the directory at `index` owns, or nil.
    ///
    /// Nil for a file, for a collapsed directory, and for an empty one: there is
    /// no extent to show for a row with nothing under it. Nil for an index
    /// outside the array too, so a caller holding a stale hover does not have to
    /// range-check before asking.
    ///
    /// Reads nothing but the rows. Whether the directory is open is not asked
    /// because it is already answered: a collapsed directory's children were
    /// never appended by ``visibleRows(of:expanded:)``, so nothing after its row
    /// sits deeper and the span comes out empty on its own. Taking the expanded
    /// set as well would be a second copy of a fact the rows already carry, and
    /// two copies of one fact is what the previous version of this function
    /// bought by living beside the view's own state.
    public static func descendants(
        ofRowAt index: Int?,
        in rows: [VisibleRow]
    ) -> (depth: Int, rows: Range<Int>)? {
        guard let index, rows.indices.contains(index) else { return nil }
        let row = rows[index]
        guard row.node.isDirectory else { return nil }
        var end = index + 1
        while end < rows.count, rows[end].depth > row.depth { end += 1 }
        guard end > index + 1 else { return nil }
        return (depth: row.depth, rows: (index + 1) ..< end)
    }
}
