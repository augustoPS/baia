import Testing
@testable import PaneChrome

@Suite struct PaneClusterLayoutTests {
    private let segments: [PaneClusterSegment] = [
        .init(role: .place, text: "design-v6-native"),
        .init(role: .changes, text: "↑1*?3"),
        .init(role: .agent, text: "claude"),
        .init(role: .attention, text: ""),
    ]

    private let widths: [PaneClusterSegmentRole: Double] = [
        .place: 100, .changes: 40, .agent: 44,
        .attention: PaneClusterMetrics.dotDiameter,
    ]

    @Test func segmentsPlaceLeftToRightInsideThePill() {
        let placed = PaneClusterLayout.solve(segments: segments, widths: widths)
        #expect(placed.map(\.segment.role) == segments.map(\.role))
        #expect(placed.first?.x == PaneClusterMetrics.horizontalInset)
        for pair in zip(placed, placed.dropFirst()) {
            #expect(pair.0.x + pair.0.width <= pair.1.x)
        }
    }

    @Test func pillWidthClosesWithTheTrailingInset() {
        let placed = PaneClusterLayout.solve(segments: segments, widths: widths)
        let last = placed.last!
        let expected = last.x + last.width + PaneClusterMetrics.horizontalInset
        #expect(PaneClusterLayout.pillWidth(for: placed) == expected)
        #expect(PaneClusterLayout.pillWidth(for: []) == 0)
    }

    @Test func hitTestResolvesTheSegmentUnderX() {
        let placed = PaneClusterLayout.solve(segments: segments, widths: widths)
        let changes = placed[1]
        #expect(PaneClusterLayout.segment(at: changes.x + 1, in: placed)?.role == .changes)
        #expect(PaneClusterLayout.segment(at: -5, in: placed) == nil)
        // The gap between two segments belongs to neither: a click there
        // opens nothing rather than whichever card is luckier.
        let gapX = changes.x + changes.width + PaneClusterMetrics.segmentGap / 2
        #expect(PaneClusterLayout.segment(at: gapX, in: placed) == nil)
    }

    @Test func theReservedDotOffsetIsTheSameWhicheverRestingSegmentsArePresent() {
        // `PaneClusterView.approvalAnchorRect()` reserves the attention dot's
        // distance from the pill's *trailing* edge so a notice — which takes the
        // pill alone — can still be told where the dot comes back to. That
        // reserve is only honest if the distance does not depend on what else is
        // on the pill, and here it is provably constant: `build` always appends
        // `.attention` last, `pillWidth` is `last.x + last.width +
        // horizontalInset`, so `pillWidth - dot.x` collapses to `dotDiameter +
        // horizontalInset` for every placement that ends in the dot.
        //
        // Pinned across the placements a real pane produces, so a reordering
        // that stopped putting attention last, or a metric change, fails here
        // rather than as a popover anchored a few points off the returning dot.
        let dot = PaneClusterSegment(role: .attention, text: "")
        let cases: [[PaneClusterSegment]] = [
            [dot],
            [.init(role: .place, text: "main"), dot],
            [.init(role: .place, text: "design-v6-native"), dot],
            [.init(role: .place, text: "design-v6-native"), .init(role: .changes, text: "↑1*?3"), dot],
            segments,
        ]
        for case_ in cases {
            let placed = PaneClusterLayout.solve(segments: case_, widths: widths)
            let hit = placed.first { $0.segment.role == .attention }!
            #expect(PaneClusterLayout.pillWidth(for: placed) - hit.x == 14)
        }

        // And 14 is those two metrics and not a coincidence of the fixture's
        // widths, so a deliberate change to either fails with the number named.
        #expect(PaneClusterMetrics.dotDiameter + PaneClusterMetrics.horizontalInset == 14)
    }

    // MARK: - The notice's width budget

    // The metrics these expectations are computed from, asserted once, apart
    // from the arithmetic that consumes them.
    //
    // **This split is the point, and the shape it replaces is one this
    // repository has been burned by twice.** The previous version built its
    // `expected` from `PaneClusterMetrics.cornerInset * 2` and
    // `horizontalInset * 2` — the same two constants, the same two operators,
    // the same order as the function body — and defended it as "spelled as
    // arithmetic so a moved metric moves the expectation". A test that recomputes
    // the arm it grades cannot fail for any arithmetic change a reader would call
    // a bug: a `+` for a `-`, a dropped term, a doubled inset all move both sides
    // together. `PaneClusterInkTests.theFaceIsTheOneTheOfferAlreadyGradesOn` is
    // the pattern kept here instead: pin the real number the function must
    // answer, and pin the constants separately so a deliberate metric change
    // fails *here*, once, naming itself, rather than passing silently.
    @Test func thePillsMetricsAreTheOnesTheseExpectationsAssume() {
        #expect(PaneClusterMetrics.cornerInset == 6)
        #expect(PaneClusterMetrics.horizontalInset == 8)
        #expect(PaneClusterMetrics.dotDiameter == 6)
        #expect(PaneClusterMetrics.segmentGap == 8)
    }

