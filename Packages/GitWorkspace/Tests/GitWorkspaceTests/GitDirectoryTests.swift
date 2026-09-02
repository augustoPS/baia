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

    /// A pointer that is not UTF-8 survives the parse byte for byte.
    ///
    /// Tested at the parse rather than through ``GitDirectory/url(forRepositoryRoot:)``
    /// because the target cannot be created here: APFS refuses a name that is not
    /// valid UTF-8 at `mkdir`, so the end-to-end arm would need a mounted ext4,
    /// NFS, SMB or ExFAT volume, which is exactly the case this is for. What the
    /// old code did to such a pointer was replace `0xFF` with U+FFFD, whose UTF-8
    /// spelling is three different bytes, so the path handed to `fileExists`
    /// named a file no filesystem holds and the worktree read as pruned.
    @Test func aPointerThatIsNotUTF8SurvivesTheParse() throws {
        let tree = try fixture.directory("wt")
        let raw = Array("gitdir: /vol/".utf8) + [0xFF] + Array("/worktrees/wt\n".utf8)
        try Data(raw).write(to: tree.appending(path: ".git"))

        let pointer = GitDirectory.gitdirPointer(
            inFileAt: tree.appending(path: ".git").path(percentEncoded: false)
        )
        #expect(pointer == Array("/vol/".utf8) + [0xFF] + Array("/worktrees/wt".utf8))

        // The whole point: what the lossy route produced was a different byte
        // string, and no filesystem answers to it.
        let lossy = Array(String(decoding: raw, as: UTF8.self).utf8)
        #expect(lossy != raw)
    }

    /// The trailing-whitespace trim runs over bytes now, and must not cut into a
    /// multi-byte scalar. UTF-8 is self-synchronising, so it cannot; this pins it.
    @Test func aPointerEndingInAMultiByteScalarKeepsItsLastByte() throws {
        let tree = try fixture.directory("wt")
        let raw = Array("gitdir: /vol/wörktree\r\n".utf8)
        try Data(raw).write(to: tree.appending(path: ".git"))

        let pointer = GitDirectory.gitdirPointer(
            inFileAt: tree.appending(path: ".git").path(percentEncoded: false)
        )
        #expect(pointer == Array("/vol/wörktree".utf8))
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

    @Test func mainCheckoutNameWalksThreeComponentsUpFromTheWorktreeGitDirectory() throws {
        // `<main>/.git/worktrees/<name>` is the shape git writes; the main
        // checkout is the root three components above that pointer target.
        let target = try fixture.directory("baia/.git/worktrees/wave2-card-models")
        let tree = try fixture.worktree("wave2-card-models", pointingAt: target.path(percentEncoded: false))
        #expect(GitDirectory.mainCheckoutName(forLinkedWorktreeRoot: tree) == "baia")
    }

    @Test func mainCheckoutNameIsNilWhenTheGitDirectoryCannotBeResolved() throws {
        let plain = try fixture.directory("notes")
        #expect(GitDirectory.mainCheckoutName(forLinkedWorktreeRoot: plain) == nil)
    }
}
