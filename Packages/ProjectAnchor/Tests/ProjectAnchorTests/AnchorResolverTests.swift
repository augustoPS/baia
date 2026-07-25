import Foundation
import Testing

@testable import ProjectAnchor

@Suite final class AnchorResolverTests {
    let fixture: DirectoryFixture
    let resolver: AnchorResolver

    init() throws {
        fixture = try DirectoryFixture()
        resolver = AnchorResolver(locator: GitRepositoryLocator(ceiling: fixture.root))
    }

    @Test func anchorsToTheRepositoryContainingTheWorkingDirectory() throws {
        let repo = try fixture.repository("proj")
        let deep = try fixture.directory("proj/src")

        let resolution = resolver.resolve(workingDirectory: deep, pin: nil)

        #expect(resolution.anchor == Anchor(url: repo, kind: .repository, source: .automatic))
        #expect(!resolution.pinIsStale)
    }

    @Test func anchorsToTheWorkingDirectoryOutsideAnyRepository() throws {
        let plain = try fixture.directory("notes")

        let resolution = resolver.resolve(workingDirectory: plain, pin: nil)

        #expect(resolution.anchor == Anchor(url: plain, kind: .plain, source: .automatic))
    }

    @Test func hasNoAnchorBeforeTheFirstWorkingDirectoryArrives() {
        let resolution = resolver.resolve(workingDirectory: nil, pin: nil)
        #expect(resolution.anchor == nil)
        #expect(!resolution.pinIsStale)
    }

    @Test func pinOverridesTheWorkingDirectory() throws {
        try fixture.repository("proj")
        let deep = try fixture.directory("proj/src")
        let pinned = try fixture.directory("notes")

        let resolution = resolver.resolve(workingDirectory: deep, pin: pinned)

        #expect(resolution.anchor == Anchor(url: pinned, kind: .plain, source: .pinned))
    }

    @Test func pinnedRepositoryRootReportsItselfAsARepository() throws {
        let repo = try fixture.repository("proj")

        let resolution = resolver.resolve(workingDirectory: nil, pin: repo)

        #expect(resolution.anchor == Anchor(url: repo, kind: .repository, source: .pinned))
    }

    @Test func pinnedDirectoryInsideARepositoryIsTakenVerbatim() throws {
        try fixture.repository("proj")
        let inside = try fixture.directory("proj/src")

        let resolution = resolver.resolve(workingDirectory: nil, pin: inside)

        // Not resolved upward to the repository root: a pin means this directory.
        #expect(resolution.anchor == Anchor(url: inside, kind: .plain, source: .pinned))
    }

    @Test func deletedPinIsReportedStaleAndFallsBackToAutomatic() throws {
        let repo = try fixture.repository("proj")
        let deep = try fixture.directory("proj/src")
        let gone = fixture.root.appending(path: "deleted")

        let resolution = resolver.resolve(workingDirectory: deep, pin: gone)

        #expect(resolution.pinIsStale)
        #expect(resolution.anchor == Anchor(url: repo, kind: .repository, source: .automatic))
    }

    @Test func aDeletedWorkingDirectoryAnchorsToItselfAsPlain() throws {
        // A shell whose cwd was removed under it is already broken on its own
        // terms. The anchor must still be something rather than nil.
        let gone = fixture.root.appending(path: "removed-under-the-shell")

        let resolution = resolver.resolve(workingDirectory: gone, pin: nil)

        #expect(resolution.anchor == Anchor(url: gone, kind: .plain, source: .automatic))
    }

    @Test func pinPointingAtAFileIsStale() throws {
        let repo = try fixture.repository("proj")
        let file = fixture.root.appending(path: "proj/README.md")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let resolution = resolver.resolve(workingDirectory: repo, pin: file)

        #expect(resolution.pinIsStale)
        #expect(resolution.anchor?.source == .automatic)
    }
}
