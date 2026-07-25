import Foundation
import Testing

@testable import GitWorkspace

@Suite final class GitDirectoryTests {
    let fixture: DirectoryFixture

    init() throws {
        fixture = try DirectoryFixture()
    }

    @Test func findsTheGitDirectoryOfANormalClone() throws {
        let repository = try fixture.repository("proj")
        #expect(
            GitDirectory.url(forRepositoryRoot: repository) == fixture.directoryURL("proj/.git")
        )
    }

    @Test func returnsNilForADirectoryWithNoGitEntry() throws {
        let plain = try fixture.directory("notes")
        #expect(GitDirectory.url(forRepositoryRoot: plain) == nil)
    }

    @Test func returnsNilForAPathThatIsNotThere() {
        #expect(GitDirectory.url(forRepositoryRoot: fixture.root.appending(path: "ghost")) == nil)
    }

    @Test func followsAGitFileToAnAbsoluteGitdir() throws {
        let target = try fixture.directory("proj/.git/worktrees/wt")
        let tree = try fixture.worktree("wt", pointingAt: target.path(percentEncoded: false))
        #expect(GitDirectory.url(forRepositoryRoot: tree) == fixture.directoryURL("proj/.git/worktrees/wt"))
    }

    @Test func followsAGitFileToARelativeGitdir() throws {
        // `git worktree add --relative-paths` writes exactly this. Resolving it
        // against the process's working directory instead of against the worktree
        // lands inside baia's own bundle, which exists and is not a git directory,
        // so the mistake would show up as "nothing in progress" rather than as an
        // error.
        try fixture.directory("proj/.git/worktrees/wt")
        let tree = try fixture.worktree("wt", pointingAt: "../proj/.git/worktrees/wt")
        #expect(GitDirectory.url(forRepositoryRoot: tree) == fixture.directoryURL("proj/.git/worktrees/wt"))
    }

    @Test func toleratesACarriageReturnAfterTheGitdirPath() throws {
        // A `.git` file that went through a Windows checkout or an editor keeps the
        // return inside the path, and every probe under the git directory then
        // misses while the path still looks correct in anything printed from it.
        try fixture.directory("proj/.git/worktrees/wt")
        let target = fixture.root.appending(path: "proj/.git/worktrees/wt").path(percentEncoded: false)
        let tree = try fixture.directory("wt")
        try "gitdir: \(target)\r\n".write(
            to: tree.appending(path: ".git"),
            atomically: true,
            encoding: .utf8
        )
        #expect(GitDirectory.url(forRepositoryRoot: tree) == fixture.directoryURL("proj/.git/worktrees/wt"))
    }

    @Test func returnsNilWhenTheGitFileHoldsNoPointer() throws {
        let tree = try fixture.directory("wt")
        try "not a pointer\n".write(
            to: tree.appending(path: ".git"),
            atomically: true,
            encoding: .utf8
        )
        #expect(GitDirectory.url(forRepositoryRoot: tree) == nil)
    }

    @Test func returnsNilWhenThePointerTargetIsGone() throws {
        // What `git worktree prune` leaves behind: the worktree directory and its
        // `.git` file survive while the git directory they name does not. Handing
        // back the missing path would make the probe answer "nothing in progress"
        // for a repository with no git directory at all, and nil is what lets a
        // caller tell those two apart.
        let tree = try fixture.worktree("wt", pointingAt: "/nowhere/.git/worktrees/wt")
        #expect(GitDirectory.url(forRepositoryRoot: tree) == nil)
    }

    @Test func returnsNilWhenThePointerTargetIsAFile() throws {
        // A pointer resolving to a regular file is a corrupt repository, and the
        // probes below it would all read as false, which is indistinguishable from
        // a clean one.
        try fixture.file("proj/gitdir-is-a-file", contents: "x")
        let target = fixture.root.appending(path: "proj/gitdir-is-a-file")
        let tree = try fixture.worktree("wt", pointingAt: target.path(percentEncoded: false))
        #expect(GitDirectory.url(forRepositoryRoot: tree) == nil)
    }

    @Test func recognisesALinkedWorktree() throws {
        try fixture.directory("proj/.git/worktrees/wt")
        let target = fixture.root.appending(path: "proj/.git/worktrees/wt")
        let tree = try fixture.worktree("wt", pointingAt: target.path(percentEncoded: false))
        #expect(GitDirectory.isLinkedWorktree(repositoryRoot: tree))
    }

    @Test func doesNotCallASubmoduleALinkedWorktree() throws {
        // The mirror of recognisesALinkedWorktree, and the reason the check is on
        // the parent component rather than on `.git` being a file: a submodule's
        // `.git` is a file too. Either test alone passes whichever way that check
        // goes. Calling a submodule a worktree would offer it in the palette as a
        // sibling of the repository it lives inside.
        try fixture.directory("super/.git/modules/sub")
        let target = fixture.root.appending(path: "super/.git/modules/sub")
        let submodule = try fixture.worktree("super/sub", pointingAt: target.path(percentEncoded: false))
        #expect(!GitDirectory.isLinkedWorktree(repositoryRoot: submodule))
    }

    @Test func doesNotCallANormalCloneALinkedWorktree() throws {
        let repository = try fixture.repository("proj")
        #expect(!GitDirectory.isLinkedWorktree(repositoryRoot: repository))
    }

    @Test func doesNotCallADirectoryWithNoGitEntryALinkedWorktree() throws {
        let plain = try fixture.directory("notes")
        #expect(!GitDirectory.isLinkedWorktree(repositoryRoot: plain))
    }
}
