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

    /// Two files whose names differ in bytes git could report but UTF-8 cannot
    /// read keep their own marks.
    ///
    /// `0xFF` and `0xFE` are each invalid on their own, so ``RepositoryPath/display``
    /// renders both names as `?.swift` with one U+FFFD. Keyed on that spelling the
    /// second file overwrote the first through `max`, and the quieter of the two
    /// drew the louder one's glyph. Keyed on bytes they are two entries, which is
    /// what they are on disk.
    @Test func twoPathsThatDrawTheSameKeepTheirOwnMarks() {
        let staged = RepositoryPath([0xFF] + Array(".swift".utf8))
        let conflicted = RepositoryPath([0xFE] + Array(".swift".utf8))
        #expect(staged.display == conflicted.display)

        let marks = FileChangeMarks([
            RepositoryFileChange(path: staged, index: .added, kind: .ordinary),
            RepositoryFileChange(path: conflicted, index: .unmerged, worktree: .unmerged, kind: .unmerged),
        ])
        #expect(marks[staged] == .staged)
        #expect(marks[conflicted] == .conflict)
    }

    /// The rollup walks bytes too, so a directory whose name is not UTF-8 answers
    /// for what is under it rather than merging with its neighbour.
    @Test func directoriesRollUpByBytesAsWell() {
        let quiet = RepositoryPath([0xFF] + Array("/a.swift".utf8))
        let loud = RepositoryPath([0xFE] + Array("/b.swift".utf8))
        let marks = FileChangeMarks([
            RepositoryFileChange(path: quiet, index: .added, kind: .ordinary),
            RepositoryFileChange(path: loud, index: .unmerged, worktree: .unmerged, kind: .unmerged),
        ])
        #expect(marks[RepositoryPath([0xFF])] == .staged)
        #expect(marks[RepositoryPath([0xFE])] == .conflict)
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
