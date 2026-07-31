import Testing

@testable import PaneChrome

/// The round trip the type exists for, and the three edges around it.
///
/// The failure being pinned is the one from 2026-07-30: two panes in different
/// repositories, levels open in one, focus away and back, and the expansions
/// gone. Everything here is stated as a sequence of `retarget` calls because that
/// is all the surface does with it.
@Suite struct FileTreeExpansionsTests {
    @Test func returnsToWhatAnAnchorWasLeftShowing() {
        var expansions = FileTreeExpansions()
        _ = expansions.retarget(to: "/repos/baia", keeping: [])
        _ = expansions.retarget(to: "/repos/vault", keeping: ["Sources", "Sources/PaneChrome"])
        #expect(expansions.retarget(to: "/repos/baia", keeping: []) == [
            "Sources", "Sources/PaneChrome",
        ])
    }

    /// The reason this is keyed rather than pruned: a name common to two
    /// repositories must not carry across.
    @Test func doesNotCarryAnOpenDirectoryIntoAnotherAnchor() {
        var expansions = FileTreeExpansions()
        _ = expansions.retarget(to: "/repos/baia", keeping: [])
        #expect(expansions.retarget(to: "/repos/vault", keeping: ["src"]).isEmpty)
    }

    /// The common case, and the one a redraw would be made out of.
    @Test func answersTheLiveSetWhenTheAnchorHasNotMoved() {
        var expansions = FileTreeExpansions()
        _ = expansions.retarget(to: "/repos/baia", keeping: [])
        let open: Set<String> = ["Sources", "Diagnostics"]
        #expect(expansions.retarget(to: "/repos/baia", keeping: open) == open)
    }

    /// A pane with no anchor lists nothing, and getting one back is not a loss.
    @Test func putsTheOpenSetAwayWhenTheAnchorGoesAway() {
        var expansions = FileTreeExpansions()
        _ = expansions.retarget(to: "/repos/baia", keeping: [])
        #expect(expansions.retarget(to: nil, keeping: ["Sources"]).isEmpty)
        #expect(expansions.retarget(to: "/repos/baia", keeping: []) == ["Sources"])
    }

    /// An anchor seen for the first time opens closed rather than inheriting
    /// whatever the surface happened to be holding.
    @Test func opensAnUnseenAnchorClosed() {
        var expansions = FileTreeExpansions()
        #expect(expansions.retarget(to: "/repos/baia", keeping: ["stale"]).isEmpty)
    }
}
