import Foundation
import Testing

@testable import ProjectAnchor

@Suite struct AnchorTests {
    @Test func displayNameIsTheLastPathComponent() {
        let anchor = Anchor(
            url: URL(filePath: "/Users/x/Projects/vault", directoryHint: .isDirectory),
            kind: .repository,
            source: .automatic
        )
        #expect(anchor.displayName == "vault")
    }

    @Test func anchorsForOneDirectoryAreEqualWhicheverWayTheURLWasBuilt() {
        let hinted = Anchor(
            url: URL(filePath: "/Users/x/Projects/vault", directoryHint: .isDirectory),
            kind: .repository,
            source: .automatic
        )
        let hintless = Anchor(
            url: URL(filePath: "/Users/x/Projects/vault"),
            kind: .repository,
            source: .automatic
        )
        #expect(hinted == hintless)
    }

    @Test func onlyARepositoryAnchorHasARepositoryRoot() {
        let url = URL(filePath: "/Users/x/Projects/vault", directoryHint: .isDirectory)
        #expect(
            Anchor.repositoryRoot(of: Anchor(url: url, kind: .repository, source: .automatic))
                == url
        )
        #expect(Anchor.repositoryRoot(of: Anchor(url: url, kind: .plain, source: .automatic)) == nil)
        #expect(Anchor.repositoryRoot(of: nil) == nil)
    }

    @Test func aPinnedRepositoryAnchorHasARootLikeAnAutomaticOne() {
        // The source decides how the anchor was chosen, never whether it has git
        // state. A guard written against `.automatic` would pass every test above
        // and silently blank the footer of every pinned repository.
        let url = URL(filePath: "/Users/x/Projects/vault", directoryHint: .isDirectory)
        #expect(
            Anchor.repositoryRoot(of: Anchor(url: url, kind: .repository, source: .pinned)) == url
        )
    }

    @Test func anchorsDifferingOnlyInSourceAreNotEqual() {
        let url = URL(filePath: "/Users/x/Projects/vault", directoryHint: .isDirectory)
        let automatic = Anchor(url: url, kind: .repository, source: .automatic)
        let pinned = Anchor(url: url, kind: .repository, source: .pinned)
        #expect(automatic != pinned)
    }
}
