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

    // **Four tests pinned `PaneClusterMetrics.bottomArrangement`'s truth table
    // here until 2026-08-13.** They covered all four cells because the answer
    // froze into a pane for its whole lifetime, and a wrong cell was a pane
    // spawned with the wrong bottom edge that nothing downstream could correct
    // without resizing a live grid.
    //
    // The function and its `PaneBottomArrangement` are deleted. Two of the four
    // cells named the footer view, which is gone; with `clusterOnly` constant
    // the other two collapsed to the same answer, leaving a function whose
    // result depended on neither argument. There is no table left to pin, and a
    // test asserting a deleted enum's one surviving case would pin a tautology.
    //
    // **What those tests were really protecting is the spawn freeze, and that
    // is not testable from this package.** The freeze lives in
    // `TerminalPaneController.spawnedUnderGlass` (`lazy`, so the first read
    // fixes the pane's answer) and is consumed by
    // `ConfigurationCenter.apply(to:)`, both in the app target, which has no
    // test target — reaching either needs an `NSWindow` and a real surface.
    // These four never tested the freeze; they tested the pure function it
    // called, and the freeze was always carried by the `lazy` and by the doc
    // comments arguing it. Deleting them removes no coverage of it.
    //
    // The hazard is unchanged and still live: `resolvedChrome` moves under a
    // toggle (Reduce Transparency, a dark/light switch, an edited
    // `chromeStyle`), and handing a running pane a different
    // `window-padding-y` is the `SIGWINCH`-bearing grid resize the whole design
    // avoids. What guards it now is the `lazy` freeze plus
    // `Diagnostics/pane-glass-legibility`, which drives a real window. If this
    // package ever gets a pure decision to make about a spawning pane again,
    // this is where its table belongs.

    // MARK: - Fitting the pill to its pane

    /// The widths the shipped 11 pt monospace actually measures, so the pane
    /// numbers below are the ones a user hits rather than round fixtures.
    /// Measured 2026-08-13 through `NSAttributedString.size().width`, the same
    /// call `PaneClusterView.remeasure()` makes.
    private var measuredWidths: [PaneClusterSegmentRole: Double] {
        [
            .operation: 74.7978515625, // CHERRY-PICK
            .place: 61.1982421875, // (a1b2c3d)
            .changes: 6.7998046875, // *
            .agent: 40.798828125, // claude
            .attention: PaneClusterMetrics.dotDiameter,
        ]
    }

    private var cherryPicking: [PaneClusterSegment] {
        [
            .init(role: .operation, text: "CHERRY-PICK"),
            .init(role: .place, text: "(a1b2c3d)"),
            .init(role: .changes, text: "*"),
        ]
    }

    /// **The failure band the fitting pass exists for.** Without a budget the
    /// pill takes its width from its content and is pinned by its top-right
    /// corner alone, so a pill wider than its pane hangs over the neighbour.
    ///
    /// The numbers are the point: `(a1b2c3d) *` is a 92.0 pt pill and the same
    /// pane mid-cherry-pick is 174.8 pt, so every pane between those two widths
    /// drew correctly until the operation arrived. Asserted as *what the pane
    /// gets*, not as "something was dropped", so a fix that dropped the wrong
    /// segment fails here too.
    @Test func aPaneTooNarrowForTheOperationKeepsThePlaceInstead() {
        let widths = measuredWidths
        // 174.80 with the operation; 92.00 without it. The 83 pt between them is
        // the band of panes this defect appeared in.
        let full = PaneClusterLayout.width(of: cherryPicking, widths: widths)
        #expect(abs(full - 174.80) < 0.01)
        #expect(
            abs(PaneClusterLayout.width(
                of: cherryPicking.filter { $0.role != .operation }, widths: widths
            ) - 92.00) < 0.01
        )

        // A 300 pt pane is fine and nothing is dropped — the case the original
        // comment reasoned from, kept so the fix cannot be "drop always".
        #expect(
            PaneClusterLayout.fitting(
                segments: cherryPicking,
                widths: widths,
                budget: PaneClusterLayout.pillWidthBudget(paneWidth: 300, cornerInset: 6)
            ).map(\.role) == [.operation, .place, .changes]
        )

        // A 120 pt pane is inside the band: its 108 pt budget cannot hold the
        // operation (174.8) but does hold `(a1b2c3d) *` (92.0). The operation is
        // the only thing given up — changes is *not*, because the fit keeps the
        // best-ranked set that fits rather than walking the drop order once.
        // (An earlier version of this pass dropped changes here too and left the
        // pill at 77.2 against 108 pt of room; see `fitting`'s doc.)
        #expect(
            PaneClusterLayout.fitting(
                segments: cherryPicking,
                widths: widths,
                budget: PaneClusterLayout.pillWidthBudget(paneWidth: 120, cornerInset: 6)
            ).map(\.role) == [.place, .changes]
        )

        // And the survivors genuinely fit, which is the whole claim: no pill
        // wider than its pane, so nothing to hang over the neighbour. 92.0 <= 108.
        #expect(
            PaneClusterLayout.width(
                of: [
                    .init(role: .place, text: "(a1b2c3d)"),
                    .init(role: .changes, text: "*"),
                ],
                widths: widths
            ) <= PaneClusterLayout.pillWidthBudget(paneWidth: 120, cornerInset: 6)
        )
    }

    /// The order is agent, changes, operation, place — least missed first — and
    /// it is a *precedence*, not a ratchet: at every budget the pill wears the
    /// best-ranked set of segments that fits, rather than whatever is left after
    /// walking the drop order once.
    ///
    /// **Every expectation below is arithmetic from ``measuredWidths``, computed
    /// by hand and shown, not read off what `fitting` returns.** The previous
    /// version of this test pinned the greedy implementation's own output —
    /// including a `(170, [.place, .attention])` step that was the overshoot
    /// defect written down as an invariant, with a comment calling it "a real
    /// property of these widths". A check whose expectations come from running
    /// the code under test grades nothing.
    ///
    /// A pill of n segments costs `sum(widths) + 8*(n-1) + 16`. The five
    /// relevant sets, worked out:
    ///
    ///   - `operation place changes agent attention`
    ///     = 74.80+61.20+6.80+40.80+6.00 + 8*4 + 16 = 237.59
    ///   - `operation place attention` = 74.80+61.20+6.00 + 8*2 + 16 = 174.00
    ///   - `place changes attention`   = 61.20+6.80+6.00  + 8*2 + 16 = 106.00
    ///   - `place attention`           = 61.20+6.00       + 8*1 + 16 =  91.20
    ///   - `changes agent attention`   = 6.80+40.80+6.00  + 8*2 + 16 =  85.60
    ///   - `attention`                 = 6.00             + 8*0 + 16 =  22.00
    @Test func theFitKeepsTheBestRankedSetThatActuallyFits() {
        let widths = measuredWidths
        let all: [PaneClusterSegment] = [
            .init(role: .operation, text: "CHERRY-PICK"),
            .init(role: .place, text: "(a1b2c3d)"),
            .init(role: .changes, text: "*"),
            .init(role: .agent, text: "claude"),
            .init(role: .attention, text: ""),
        ]

        let steps: [(budget: Double, roles: [PaneClusterSegmentRole], why: String)] = [
            // Everything fits.
            (400, [.operation, .place, .changes, .agent, .attention], "237.59 <= 400"),
            // 188 admits `operation place changes attention` (188.79)? No —
            // 188.79 > 188. Next rank down keeping place and operation is
            // `operation place attention` at 174.00, which fits.
            (188, [.operation, .place, .attention], "174.00 <= 188 < 188.79"),
            // The step the old test got wrong. At 170 the operation cannot stay
            // beside place (174.00 > 170), so operation is given up — and the
            // room it frees is then spent on changes *and* agent, both of which
            // the greedy version had already thrown away for nothing:
            // `place changes agent attention` = 61.20+6.80+40.80+6.00 + 8*3 + 16
            // = 154.80, which fits in 170. Keeping agent as well is not a
            // consolation prize: it costs nothing any more precious segment
            // needed, and the precedence vector (place, operation, changes,
            // agent) reads 1,0,1,1 against 1,0,1,0 for dropping it.
            (170, [.place, .changes, .agent, .attention], "154.80 <= 170 < 174.00"),
            // 120 cannot hold agent too (154.80 > 120) but holds changes.
            (120, [.place, .changes, .attention], "106.00 <= 120 < 154.80"),
            // Below `place changes attention` (106.00) but above
            // `place attention` (91.20): changes is the one given up.
            (100, [.place, .attention], "91.20 <= 100 < 106.00"),
            // Under 91.20 no set containing place fits at all, so precedence
            // falls through a rank and the budget buys changes and agent
            // instead. Non-monotonic in place, and correct: see `fitting`'s doc.
            (91, [.changes, .agent, .attention], "91.20 > 91, 85.60 <= 91"),
            // Under 85.60: agent is the first given up at this rank.
            (85, [.changes, .attention], "36.80 <= 85 < 85.60"),
            // Under `changes attention` (36.80): the dot alone.
            (30, [.attention], "22.00 <= 30 < 36.80"),
            // Under even the dot's own pill. Nothing droppable is left and the
            // dot survives anyway.
            (20, [.attention], "22.00 > 20, dot is undroppable"),
        ]
        for (budget, roles, why) in steps {
            #expect(
                PaneClusterLayout.fitting(segments: all, widths: widths, budget: budget)
                    .map(\.role) == roles,
                "budget \(budget): \(why)"
            )
        }
    }

    /// The property behind the table above, checked against a brute-force oracle
    /// rather than against a second copy of the algorithm.
    ///
    /// For every budget on a fine sweep, the oracle enumerates all subsets of the
    /// droppable roles independently of `fitting`, keeps those that fit, and
    /// picks the best by the same lexicographic precedence the doc states —
    /// place, then operation, then changes, then agent. `fitting` must agree.
    /// This is what fails if the implementation ever returns a set that fits but
    /// is not the best one (the overshoot defect), or one that is best-ranked but
    /// does not fit.
    @Test func theFitIsTheBestRankedSetThatFitsRatherThanTheFirstOne() {
        let widths = measuredWidths
        let all: [PaneClusterSegment] = [
            .init(role: .operation, text: "CHERRY-PICK"),
            .init(role: .place, text: "(a1b2c3d)"),
            .init(role: .changes, text: "*"),
            .init(role: .agent, text: "claude"),
            .init(role: .attention, text: ""),
        ]
        let droppable = PaneClusterLayout.dropOrder
        // Most precious first, which is the drop order reversed.
        let precedence = Array(droppable.reversed())

        for step in stride(from: 0.0, through: 260, by: 0.5) {
            // The oracle: all 16 subsets, filtered to those that fit, ranked.
            var bestRoles: [PaneClusterSegmentRole]?
            var bestRank: [Int]?
            for mask in 0..<(1 << droppable.count) {
                var kept: Set<PaneClusterSegmentRole> = []
                for (index, role) in droppable.enumerated() where mask & (1 << index) != 0 {
                    kept.insert(role)
                }
                let candidate = all.filter {
                    kept.contains($0.role) || !droppable.contains($0.role)
                }
                guard PaneClusterLayout.width(of: candidate, widths: widths) <= step
                else { continue }
                let rank = precedence.map { kept.contains($0) ? 1 : 0 }
                if let current = bestRank, !current.lexicographicallyPrecedes(rank) { continue }
                bestRank = rank
                bestRoles = candidate.map(\.role)
            }
            // Nothing fits at all: the undroppable roles survive regardless.
            let expected = bestRoles ?? all.filter { !droppable.contains($0.role) }.map(\.role)

            #expect(
                PaneClusterLayout.fitting(segments: all, widths: widths, budget: step)
                    .map(\.role) == expected,
                "budget \(step)"
            )
        }
    }

    /// No survivor set ever exceeds the budget it was fitted to — the claim the
    /// whole pass exists for, since a pill wider than its pane is the thing that
    /// draws over the neighbour. Checked on every subset of the segments, so a
    /// status carrying only some of the roles is covered too, and at budgets
    /// down to zero.
    ///
    /// The one documented exception is a budget too small for the undroppable
    /// roles alone: the attention dot is never given up, so a pane narrower than
    /// 22 pt still wears its dot. Asserted as exactly that, rather than skipped.
    @Test func aFittedPillNeverExceedsItsBudget() {
        let widths = measuredWidths
        let all: [PaneClusterSegment] = [
            .init(role: .operation, text: "CHERRY-PICK"),
            .init(role: .place, text: "(a1b2c3d)"),
            .init(role: .changes, text: "*"),
            .init(role: .agent, text: "claude"),
            .init(role: .attention, text: ""),
        ]
        let undroppableOnly = all.filter { !PaneClusterLayout.dropOrder.contains($0.role) }
        let floor = PaneClusterLayout.width(of: undroppableOnly, widths: widths)

        for mask in 0..<(1 << all.count) {
            let segments = all.enumerated()
                .filter { mask & (1 << $0.offset) != 0 }
                .map(\.element)
            for step in stride(from: 0.0, through: 260, by: 2.5) {
                let kept = PaneClusterLayout.fitting(
                    segments: segments, widths: widths, budget: step
                )
                let width = PaneClusterLayout.width(of: kept, widths: widths)
                guard width > step else { continue }
                // Over budget is allowed only when the undroppable roles alone
                // already exceed it.
                #expect(
                    kept.allSatisfy { !PaneClusterLayout.dropOrder.contains($0.role) }
                        && step < floor,
                    "budget \(step) kept \(kept.map(\.role)) at \(width)"
                )
            }
        }
    }

    /// The dot is never dropped. It is 6 pt, it is what a pane is scanned for
    /// from across the window, and the approval popover reserves a position
    /// against it (`PaneClusterView.approvalAnchorRect()`), so a fitting pass
    /// that could drop it would move a popover's anchor by narrowing a pane.
    @Test func theAttentionDotSurvivesEveryBudget() {
        let widths = measuredWidths
        let all: [PaneClusterSegment] = [
            .init(role: .operation, text: "CHERRY-PICK"),
            .init(role: .place, text: "(a1b2c3d)"),
            .init(role: .changes, text: "*"),
            .init(role: .agent, text: "claude"),
            .init(role: .attention, text: ""),
        ]
        // The claim is that the dot is *present* at every budget, which is what
        // the popover's anchor depends on — not that it is alone.
        //
        // **This test asserted `== [.attention]` at every budget below 91.20
        // until 2026-08-13, and that was the greedy overshoot written down as an
        // invariant.** Dropping until the survivors fit emptied the pill down to
        // the dot far earlier than the arithmetic requires: at a budget of 50 the
        // pill can afford `changes attention` (36.80) and at 91 it can afford
        // `changes agent attention` (85.60). Pinning "only the dot" made the
        // defect look like the specification. The dot's survival is the property;
        // what accompanies it is `theFitKeepsTheBestRankedSetThatActuallyFits`'
        // business.
        for budget in [0.0, 1, 10, 22, 50, 91] {
            let kept = PaneClusterLayout.fitting(segments: all, widths: widths, budget: budget)
            #expect(kept.map(\.role).contains(.attention), "budget \(budget)")
        }

        // The genuinely load-bearing end of the range: below the dot's own 22 pt
        // pill nothing droppable is left, and it survives anyway rather than the
        // pill emptying. `fitting` runs out of candidates and keeps the
        // undroppable roles.
        for budget in [0.0, 1, 10, 20] {
            let kept = PaneClusterLayout.fitting(segments: all, widths: widths, budget: budget)
            #expect(kept.map(\.role) == [.attention], "budget \(budget)")
        }

        // And `dropOrder` is the reason, not luck: attention is not in it.
        #expect(!PaneClusterLayout.dropOrder.contains(.attention))
        #expect(!PaneClusterLayout.dropOrder.contains(.notice))
    }

    /// Segments are dropped whole, never cut. `CHERRY-P` in warn ink is a fact
    /// the owner cannot act on wearing the colour that says act now, and the
    /// capsule's own grammar is "absent, never empty". Asserted as every
    /// survivor keeping its exact text.
    @Test func aDroppedSegmentIsGoneRatherThanTruncated() {
        let widths = measuredWidths
        for budget in stride(from: 0.0, through: 200, by: 7) {
            let kept = PaneClusterLayout.fitting(
                segments: cherryPicking, widths: widths, budget: budget
            )
            for segment in kept {
                let original = cherryPicking.first { $0.role == segment.role }
                #expect(segment.text == original?.text, "budget \(budget)")
            }
        }
    }

    /// The pill budget and the notice budget are one reservation, differing by
    /// exactly the pill's own two insets. Pinned so the two cannot drift: a
    /// notice's glyphs and a resting pill are bounded by the same pane.
    @Test func thePillBudgetIsTheNoticeBudgetPlusThePillsOwnPadding() {
        for pane in [600.0, 300, 120, 40] {
            for inset in [6.0, 40] {
                #expect(
                    PaneClusterLayout.pillWidthBudget(paneWidth: pane, cornerInset: inset)
                        - PaneClusterLayout.noticeTextBudget(paneWidth: pane, cornerInset: inset)
                        == PaneClusterMetrics.horizontalInset * 2
                        || PaneClusterLayout.noticeTextBudget(
                            paneWidth: pane, cornerInset: inset
                        ) == 0
                )
            }
        }
        // 600 - 6 - 6 = 588, the pill's whole allowance on the shipped inset.
        #expect(PaneClusterLayout.pillWidthBudget(paneWidth: 600, cornerInset: 6) == 588)
        #expect(PaneClusterLayout.pillWidthBudget(paneWidth: 0, cornerInset: 6) == 0)
        #expect(PaneClusterLayout.pillWidthBudget(paneWidth: -100, cornerInset: 6) == 0)
    }

    /// `width(of:widths:)` answers what `solve` + `pillWidth` would, which is
    /// what lets the budget be applied before a placement exists. Two
    /// derivations of one number is two chances to drop a gap.
    @Test func theBudgetsWidthIsThePlacementsWidth() {
        let widths = measuredWidths
        let cases: [[PaneClusterSegment]] = [
            cherryPicking,
            [.init(role: .place, text: "(a1b2c3d)")],
            [.init(role: .place, text: "x"), .init(role: .attention, text: "")],
            [],
        ]
        for segments in cases {
            #expect(
                PaneClusterLayout.width(of: segments, widths: widths)
                    == PaneClusterLayout.pillWidth(
                        for: PaneClusterLayout.solve(segments: segments, widths: widths)
                    )
            )
        }
    }
}
