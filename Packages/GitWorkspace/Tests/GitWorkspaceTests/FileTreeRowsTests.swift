import Testing

@testable import GitWorkspace

@Suite struct FileTreeRowsTests {
    /// `src/` holding `a.swift` and `deep/` holding `b.swift`, beside a top-level
    /// `README.md`. Two levels of nesting, because a one-level tree cannot tell a
    /// walk that stops at the first shallower row from one that stops at the first
    /// row of equal depth.
    private var tree: [FileTreeNode] {
        FileTree.build(paths: [
            "src/a.swift",
            "src/deep/b.swift",
            "README.md",
        ])
    }

    private func rows(expanded: Set<RepositoryPath>) -> [FileTree.VisibleRow] {
        FileTree.visibleRows(of: tree, expanded: expanded)
    }

    /// Two sibling directories whose names differ only outside UTF-8 open
    /// independently.
    ///
    /// Both draw as `?` with one U+FFFD, so keyed on the drawn spelling one
    /// membership test answered for both: opening either revealed the children of
    /// both, and the set could not hold one without the other.
    @Test func twoDirectoriesThatDrawTheSameOpenIndependently() {
        let first = RepositoryPath([0xFF])
        let second = RepositoryPath([0xFE])
        #expect(first.display == second.display)

        let tree = FileTree.build(paths: [
            RepositoryPath([0xFF] + Array("/a.swift".utf8)),
            RepositoryPath([0xFE] + Array("/b.swift".utf8)),
        ])

        // Sorted on bytes, so `0xFE` comes first and its child is the row that
        // does *not* appear: only the directory that was opened reveals anything.
        let openFirst = FileTree.visibleRows(of: tree, expanded: [first])
        #expect(openFirst.map(\.node.rawPath) == [
            second,
            first,
            RepositoryPath([0xFF] + Array("/a.swift".utf8)),
        ])

        // The mirror, which is what proves the two are independent rather than
        // merely ordered: opening the other reveals the other child alone.
        let openSecond = FileTree.visibleRows(of: tree, expanded: [second])
        #expect(openSecond.map(\.node.rawPath) == [
            second,
            RepositoryPath([0xFE] + Array("/b.swift".utf8)),
            first,
        ])
    }

    private func paths(_ rows: [FileTree.VisibleRow]) -> [String] {
        rows.map(\.node.path)
    }

    // MARK: - Flattening

    @Test func acollapsedTreeShowsOnlyItsTopLevel() {
        #expect(paths(rows(expanded: [])) == ["src", "README.md"])
    }

    /// Opening a directory reveals its own children and not its grandchildren.
    /// A flattening that recursed unconditionally would pass a test that only
    /// opened the leaf level.
    @Test func openingADirectoryRevealsOneLevel() {
        #expect(paths(rows(expanded: ["src"])) == ["src", "src/deep", "src/a.swift", "README.md"])
    }

    @Test func openingBothLevelsRevealsTheWholeTree() {
        #expect(paths(rows(expanded: ["src", "src/deep"])) == [
            "src", "src/deep", "src/deep/b.swift", "src/a.swift", "README.md",
        ])
    }

    /// Opening a nested directory whose parent is shut reveals nothing. The
    /// expanded set is not a list of what is visible; a row appears only when
    /// every directory above it is open too.
    @Test func openingANestedDirectoryUnderAClosedParentRevealsNothing() {
        #expect(paths(rows(expanded: ["src/deep"])) == ["src", "README.md"])
    }

    /// Depth is the nesting level, not the row's position. Asserted separately
    /// because every path assertion above would pass with every depth set to
    /// zero, and depth is the only thing the drawing indents by.
    @Test func depthCountsAncestorsRatherThanRows() {
        let open = rows(expanded: ["src", "src/deep"])
        #expect(open.map(\.depth) == [0, 1, 2, 1, 0])
    }

    /// A path in the expanded set that names nothing in the tree is ignored
    /// rather than producing a row. Stale entries survive a branch switch.
    @Test func anExpandedPathThatNamesNothingIsIgnored() {
        #expect(paths(rows(expanded: ["gone", "src"])) == [
            "src", "src/deep", "src/a.swift", "README.md",
        ])
    }

    // MARK: - The descendant span

    /// The span is the rows under the directory, exclusive of its own row, and
    /// the depth is the directory's own.
    @Test func anOpenDirectoryOwnsEveryRowBeneathIt() {
        let open = rows(expanded: ["src", "src/deep"])
        let guide = FileTree.descendants(ofRowAt: 0, in: open)
        #expect(guide?.depth == 0)
        #expect(guide?.rows == 1 ..< 4)
    }

    /// The walk stops at the first row no deeper than the directory, so a span
    /// never runs past a sibling. Without this a walk to the end of the array
    /// passes every test whose directory happens to be last.
    @Test func aSpanStopsAtTheNextSiblingRatherThanAtTheEnd() {
        let open = rows(expanded: ["src", "src/deep"])
        // `src/deep` is row 1 and owns only row 2. Row 3 is `src/a.swift`, its
        // sibling, and row 4 is `README.md` at the top level.
        #expect(FileTree.descendants(ofRowAt: 1, in: open)?.rows == 2 ..< 3)
    }

    /// A directory that is shut owns nothing, because its children are not in
    /// the rows at all. This is the assertion that lets the function read the
    /// rows alone rather than also taking the expanded set.
    @Test func aClosedDirectoryOwnsNothing() {
        #expect(FileTree.descendants(ofRowAt: 0, in: rows(expanded: [])) == nil)
    }

    @Test func aFileOwnsNothing() {
        let open = rows(expanded: ["src"])
        // Row 2 is `src/a.swift`.
        #expect(open[2].node.isDirectory == false)
        #expect(FileTree.descendants(ofRowAt: 2, in: open) == nil)
    }

    /// An index off either end, and no index at all, are all nil rather than a
    /// crash. The caller passes a hover that can go stale between a rebuild and
    /// the next mouse event.
    @Test func anIndexOutsideTheRowsIsNil() {
        let open = rows(expanded: ["src"])
        #expect(FileTree.descendants(ofRowAt: nil, in: open) == nil)
        #expect(FileTree.descendants(ofRowAt: -1, in: open) == nil)
        #expect(FileTree.descendants(ofRowAt: open.count, in: open) == nil)
        #expect(FileTree.descendants(ofRowAt: 0, in: []) == nil)
    }

    /// Every open directory's span is exactly the rows whose depth exceeds its
    /// own until the first that does not, checked against an independent walk
    /// rather than against hand-written indices. A hand-written index agrees
    /// with whatever the implementation happens to do at the row it names.
    @Test func everySpanHoldsExactlyTheRowsNestedUnderIt() {
        let open = rows(expanded: ["src", "src/deep"])
        for (index, row) in open.enumerated() where row.node.isDirectory {
            guard let guide = FileTree.descendants(ofRowAt: index, in: open) else { continue }
            for inside in guide.rows {
                #expect(open[inside].depth > row.depth)
            }
            let after = guide.rows.upperBound
            if after < open.count {
                #expect(open[after].depth <= row.depth)
            }
        }
    }
}
