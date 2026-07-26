import Foundation
import Testing

@testable import PaneChrome

@Suite struct PaletteRowTests {
    @Test func theLastComponentIsTheNameAndTheRestIsContext() {
        // The tier split that makes a list of paths scannable. Without it every
        // row is one grey string and the eye has to parse slashes to find the
        // project name.
        let row = PaletteRow.make(relativePath: "website/shop")
        #expect(row.parent.map(\.text).joined() == "website/")
        #expect(row.name.map(\.text).joined() == "shop")
        #expect(row.parent.allSatisfy { $0.emphasis == .context })
        #expect(row.name.allSatisfy { $0.emphasis == .normal })
    }

    @Test func aProjectDirectlyUnderARootHasNoParent() {
        // `baia` sits at the top of `~/Projects`, so there is nothing above it to
        // draw. An empty parent renders as nothing rather than as a stray slash.
        let row = PaletteRow.make(relativePath: "baia")
        #expect(row.parent.isEmpty)
        #expect(row.name.map(\.text).joined() == "baia")
    }

    @Test func matchedCharactersTakeTheAccentOnEitherSideOfTheSplit() {
        // `wsh` against `website/shop` matches the `w` in the parent and the `sh`
        // in the name, which is the placement `FuzzyMatcher` documents itself
        // finding. Both halves have to be able to carry a highlight.
        let row = PaletteRow.make(relativePath: "website/shop", matchedIndices: [0, 8, 9])
        #expect(row.parent.map(\.text) == ["w", "ebsite/"])
        #expect(row.parent.map(\.emphasis) == [.strong, .context])
        #expect(row.name.map(\.text) == ["sh", "op"])
        #expect(row.name.map(\.emphasis) == [.strong, .normal])
    }

    @Test func consecutiveMatchesCollapseIntoOneRun() {
        // One run per character would render identically and cost a measurement
        // and an attribute range each, on every row, on every keystroke.
        let row = PaletteRow.make(relativePath: "baia", matchedIndices: [0, 1, 2, 3])
        #expect(row.name.count == 1)
        #expect(row.name.first?.text == "baia")
        #expect(row.name.first?.emphasis == .strong)
    }

    @Test func alternatingMatchesStayApart() {
        // The other end of the grouping rule: runs may only merge when they agree
        // about being matched, or a highlight would bleed onto the character
        // beside it.
        let row = PaletteRow.make(relativePath: "abcd", matchedIndices: [0, 2])
        #expect(row.name.map(\.text) == ["a", "b", "c", "d"])
        #expect(row.name.map(\.emphasis) == [.strong, .normal, .strong, .normal])
    }

    @Test func anEmptyQueryLeavesEveryCharacterInItsOwnTier() {
        // The palette shows the whole list before the first keystroke, ranked by
        // recency. Nothing is highlighted, and the row still has to read.
        let row = PaletteRow.make(relativePath: "website/shop", matchedIndices: [])
        #expect(row.parent.count == 1)
        #expect(row.name.count == 1)
        #expect(row.text == "website/shop")
    }

    @Test func theRunsAlwaysJoinBackToTheMatchedString() {
        // The ranker scored `relativePath`, so a row that rendered anything else
        // would highlight offsets into a string it is not showing.
        for path in ["baia", "website/shop", "baia/.worktrees/exif-display", "a/b/c/d"] {
            let row = PaletteRow.make(relativePath: path, matchedIndices: [0, 2])
            #expect(row.text == path)
        }
    }

    @Test func onlyTheUnusualKindsEarnAChip() {
        // A repository is the common case, and a chip on every row would be a
        // column of noise saying what the absence of a chip already says.
        #expect(PaletteRow.make(relativePath: "baia", kind: .repository).chip == nil)
        #expect(PaletteRow.make(relativePath: "x", kind: .worktree).chip == "WT")
        #expect(PaletteRow.make(relativePath: "lifetracker", kind: .directory).chip == "DIR")
    }

    @Test func aWorktreePathKeepsItsBranchNameAsTheName() {
        // Both worktree layouts in daily use here bury the interesting name at
        // the end of a long path, which is exactly the case the tier split is
        // for: the eye lands on `exif-display`, and `baia/.worktrees/` is still
        // there to say which repository it belongs to.
        let row = PaletteRow.make(
            relativePath: "baia/.worktrees/exif-display",
            kind: .worktree
        )
        #expect(row.name.map(\.text).joined() == "exif-display")
        #expect(row.parent.map(\.text).joined() == "baia/.worktrees/")
        #expect(row.chip == "WT")
    }

    @Test func aTrailingSlashLeavesAnEmptyName() {
        // Not a path the discovery produces, and it must not crash the palette if
        // it ever does. An empty name draws nothing rather than indexing past the
        // end of the string.
        let row = PaletteRow.make(relativePath: "website/")
        #expect(row.name.isEmpty)
        #expect(row.parent.map(\.text).joined() == "website/")
    }
}