    @Test func theNoticeBudgetLeavesRoomAtBothEndsOfThePane() {
        // 600 - 6 - 6 (the corner insets the pill is pinned at, reserved at both
        // ends of the pane) - 8 - 8 (the pill's own padding) = 572. Pinned, so a
        // sign flip or a dropped term fails here.
        #expect(PaneClusterLayout.noticeTextBudget(paneWidth: 600, cornerInset: 6) == 572)
        #expect(PaneClusterLayout.noticeTextBudget(paneWidth: 200, cornerInset: 6) == 172)
    }

    @Test func aLargerInsetLeavesTheSentenceLessRoom() {
        // The dial (`chrome.cluster.cornerInset`) is what the pill is actually
        // pinned at, and the budget reserves it at both ends. Reading
        // `PaneClusterMetrics.cornerInset` here instead of the pinned value —
        // which is what the function did until the fifth review — over-allowed
        // by twice the difference, and at a dialled 40 the notice ran off the
        // pane's leading edge, the exact failure the budget exists to prevent.
        //
        // 600 - 40 - 40 - 8 - 8 = 504, sixty-eight points less than the same
        // pane at the shipped 6.
        #expect(PaneClusterLayout.noticeTextBudget(paneWidth: 600, cornerInset: 40) == 504)
        #expect(
            PaneClusterLayout.noticeTextBudget(paneWidth: 600, cornerInset: 40)
                < PaneClusterLayout.noticeTextBudget(paneWidth: 600, cornerInset: 6)
        )
    }

    @Test func theNoticeBudgetNeverGoesNegative() {
        // A pane mid-divider-drag is narrower than its own insets, and a
        // negative budget handed to a truncator is a crash or a garbage width.
        // Zero draws nothing, which is the harmless failure.
        #expect(PaneClusterLayout.noticeTextBudget(paneWidth: 0, cornerInset: 6) == 0)
        #expect(PaneClusterLayout.noticeTextBudget(paneWidth: 4, cornerInset: 6) == 0)
        #expect(PaneClusterLayout.noticeTextBudget(paneWidth: -100, cornerInset: 6) == 0)

        // And the exact boundary: a pane the width of the four insets (28 at
        // the shipped metrics) has no room for a glyph and answers zero rather
        // than a sliver.
        #expect(PaneClusterLayout.noticeTextBudget(paneWidth: 28, cornerInset: 6) == 0)
        #expect(PaneClusterLayout.noticeTextBudget(paneWidth: 38, cornerInset: 6) == 10)
    }

    @Test func theNoticeBudgetGrowsPointForPointWithThePane() {
        // Monotonic and unscaled, which is what makes a widened pane show more
        // of the sentence rather than re-cutting it somewhere arbitrary. Both
        // ends pinned, so a `paneWidth / 2` or a `paneWidth * 0.8` fails here —
        // a difference-only assertion holds for any function of the form
        // `paneWidth - k` and would not.
        #expect(PaneClusterLayout.noticeTextBudget(paneWidth: 300, cornerInset: 6) == 272)
        #expect(PaneClusterLayout.noticeTextBudget(paneWidth: 900, cornerInset: 6) == 872)
    }

    // MARK: - Where the sentence stops

    /// A measurer with one point per character, so the expectations below read
    /// as character counts. Deliberately not a real font: the decision under
    /// test is where the loop stops given widths, and a font would make every
    /// expectation a measurement of Menlo rather than of this function.
    private func oneWide(_ text: String) -> Double { Double(text.count) }

    @Test func aSentenceThatFitsIsReturnedUncut() {
        // Identical, not merely equal in prefix: a cut that rebuilt the string
        // character by character could return a value that differs in
        // normalisation while measuring the same.
        let text = "no repository here"
        #expect(PaneClusterLayout.noticeCut(text, budget: 100, measure: oneWide) == text)
        // And exactly at the budget, which is the boundary `<=` decides.
        #expect(PaneClusterLayout.noticeCut(text, budget: 18, measure: oneWide) == text)
    }

    @Test func anEmptyBudgetCutsEverything() {
        // A pane narrower than its own insets budgets zero, and zero must draw
        // nothing rather than one glyph.
        #expect(PaneClusterLayout.noticeCut("anything", budget: 0, measure: oneWide) == "")
        #expect(PaneClusterLayout.noticeCut("anything", budget: -5, measure: oneWide) == "")
    }

    @Test func aBudgetBetweenTwoCharactersStopsAtTheBoundaryNotPastIt() {
        // Five points buys five characters and never a sixth, which is the
        // whole contract: the pill's width is measured from what this returns,
        // so one character past the budget is one character off the pane.
        #expect(PaneClusterLayout.noticeCut("abcdefghij", budget: 5, measure: oneWide) == "abcde")
        // A fractional budget rounds the only honest way — down to what fits.
        #expect(PaneClusterLayout.noticeCut("abcdefghij", budget: 5.9, measure: oneWide) == "abcde")
        #expect(PaneClusterLayout.noticeCut("abcdefghij", budget: 1, measure: oneWide) == "a")
    }

    @Test func aMultiScalarClusterIsNeverSplitInHalf() {
        // `é` as `e` + U+0301, and a flag as two regional indicators: one
        // `Character` each, several scalars each. A loop walking scalars (or
        // UTF-16 units) would cut between them and render a combining mark on
        // nothing, or half a flag. Budget 1 admits exactly the first cluster.
        let combining = "e\u{0301}x"
        #expect(PaneClusterLayout.noticeCut(combining, budget: 1, measure: oneWide) == "e\u{0301}")
        #expect(PaneClusterLayout.noticeCut(combining, budget: 2, measure: oneWide) == combining)

        let flag = "🇧🇷ok"
        #expect(PaneClusterLayout.noticeCut(flag, budget: 1, measure: oneWide) == "🇧🇷")
        // And a budget that cannot afford even the first cluster returns
        // nothing rather than the scalars it is made of.
        #expect(PaneClusterLayout.noticeCut(flag, budget: 0.5, measure: oneWide) == "")
    }

    @Test func theCutMeasuresNoMoreCharactersThanTheSentenceCanCost() {
        // **Characters, not calls, because characters are the cost.** The
        // version of this test that stood here counted *invocations* and
        // asserted `calls <= 12` under the name
        // `theCutMeasuresProportionallyToTheStringNotToItsSquare` — a name the
        // assertion could not support. The loop measures a growing prefix
        // (`text[startIndex..<next]`), so its call count is O(n) while the
        // characters it hands the measurer are O(n²), and an invocation count
        // passes just as happily against an implementation measuring seventy
        // thousand characters. It also failed to discriminate the regression it
        // named: a `cut + character` accumulation makes exactly the same number
        // of calls.
        //
        // So this counts what `NSAttributedString.size()` is actually charged
        // for, and pins it exactly rather than loosely: a bound would let the
        // real cost drift underneath it, and an exact number is what makes the
        // doc comment's arithmetic checkable.
        func cost(_ text: String, budget: Double) -> (calls: Int, characters: Int) {
            var calls = 0
            var characters = 0
            _ = PaneClusterLayout.noticeCut(text, budget: budget) { measured in
                calls += 1
                characters += measured.count
                return Double(measured.count)
            }
            return (calls, characters)
        }

        // The real input: the longest refusal notice is sixty-six characters,
        // and a pane that admits sixty cuts it. One whole-string check plus
        // sixty-one prefixes that fit plus the first that does not = 62 calls;
        // the characters are 66 (the whole-string check) + 1 + 2 + … + 61 =
        // 1957. Two thousand characters of measurement, once per notice, is the
        // number `noticeCut`'s doc comment calls affordable — this is where that
        // claim is checked rather than asserted.
        let sentence = String(repeating: "x", count: 66)
        #expect(cost(sentence, budget: 60) == (calls: 62, characters: 1957))

        // And the shape of the curve, so "quadratic" is a measured fact here and
        // not a word in a comment: six times the sentence costs thirty-seven
        // times the measurement (382 calls, 73171 characters). A linear
        // implementation would answer about 6× instead.
        let long = String(repeating: "x", count: 400)
        #expect(cost(long, budget: 380) == (calls: 382, characters: 73171))
        #expect(cost(long, budget: 380).characters > cost(sentence, budget: 60).characters * 30)

        // The early return is what keeps the common case off that curve
        // entirely: a sentence that fits is measured once, whole, and the loop
        // never runs. This is the case nearly every notice takes, and it is why
        // the quadratic tail is reachable only on a pane narrower than the
        // sentence.
        #expect(cost(sentence, budget: 1000) == (calls: 1, characters: 66))
    }

    // MARK: - The spawn arrangement

    // The full truth table, all four cells, because the answer freezes into a
    // pane for its whole lifetime: a wrong cell here is a pane spawned with
    // the wrong bottom edge, and nothing downstream may correct it without
    // resizing a live grid.

    @Test func aClusterOnlySpawnUnderFlatRunsClearToTheBottom() {
        #expect(
            PaneClusterMetrics.bottomArrangement(clusterOnly: true, underGlass: false)
                == .fullHeightClear
        )
    }

    @Test func aClusterOnlySpawnUnderGlassRunsClearToTheBottom() {
        // Glass changes nothing once the footer is gone: the bump exists to
        // clear a bar overlapping the surface's last points, and there is no
        // bar to clear.
        #expect(
            PaneClusterMetrics.bottomArrangement(clusterOnly: true, underGlass: true)
                == .fullHeightClear
        )
    }

    @Test func aFooterSpawnUnderGlassRunsFullHeightWithTheBump() {
        #expect(
            PaneClusterMetrics.bottomArrangement(clusterOnly: false, underGlass: true)
                == .fullHeightWithBump
        )
    }

    @Test func aFooterSpawnUnderFlatInsetsAboveTheBar() {
        #expect(
            PaneClusterMetrics.bottomArrangement(clusterOnly: false, underGlass: false)
                == .insetAboveBar
        )
    }
}
