import Foundation
import Testing

@testable import GitWorkspace

/// The marker names and their coexistence were measured against git 2.50.1 rather
/// than taken from the documentation: a `git merge` conflict leaves `MERGE_HEAD`,
/// a `git cherry-pick` conflict leaves `CHERRY_PICK_HEAD`, an interactive rebase
/// stopped on a conflict leaves the `rebase-merge` directory, and `git bisect
/// start` leaves `BISECT_LOG` for the whole session.
@Suite final class InProgressProbeTests {
    let fixture: DirectoryFixture
    let gitDirectory: URL

    init() throws {
        fixture = try DirectoryFixture()
        gitDirectory = try fixture.directory("proj/.git")
    }

    @Test func detectsNothingInAQuietGitDirectory() throws {
        // The other markers git always keeps there. A probe matching on a prefix,
        // or on the wrong file, reports a permanent operation in progress on every
        // repository the owner has ever committed in.
        try fixture.file("proj/.git/HEAD", contents: "ref: refs/heads/main\n")
        try fixture.file("proj/.git/ORIG_HEAD", contents: "5a52ecc\n")
        try fixture.file("proj/.git/COMMIT_EDITMSG", contents: "wip\n")
        #expect(InProgressProbe.detect(gitDirectory: gitDirectory) == nil)
    }

    @Test func detectsARebaseFromTheMergeBackendDirectory() throws {
        try fixture.directory("proj/.git/rebase-merge")
        #expect(InProgressProbe.detect(gitDirectory: gitDirectory) == .rebase)
    }

    @Test func detectsARebaseFromTheApplyBackendDirectory() throws {
        // `git rebase --apply` and `git am` write `rebase-apply` where the default
        // merge backend writes `rebase-merge`. Probing one covers half the ways a
        // rebase can halt, and the owner would see a clean bar in the other half.
        try fixture.directory("proj/.git/rebase-apply")
        #expect(InProgressProbe.detect(gitDirectory: gitDirectory) == .rebase)
    }

    @Test func detectsAMerge() throws {
        try fixture.file("proj/.git/MERGE_HEAD", contents: "5a52ecc\n")
        #expect(InProgressProbe.detect(gitDirectory: gitDirectory) == .merge)
    }

    @Test func detectsACherryPick() throws {
        try fixture.file("proj/.git/CHERRY_PICK_HEAD", contents: "5a52ecc\n")
        #expect(InProgressProbe.detect(gitDirectory: gitDirectory) == .cherryPick)
    }

    @Test func detectsARevert() throws {
        try fixture.file("proj/.git/REVERT_HEAD", contents: "5a52ecc\n")
        #expect(InProgressProbe.detect(gitDirectory: gitDirectory) == .revert)
    }

    @Test func detectsABisect() throws {
        try fixture.file("proj/.git/BISECT_LOG", contents: "git bisect start\n")
        #expect(InProgressProbe.detect(gitDirectory: gitDirectory) == .bisect)
    }

    @Test func namesTheMergeRatherThanTheBisectItRanInsideOf() throws {
        // `BISECT_LOG` is written once by `git bisect start` and removed only by
        // `git bisect reset`, so it is still there for every merge the owner
        // performs during the session. Checking bisect first would name the session
        // he already knows about instead of the conflict blocking him, and the
        // whole point of the bar is to name the thing that has to be fixed.
        try fixture.file("proj/.git/BISECT_LOG", contents: "git bisect start\n")
        try fixture.file("proj/.git/MERGE_HEAD", contents: "5a52ecc\n")
        #expect(InProgressProbe.detect(gitDirectory: gitDirectory) == .merge)
    }

    @Test func namesTheRebaseRatherThanTheMergeMarkersItLeavesBehind() throws {
        // A halted rebase leaves `MERGE_MSG` and `AUTO_MERGE` in the git directory
        // alongside `rebase-merge`. Neither is a marker here, and adding either
        // would report `.merge` for the state `git rebase --continue` repairs.
        try fixture.directory("proj/.git/rebase-merge")
        try fixture.file("proj/.git/MERGE_MSG", contents: "conflict\n")
        try fixture.file("proj/.git/AUTO_MERGE", contents: "5a52ecc\n")
        #expect(InProgressProbe.detect(gitDirectory: gitDirectory) == .rebase)
    }

    @Test func detectsNothingInAGitDirectoryThatIsNotThere() {
        // A pruned worktree's git directory. Every probe answers false, which is
        // the same answer a clean repository gives, and that is why
        // `GitDirectory.url(forRepositoryRoot:)` returns nil for the missing case
        // rather than leaving this call to disambiguate it.
        #expect(InProgressProbe.detect(gitDirectory: fixture.root.appending(path: "gone")) == nil)
    }
}
