import Foundation
import Testing

@testable import GitWorkspace

@Suite struct RepositoryStatusTests {
    @Test func indicatorsAreEmptyForACleanRepositoryInSync() {
        // The empty string is the contract that lets a status bar concatenate
        // this after the head name with no conditional. A space, or a dash, or
        // any other placeholder would put a mark on every clean pane.
        let status = RepositoryStatus(head: .branch("main"), upstream: "origin/main")
        #expect(status.indicators == "")
    }

    @Test func indicatorsCarryAheadBehindDirtyAndUntrackedInThatOrder() {
        let status = RepositoryStatus(
            head: .branch("main"),
            upstream: "origin/main",
            ahead: 1,
            behind: 2,
            staged: 3,
            untracked: 4
        )
        #expect(status.indicators == "↑1↓2*?")
    }

    @Test func indicatorsOmitAZeroCountRatherThanPrintingIt() {
        // `ps1-style.sh` guards each arrow on the count being non-empty and not
        // "0". A status bar printing ↑0↓0 on every synced branch is noise the
        // owner has already rejected once in his own prompt.
        let status = RepositoryStatus(
            head: .branch("main"),
            upstream: "origin/main",
            ahead: 0,
            behind: 3
        )
        #expect(status.indicators == "↓3")
    }

    @Test func aStagedChangeAloneIsDirty() {
        let status = RepositoryStatus(head: .branch("main"), staged: 1)
        #expect(status.indicators == "*")
    }

    @Test func anUnstagedChangeAloneIsDirty() {
        let status = RepositoryStatus(head: .branch("main"), unstaged: 1)
        #expect(status.indicators == "*")
    }

    @Test func aConflictedFileAloneIsDirty() {
        // A repository stuck mid-merge has neither staged nor unstaged counts in
        // porcelain v2, only unmerged records. Leaving conflicts out of the
        // asterisk renders the one state the owner most needs to see as clean.
        let status = RepositoryStatus(head: .branch("main"), conflicted: 1)
        #expect(status.indicators == "*")
    }

    @Test func untrackedFilesAloneAreNotDirty() {
        // The two marks are separate in the owner's prompt: `*` comes from
        // `git diff`, which never sees an untracked file. Collapsing them would
        // make a fresh clone with a stray note in it look like it has edits.
        let status = RepositoryStatus(head: .branch("main"), untracked: 2)
        #expect(status.indicators == "?")
    }

    @Test func displayHeadIsTheBranchName() {
        #expect(RepositoryStatus(head: .branch("workspace-shell")).displayHead == "workspace-shell")
    }

    @Test func displayHeadIsTheBranchNameOfAnUnbornRepository() {
        // The point of the `unborn` case: a fresh `git init` shows `main`, not
        // `(initial)` and not a parenthesised oid it does not have.
        #expect(RepositoryStatus(head: .unborn("main")).displayHead == "main")
    }

    @Test func displayHeadAbbreviatesADetachedCommitInParentheses() {
        let status = RepositoryStatus(head: .detached(commit: "d45da29c98b28407c3bc86cde1d5ff3a5e14b2e0"))
        #expect(status.displayHead == "(d45da29)")
    }

    @Test func displayHeadPassesAShortCommitThroughWhole() {
        // `prefix` on a string shorter than the bound returns the whole string
        // rather than trapping, and nothing pads it out. A fixture oid is the
        // only way to get here, and the alternative is a crash in a status bar.
        #expect(RepositoryStatus(head: .detached(commit: "abc")).displayHead == "(abc)")
    }

    @Test func anUnbornHeadIsNotEqualToTheBranchItBecomes() {
        // These two render identically through `displayHead`, so a status bar
        // that compared rendered strings would not refresh when the first commit
        // lands. Equality is on `Head` itself, which is what makes the moment a
        // repository stops being empty visible to a caller keyed on inequality.
        let unborn = RepositoryStatus(head: .unborn("main"))
        let born = RepositoryStatus(head: .branch("main"))
        #expect(unborn.displayHead == born.displayHead)
        #expect(unborn != born)
    }
}
