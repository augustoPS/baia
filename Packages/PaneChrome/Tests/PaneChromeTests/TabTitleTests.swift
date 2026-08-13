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

    // MARK: - The tab grammar

    @Test func aTabNoLongerSpendsAQuarterOfItselfOnTheAppName() {
        // Every tab used to open with `baia — `, about 56 pt of a 240 pt tab, to
        // say the one thing every tab in the bar had in common. The window
        // already knows which application it belongs to, and so does the person
        // reading it.
        #expect(TabTitle.tab(project: "vault") == "vault")
        #expect(!TabTitle.tab(project: "vault").contains("baia"))
    }

    @Test func onlyAnUnacknowledgedPaneEarnsTheAskingGlyph() {
        // An acknowledged pane shows nothing in the tab: you have already been
        // there, and the tab is not where you were told about it. Keeping the
        // glyph would leave a bar of exclamation marks that no longer mean
        // anything is new, which is the state the single `Blow.aiff` was in.
        #expect(TabTitle.tab(project: "vault", attention: .asking) == "! vault")
        #expect(TabTitle.tab(project: "vault", attention: .acknowledged) == "vault")
        #expect(TabTitle.tab(project: "vault", attention: .none) == "vault")
    }

    @Test func aDonePaneEarnsNoTabGlyph() {
        // The ✓ lives in the capsule alone. The tab grammar is the shipped rule.
        #expect(TabTitle.tab(project: "baia", attention: .done) == "baia")
    }

    @Test func aBusyPaneReadsAsBusyOnlyWhileItIsNotAsking() {
        // Asking outranks busy: both are true of a pane whose agent just stopped
        // to ask, and only one of them is worth a tab's width.
        #expect(TabTitle.tab(project: "vault", isBusy: true) == "\u{25D0} vault")
        #expect(TabTitle.tab(project: "vault", attention: .asking, isBusy: true) == "! vault")
    }

    @Test func theBranchNeverAppearsInATitle() {
        // Owner ruling 2026-08-12: the capsule is the one home for repo facts,
        // and the title slims to the anchor name. The branch used to appear as
        // `:branch` when it was not the default; now the capsule's place
        // segment owns it, and a title repeating it would be the duplication
        // the ruling exists to end.
        #expect(TabTitle.tab(project: "vault", branch: "main", isDefaultBranch: true) == "vault")
        #expect(TabTitle.tab(project: "vault", branch: "fix-auth", isDefaultBranch: false)
            == "vault")
        #expect(TabTitle.tab(project: "baia", branch: "exif-display", isDefaultBranch: false)
            == "baia")
    }

    @Test func branchAndMarkersLeaveTheTitleAtEveryBudget() {
        // Owner ruling 2026-08-12. The budget ladder used to drop the markers,
        // then the branch, as tabs were added; with both gone from the grammar
        // entirely there is nothing left for width pressure to drop, and every
        // budget renders the same title. The glyph and the project survive, as
        // they always did at the narrowest budget.
        let full = { (budget: TabTitle.Budget) in
            TabTitle.tab(
                project: "vault",
                branch: "fix-auth",
                isDefaultBranch: false,
                markers: "*?3",
                attention: .asking,
                budget: budget
            )
        }
        for budget in TabTitle.Budget.allCases {
            #expect(full(budget) == "! vault")
        }
    }

    @Test func theBudgetIsChosenFromTheTabCount() {
        #expect(TabTitle.Budget.forTabCount(1) == .everything)
        #expect(TabTitle.Budget.forTabCount(2) == .everything)
        #expect(TabTitle.Budget.forTabCount(3) == .withoutMarkers)
        #expect(TabTitle.Budget.forTabCount(4) == .withoutMarkers)
        #expect(TabTitle.Budget.forTabCount(5) == .withoutBranch)
        #expect(TabTitle.Budget.forTabCount(6) == .withoutBranch)
        #expect(TabTitle.Budget.forTabCount(7) == .projectOnly)
        #expect(TabTitle.Budget.forTabCount(40) == .projectOnly)
    }

    @Test func theStateGlyphSurvivesEveryBudget() {
        // The one part that is never dropped. Two characters answer the question
        // the whole feature exists for, and a seven-tab window is precisely where
        // "which one wants me" is hardest to answer by looking.
        for budget in TabTitle.Budget.allCases {
            #expect(TabTitle.tab(project: "vault", attention: .asking, budget: budget)
                .hasPrefix("!"))
        }
    }

    @Test func theProjectNameIsNeverTruncatedHere() {
        // A tab nobody can identify is the failure the bar exists to prevent, so
        // truncation is left to AppKit, which does it per tab rather than to all
        // of them at once.
        let long = String(repeating: "verylongproject", count: 4)
        #expect(TabTitle.tab(project: long, budget: .projectOnly).contains(long))
    }

    // MARK: - The window title

    @Test func aQuietWindowIsCalledWhateverItsTabIsCalled() {
        #expect(TabTitle.windowTitle(waitingProjects: [], tab: "baia") == "baia")
    }

    @Test func oneOrTwoWaitingPanesAreNamedRatherThanCounted() {
        // A count answers "how many", which nobody asked. A name answers
        // "which", which is the entire reason the marker exists: the signal it
        // replaces was one identical sound per session, and the whole failure was
        // that it could not say which pane had made it.
        #expect(TabTitle.windowTitle(waitingProjects: ["vault"], tab: "baia")
            == "! vault  \u{00B7}  baia")
        #expect(TabTitle.windowTitle(waitingProjects: ["vault", "admin"], tab: "baia")
            == "! vault, admin  \u{00B7}  baia")
    }

    @Test func threeOrMoreFallBackToACountWhereNamingStopsPayingForItsWidth() {
        #expect(TabTitle.windowTitle(waitingProjects: ["vault", "admin", "shop"], tab: "baia")
            == "! 3 waiting  \u{00B7}  baia")
        #expect(TabTitle.windowTitle(waitingProjects: ["a", "b", "c", "d"], tab: "baia")
            == "! 4 waiting  \u{00B7}  baia")
    }

    @Test func theWindowKeepsItsOwnNameAfterTheAnnouncement() {
        // The announcement goes on every window, because a window nobody is
        // looking at is exactly the one the title has to speak for. Replacing the
        // window's own name with it would make every tab in the group read
        // identically for as long as anything was waiting.
        let title = TabTitle.windowTitle(waitingProjects: ["vault"], tab: "shop:fix-auth *")
        #expect(title.hasSuffix("shop:fix-auth *"))
        #expect(title.hasPrefix("! vault"))
    }

    @Test func theWindowTitleUsesTheSameGlyphAsTheFooterAndTheGitMarkers() {
        // `!` rather than a filled circle. It is already the glyph for "act now"
        // in the conflicted-files marker and in the capsule, and a second symbol
        // for one idea is one the reader has to learn separately.
        #expect(TabTitle.windowTitle(waitingProjects: ["vault"], tab: "baia").hasPrefix("!"))
    }

    // MARK: - The announcement alone

    @Test func aQuietWindowAnnouncesNothingAtAll() {
        // The owner's 2026-08-13 ruling removes the folder name from the
        // titlebar, and the name was the *entire* content of a quiet window's
        // title: `windowTitle(waitingProjects:tab:)` returns `tab` unchanged when
        // nothing is waiting. With the name gone there is nothing left to say, so
        // the title is empty rather than holding a placeholder.
        //
        // Empty rather than the path, which is the tempting substitution and the
        // wrong one: the path is the *subtitle*, and promoting it here would draw
        // it twice in one band.
        #expect(TabTitle.announcement(waitingProjects: []) == "")
    }

    @Test func theWaitingAnnouncementSurvivesTheNameLeaving() {
        // The half that must not die with the folder name.
        // `AttentionNotifier` documents the window title as the *primary*
        // carrier for "a pane is asking" — not a fallback — because
        // `NSApp.dockTile.badgeLabel` does nothing in this app, so the Window
        // menu, Mission Control and the window switcher are the only places a
        // background window can speak. Removing the name must not take the
        // announcement with it.
        #expect(TabTitle.announcement(waitingProjects: ["vault"]) == "! vault")
        #expect(TabTitle.announcement(waitingProjects: ["vault", "admin"]) == "! vault, admin")
    }

    @Test func theAnnouncementKeepsTheNameAndCountRuleItAlwaysHad() {
        // The naming-versus-counting threshold is unchanged by the name leaving:
        // it was never about the window's own name, only about the width two
        // project names are worth against three.
        #expect(TabTitle.announcement(waitingProjects: ["vault", "admin", "shop"]) == "! 3 waiting")
        #expect(TabTitle.announcement(waitingProjects: ["a", "b", "c", "d"]) == "! 4 waiting")
    }

    @Test func theAnnouncementNoLongerCarriesTheSeparatorThatJoinedItToTheName() {
        // The ` · ` existed only to join the announcement to the tab name behind
        // it. With nothing behind it, a trailing separator would be a dangling
        // piece of punctuation in the Window menu. A `hasSuffix` check rather
        // than equality, so this fails for a trailing space too.
        let announced = TabTitle.announcement(waitingProjects: ["vault"])
        #expect(!announced.contains("\u{00B7}"))
        #expect(announced == announced.trimmingCharacters(in: .whitespaces))
    }

    @Test func theAnnouncementAgreesWithTheTitleItReplaces() {
        // The two spellings must not drift. Whatever `windowTitle` puts before
        // its separator is exactly what `announcement` now says on its own, so
        // the glyph, the joiner and the counting threshold stay one rule rather
        // than becoming two that are free to disagree.
        for projects in [["vault"], ["vault", "admin"], ["a", "b", "c"]] {
            let joined = TabTitle.windowTitle(waitingProjects: projects, tab: "baia")
            #expect(joined == "\(TabTitle.announcement(waitingProjects: projects))  \u{00B7}  baia")
        }
    }
}
