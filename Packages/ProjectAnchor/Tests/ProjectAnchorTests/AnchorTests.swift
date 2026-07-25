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

    @Test func anchorsDifferingOnlyInSourceAreNotEqual() {
        let url = URL(filePath: "/Users/x/Projects/vault", directoryHint: .isDirectory)
        let automatic = Anchor(url: url, kind: .repository, source: .automatic)
        let pinned = Anchor(url: url, kind: .repository, source: .pinned)
        #expect(automatic != pinned)
    }
}
