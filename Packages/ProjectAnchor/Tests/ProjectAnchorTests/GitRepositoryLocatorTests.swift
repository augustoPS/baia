import Foundation
import Testing

@testable import ProjectAnchor

@Suite final class GitRepositoryLocatorTests {
    let fixture: DirectoryFixture
    let locator: GitRepositoryLocator

    init() throws {
        fixture = try DirectoryFixture()
        // The fixture lives outside $HOME, so the default ceiling would fall
        // back to "/". Pinning the ceiling to the fixture root keeps every walk
        // inside the tree these tests built.
        locator = GitRepositoryLocator(ceiling: fixture.root)
    }

    /// The locator hands back directory URLs, and `URL` equality separates a
    /// hinted URL from a hintless one for the same path. These tests compare the
    /// locator's raw output, not an ``Anchor``, so nothing canonicalizes for
    /// them and the expectation carries the hint here.
    private func directoryURL(_ url: URL) -> URL {
        URL(filePath: url.path(percentEncoded: false), directoryHint: .isDirectory)
    }

    @Test func findsTheRepositoryContainingADeepDirectory() throws {
        let repo = try fixture.repository("proj")
        let deep = try fixture.directory("proj/a/b/c")
        #expect(locator.repositoryRoot(containing: deep) == directoryURL(repo))
    }

    @Test func findsTheRepositoryWhenGivenItsOwnRoot() throws {
        let repo = try fixture.repository("proj")
        #expect(locator.repositoryRoot(containing: repo) == directoryURL(repo))
    }

    @Test func returnsNilOutsideAnyRepository() throws {
        let plain = try fixture.directory("notes/drafts")
        #expect(locator.repositoryRoot(containing: plain) == nil)
    }

    @Test func closestRepositoryWinsWhenNested() throws {
        try fixture.repository("outer")
        let inner = try fixture.repository("outer/vendor/inner")
        let deep = try fixture.directory("outer/vendor/inner/src")
        #expect(locator.repositoryRoot(containing: deep) == directoryURL(inner))
    }

    @Test func treatsAGitFileAsARepositoryRoot() throws {
        let tree = try fixture.worktree("wt", pointingAt: "/somewhere/.git/worktrees/wt")
        let deep = try fixture.directory("wt/src")
        #expect(locator.repositoryRoot(containing: deep) == directoryURL(tree))
    }

    @Test func returnsNilForAMissingPath() {
        let ghost = fixture.root.appending(path: "was-never-here")
        #expect(locator.repositoryRoot(containing: ghost) == nil)
    }

    @Test func resolvesSymlinksBeforeWalking() throws {
        let repo = try fixture.repository("proj")
        let deep = try fixture.directory("proj/src")
        let link = fixture.root.appending(path: "shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: deep)
        #expect(locator.repositoryRoot(containing: link) == directoryURL(repo))
    }

    @Test func doesNotClaimARepositorySittingAtTheCeiling() throws {
        // A dotfiles repository at $HOME must not claim every directory under it.
        try FileManager.default.createDirectory(
            at: fixture.root.appending(path: ".git"),
            withIntermediateDirectories: true
        )
        let plain = try fixture.directory("notes")
        #expect(locator.repositoryRoot(containing: plain) == nil)
    }

    @Test func claimsARepositoryAtTheCeilingPathWhenTheStartIsOutsideTheCeiling() throws {
        // The mirror of doesNotClaimARepositorySittingAtTheCeiling: same tree,
        // same input, a ceiling that is not an ancestor of the start. The walk is
        // unbounded then, so the repository at the fixture root is claimed. The
        // pair is what pins the ceiling's effect; either test on its own passes
        // whichever way the bounded check goes.
        let elsewhere = GitRepositoryLocator(ceiling: fixture.root.appending(path: "unrelated"))
        try FileManager.default.createDirectory(
            at: fixture.root.appending(path: ".git"),
            withIntermediateDirectories: true
        )
        let plain = try fixture.directory("notes")
        #expect(elsewhere.repositoryRoot(containing: plain) == directoryURL(fixture.root))
    }

    @Test func doesNotClaimARepositoryWhenTheStartIsTheCeilingItself() throws {
        // cwd == $HOME in a dotfiles-repo home. Hits the equality half of the
        // bounded check, which the prefix half never reaches.
        try FileManager.default.createDirectory(
            at: fixture.root.appending(path: ".git"),
            withIntermediateDirectories: true
        )
        #expect(locator.repositoryRoot(containing: fixture.root) == nil)
    }

    @Test func recognisesARepositoryRootDirectly() throws {
        let repo = try fixture.repository("proj")
        let plain = try fixture.directory("notes")
        #expect(locator.isRepositoryRoot(repo))
        #expect(!locator.isRepositoryRoot(plain))
    }
}
