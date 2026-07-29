import Testing

@testable import GitWorkspace

/// Design v3 §5.2: one glyph per row in the tree, the more urgent of the two `XY`
/// columns, and a directory carrying the strongest thing beneath it.
@Suite struct FileChangeMarksTests {
    @Test func unstagedOutranksStagedForAFileThatIsBoth() {
        // `MM`: committing now leaves the second M behind, so the glyph has to be
        // the half that is still owed.
        let marks = FileChangeMarks([
            RepositoryFileChange(path: "a.swift", index: .modified, worktree: .modified, kind: .ordinary),
        ])
        #expect(marks["a.swift"] == .unstaged)
    }

    @Test func aStagedFileWithACleanWorktreeIsStaged() {
        let marks = FileChangeMarks([
            RepositoryFileChange(path: "a.swift", index: .added, kind: .ordinary),
        ])
        #expect(marks["a.swift"] == .staged)
    }

    @Test func everyKindGetsItsOwnMark() {
        let marks = FileChangeMarks([
            RepositoryFileChange(path: "conflict", index: .unmerged, worktree: .unmerged, kind: .unmerged),
            RepositoryFileChange(path: "untracked", kind: .untracked),
        ])
        #expect(marks["conflict"] == .conflict)
        #expect(marks["untracked"] == .untracked)
    }

    /// The rollup, which is what makes a collapsed directory worth reading.
    @Test func aDirectoryCarriesTheStrongestMarkBeneathIt() {
        let marks = FileChangeMarks([
            RepositoryFileChange(path: "Sources/quiet/a.swift", index: .added, kind: .ordinary),
            RepositoryFileChange(path: "Sources/loud/b.swift", index: .unmerged, worktree: .unmerged, kind: .unmerged),
        ])
        #expect(marks["Sources"] == .conflict)
        #expect(marks["Sources/quiet"] == .staged)
        #expect(marks["Sources/loud"] == .conflict)
        #expect(marks["Sources/quiet/a.swift"] == .staged)
    }

    /// Untracked rolls up like anything else: a directory of new files is a
    /// directory with something in it, and drawing nothing there would make the
    /// tree quieter than the truth.
    @Test func untrackedRollsUpTooRatherThanBeingSwallowed() {
        let marks = FileChangeMarks([
            RepositoryFileChange(path: "docs/new.md", kind: .untracked),
        ])
        #expect(marks["docs"] == .untracked)
    }

    @Test func aPathWithNothingUnderItHasNoMark() {
        let marks = FileChangeMarks([
            RepositoryFileChange(path: "Sources/a.swift", index: .added, kind: .ordinary),
        ])
        #expect(marks["Tests"] == nil)
        #expect(marks["Sources/b.swift"] == nil)
        #expect(FileChangeMarks([]).isEmpty)
    }

    /// A record with neither column carrying a state draws nothing rather than
    /// inventing a mark no reader could explain. Git does not emit one; a
    /// hand-built fixture can.
    @Test func aChangeWithNoStateInEitherColumnHasNoMark() {
        let marks = FileChangeMarks([
            RepositoryFileChange(path: "a.swift", kind: .ordinary),
        ])
        #expect(marks["a.swift"] == nil)
    }

    /// The order is the whole of both operations: collapsing `XY` and rolling a
    /// directory up are the same `max`.
    @Test func urgencyOrdersQuietestFirst() {
        #expect(FileChangeMark.untracked < .staged)
        #expect(FileChangeMark.staged < .unstaged)
        #expect(FileChangeMark.unstaged < .conflict)
        #expect(FileChangeMark.allCases.map(\.glyph) == ["?", "M", "*", "!"])
    }
}
