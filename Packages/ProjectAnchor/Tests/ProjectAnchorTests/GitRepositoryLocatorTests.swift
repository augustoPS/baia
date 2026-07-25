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

    @Test func findsTheRepositoryContainingADeepDirectory() throws {
        let repo = try fixture.repository("proj")
        let deep = try fixture.directory("proj/a/b/c")
        #expect(locator.repositoryRoot(containing: deep) == repo)
    }

    @Test func findsTheRepositoryWhenGivenItsOwnRoot() throws {
        let repo = try fixture.repository("proj")
        #expect(locator.repositoryRoot(containing: repo) == repo)
    }

    @Test func returnsNilOutsideAnyRepository() throws {
        let plain = try fixture.directory("notes/drafts")
        #expect(locator.repositoryRoot(containing: plain) == nil)
    }

    @Test func closestRepositoryWinsWhenNested() throws {
        try fixture.repository("outer")
        let inner = try fixture.repository("outer/vendor/inner")
        let deep = try fixture.directory("outer/vendor/inner/src")
        #expect(locator.repositoryRoot(containing: deep) == inner)
    }

    @Test func treatsAGitFileAsARepositoryRoot() throws {
        let tree = try fixture.worktree("wt", pointingAt: "/somewhere/.git/worktrees/wt")
        let deep = try fixture.directory("wt/src")
        #expect(locator.repositoryRoot(containing: deep) == tree)
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
        #expect(locator.repositoryRoot(containing: link) == repo)
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

    @Test func walksPastTheCeilingWhenTheStartIsOutsideIt() throws {
        // Ceiling elsewhere means the start is not bounded by it, so the walk
        // runs to "/" and still finds the repository above it.
        let elsewhere = GitRepositoryLocator(ceiling: fixture.root.appending(path: "unrelated"))
        let repo = try fixture.repository("proj")
        let deep = try fixture.directory("proj/a/b")
        #expect(elsewhere.repositoryRoot(containing: deep) == repo)
    }

    @Test func recognisesARepositoryRootDirectly() throws {
        let repo = try fixture.repository("proj")
        let plain = try fixture.directory("notes")
        #expect(locator.isRepositoryRoot(repo))
        #expect(!locator.isRepositoryRoot(plain))
    }
}
