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

    @Test func aPlainAnchorCanExplainARefusalWithoutBecomingSendable() {
        // The regression, and the ruling that narrowed its fix. `sendToPrompt`
        // guarded on `kind == .repository` and so returned before
        // `PromptPath.resolve` ran — silently, because the refusal notice is
        // written *by* the resolve path it returned in front of. The row's red
        // flash comes off the `false` return, so the click looked answered while
        // the pane said nothing, and the defect presented as a capsule that would
        // not draw a notice it was never handed.
        //
        // The two roots must part here in *opposite* directions, and asserting one
        // without the other loses the ruling. A plain anchor answers `refusalRoot`
        // so an impossible name can still name itself; it answers nil to
        // `promptRoot` so a bare shell pane stays send-inert, which the owner ruled
        // on 2026-08-13 rather than accepting as a side effect of the repair.
        let url = URL(filePath: "/Users/x/Projects", directoryHint: .isDirectory)
        let plain = Anchor(url: url, kind: .plain, source: .automatic)
        #expect(Anchor.refusalRoot(of: plain) == url)
        #expect(Anchor.promptRoot(of: plain) == nil)
        #expect(Anchor.repositoryRoot(of: plain) == nil)
    }

    @Test func aRepositoryAnchorAnswersBothRootsAndNoAnchorAnswersNeither() {
        // The remaining arms, so "a repository under either source, and only a real
        // anchor" is stated whole rather than inferred from the plain case. Both
        // predicates are asked at every point, because the pair is the contract:
        // one of them widening to match the other is the failure this pins.
        let url = URL(filePath: "/Users/x/Projects/vault", directoryHint: .isDirectory)
        for source in [Anchor.Source.automatic, .pinned] {
            let repository = Anchor(url: url, kind: .repository, source: source)
            #expect(Anchor.promptRoot(of: repository) == url)
            #expect(Anchor.refusalRoot(of: repository) == url)
        }
        #expect(Anchor.promptRoot(of: nil) == nil)
        #expect(Anchor.refusalRoot(of: nil) == nil)
    }

    @Test func aPinnedRepositoryAnchorHasARootLikeAnAutomaticOne() {
        // The source decides how the anchor was chosen, never whether it has git
        // state. A guard written against `.automatic` would pass every test above
        // and silently blank the chrome of every pinned repository.
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
