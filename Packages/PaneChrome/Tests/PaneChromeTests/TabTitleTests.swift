import Foundation
import Testing

@testable import PaneChrome

@Suite struct TabTitleTests {
    @Test func anAgentWorktreeNameIsAbbreviatedButASuperpowersWorktreeNameIsShownVerbatim() {
        // Both layouts are in daily use in this workspace. The Agent tool's hex
        // id is noise past the sixth digit; a superpowers worktree's name *is*
        // the branch, and cutting it loses which piece of work the tab holds.
        #expect(TabTitle.title(anchorName: "agent-3f9c1a2b", isWorktree: true) == "agent-3f9c1a")
        #expect(TabTitle.title(anchorName: "exif-display-0725-1432", isWorktree: true)
            == "exif-display-0725-1432")
    }

    @Test func anAgentNameOutsideAWorktreeIsShownVerbatim() {
        // A repository the owner deliberately called `agent-deadbeef` keeps its
        // name. Outside the worktree layouts there is no hex id to throw away,
        // and the abbreviation would be silently eating half of a real project
        // name.
        #expect(TabTitle.title(anchorName: "agent-3f9c1a2b", isWorktree: false)
            == "agent-3f9c1a2b")
    }

    @Test func anUppercaseHexSuffixIsNotTreatedAsAnAgentIdentifier() {
        // The Agent tool writes lowercase. `Character.isHexDigit` would accept
        // this and cut a name the tool never generated.
        #expect(TabTitle.title(anchorName: "agent-ABCDEF12", isWorktree: true)
            == "agent-ABCDEF12")
    }

    @Test func aSuffixShorterThanTheAbbreviationIsLeftAlone() {
        // Nothing to gain, and `prefix(6)` on a shorter string returns it
        // whole, so an implementation without the length check would look
        // correct here and then accept `agent-x` as an identifier too.
        #expect(TabTitle.title(anchorName: "agent-3f9c", isWorktree: true) == "agent-3f9c")
        #expect(TabTitle.title(anchorName: "agent-", isWorktree: true) == "agent-")
    }

    @Test func aNonHexSuffixIsNotAnAgentIdentifier() {
        #expect(TabTitle.title(anchorName: "agent-rewrite-tests", isWorktree: true)
            == "agent-rewrite-tests")
    }

    @Test func uniqueTitlesKeepTheirBareLastComponent() {
        #expect(TabTitle.disambiguated(["~/Projects/baia", "~/Projects/vault"])
            == ["baia", "vault"])
    }

    @Test func aTitleWithNoParentsSurvivesDisambiguation() {
        // The output of title(anchorName:isWorktree:) has no path around it,
        // and feeding it straight in has to be a no-op rather than an empty
        // string.
        #expect(TabTitle.disambiguated(["baia", "vault"]) == ["baia", "vault"])
    }

    @Test func disambiguationAppendsTheParentOfARepeatedTitle() {
        #expect(TabTitle.disambiguated(["~/Projects/baia", "~/sandbox/baia"])
            == ["baia (Projects)", "baia (sandbox)"])
    }

    @Test func disambiguationGrowsTheParentPathUntilTheTitlesDiffer() {
        // One parent is not enough here, so the depth has to keep increasing. A
        // single-parent implementation would pass
        // disambiguationAppendsTheParentOfARepeatedTitle and return two
        // identical titles for this.
        #expect(TabTitle.disambiguated(["~/a/work/baia", "~/b/work/baia"])
            == ["baia (a/work)", "baia (b/work)"])
    }

    @Test func onlyTheRepeatedTitlesGrowAParent() {
        // A tab that was already unambiguous keeps its short name. Deepening
        // every entry whenever any pair collided would widen every tab in the
        // window because two of them happened to clash.
        #expect(TabTitle.disambiguated(["~/Projects/baia", "~/sandbox/baia", "~/Projects/vault"])
            == ["baia (Projects)", "baia (sandbox)", "vault"])
    }

    @Test func disambiguationTerminatesWhenTwoTitlesShareEveryComponent() {
        // Two panes on the same path is not an edge case, it is what splitting
        // a pane produces immediately. A loop that ran until the titles were
        // unique would never return, and this test would hang rather than fail.
        // Growing them to the full path instead is equally ambiguous and three
        // times as wide, so the pair is left where it is.
        #expect(TabTitle.disambiguated(["~/Projects/baia", "~/Projects/baia"])
            == ["baia", "baia"])
    }

    @Test func aRepeatedTitleStopsGrowingOnceItSeparatesFromTheOneItCanSeparateFrom() {
        // Two identical paths plus a third that differs. The identical pair
        // must not block the third from separating, and must not keep growing
        // after it has.
        #expect(TabTitle.disambiguated(["~/p/baia", "~/p/baia", "~/q/baia"])
            == ["baia (p)", "baia (p)", "baia (q)"])
    }

    @Test func disambiguationPreservesOrderAndCount() {
        let titles = ["~/a/baia", "~/Projects/vault", "~/b/baia", "~/Projects/shop"]
        let result = TabTitle.disambiguated(titles)
        #expect(result.count == titles.count)
        #expect(result == ["baia (a)", "vault", "baia (b)", "shop"])
    }

    @Test func noTitlesDisambiguateToNoTitles() {
        #expect(TabTitle.disambiguated([]) == [])
    }
}
