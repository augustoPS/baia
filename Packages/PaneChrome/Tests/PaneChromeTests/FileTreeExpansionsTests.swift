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

    /// The set on screen is the one this type has never been handed: `retarget`
    /// stores what it moves *away* from. Recording without taking it would write a
    /// session file holding every anchor of the run except the one being looked at
    /// when the owner quit.
    @Test func recordsTheLiveSetUnderTheAnchorItIsPointedAt() {
        var expansions = FileTreeExpansions()
        _ = expansions.retarget(to: "/repos/vault", keeping: [])
        _ = expansions.retarget(to: "/repos/baia", keeping: ["notes"])
        #expect(expansions.recording(["Sources", "Diagnostics"]) == [
            "/repos/vault": ["notes"],
            "/repos/baia": ["Diagnostics", "Sources"],
        ])
    }

    /// Sorted, because this goes into a file that is compared in tests and read by
    /// a human when a restore goes wrong, and `Set` has no order to encode.
    @Test func recordsEachAnchorsDirectoriesSorted() {
        var expansions = FileTreeExpansions()
        _ = expansions.retarget(to: "/repos/baia", keeping: [])
        #expect(expansions.recording(["b", "a", "c"])["/repos/baia"] == ["a", "b", "c"])
    }

    /// Nothing pointed anywhere yet, which is what a seed applied before the first
    /// refresh sees. The map fills and the caller keeps what it was showing.
    @Test func seedingBeforeAnyAnchorLeavesTheCallersSetAlone() {
        var expansions = FileTreeExpansions()
        #expect(expansions.seed(["/repos/baia": ["Sources"]], showing: []).isEmpty)
        #expect(expansions.retarget(to: "/repos/baia", keeping: []) == ["Sources"])
    }

    /// The ordering that decides whether any of this reaches the screen. A window's
    /// sidebar is refreshed as it opens and the session's expansions are applied
    /// once every window exists, so the surface has already been pointed at an
    /// anchor and shown it empty by the time the seed arrives.
    @Test func seedingAfterTheAnchorIsSetAnswersWithThatAnchorsStoredSet() {
        var expansions = FileTreeExpansions()
        _ = expansions.retarget(to: "/repos/baia", keeping: [])
        #expect(expansions.seed(["/repos/baia": ["Sources"]], showing: []) == ["Sources"])
    }

    /// The file describes the previous run. By the time it is applied the owner may
    /// have opened directories in this one, and those win.
    @Test func seedingDoesNotOverwriteAnAnchorThisRunAlreadyPutAway() {
        var expansions = FileTreeExpansions()
        _ = expansions.retarget(to: "/repos/baia", keeping: [])
        _ = expansions.retarget(to: "/repos/vault", keeping: ["opened-just-now"])
        _ = expansions.seed(["/repos/baia": ["from-the-file"]], showing: [])
        #expect(expansions.retarget(to: "/repos/baia", keeping: []) == ["opened-just-now"])
    }

    /// An anchor the file names and this run has not visited is taken, which is the
    /// whole point of carrying the map across a relaunch.
    @Test func seedingFillsAnAnchorThisRunHasNotVisited() {
        var expansions = FileTreeExpansions()
        _ = expansions.retarget(to: "/repos/baia", keeping: [])
        _ = expansions.seed(["/repos/vault": ["notes"]], showing: [])
        #expect(expansions.retarget(to: "/repos/vault", keeping: []) == ["notes"])
    }
}
