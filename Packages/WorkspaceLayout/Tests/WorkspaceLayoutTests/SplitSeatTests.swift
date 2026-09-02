import Testing

@testable import WorkspaceLayout

/// The seat decision: where a divider can sit for a stored ratio, and whether
/// this split should keep asking for it.
///
/// The 2026-07-31 loop is the load-bearing case. Thickness 671, ratio 0.5, the
/// first child stuck off the requested 335.5, three refusals, then `.spent`.
/// Everything else is a reset of that bound, or the clamp that keeps a request
/// legal in the first place.
@Suite struct SplitSeatTests {
    /// The measured loop: `[1, 0]` at thickness 671 asking for 335.5 and being
    /// given something else, every pass until AppKit gave up on the
    /// update-constraints count.
    @Test func threeRefusalsAtOneThicknessThenSpent() {
        var seat = SplitSeat()
        let thickness = 671.0
        let ratio = 0.5
        let stuck = 200.0
        let divider = 1.0

        for _ in 0 ..< 3 {
            #expect(
                seat.decide(
                    thickness: thickness,
                    ratio: ratio,
                    current: stuck,
                    dividerThickness: divider
                ) == .request(position: 335.5)
            )
            seat.observed(landed: false)
        }

        #expect(
            seat.decide(
                thickness: thickness,
                ratio: ratio,
                current: stuck,
                dividerThickness: divider
            ) == .spent
        )
    }

    /// A resize resets the count, because a position that was impossible at one
    /// width may be fine at another.
    @Test func aDifferentThicknessAtTheSameRatioRequestsAgain() {
        var seat = spentSeat()
        #expect(seat.decide(thickness: 671, ratio: 0.5, current: 200, dividerThickness: 1) == .spent)
        #expect(
            seat.decide(
                thickness: 800,
                ratio: 0.5,
                current: 200,
                dividerThickness: 1
            ) == .request(position: 400)
        )
    }

    /// The owner asking for something is worth three more attempts, whatever
    /// this split has been refused so far.
    @Test func ratioChangedRequestsAgainAtTheSameThickness() {
        var seat = spentSeat()
        #expect(seat.decide(thickness: 671, ratio: 0.5, current: 200, dividerThickness: 1) == .spent)
        seat.ratioChanged()
        #expect(
            seat.decide(
                thickness: 671,
                ratio: 0.5,
                current: 200,
                dividerThickness: 1
            ) == .request(position: 335.5)
        )
    }

    /// A split too small to give both panes their minimum has no legal position
    /// at all, and that answer is not a refusal.
    ///
    /// Interleaving no-legal-seat answers with legal ones at the SAME thickness
    /// pins the count without reading it: the thickness never changes, so no
    /// new-size reset can hide a refusal the no-legal-seat path quietly added.
    /// Three such answers plus two real refusals must still leave the budget
    /// unspent, which holds only if no-legal-seat counts nothing and resets
    /// nothing.
    @Test func noLegalSeatCountsNoRefusal() {
        var seat = SplitSeat()
        let divider = 1.0
        let tooSmall = SplitSeat.minimumPaneThickness * 2 + divider - 1
        #expect(
            seat.decide(
                thickness: tooSmall,
                ratio: 0.5,
                current: 0,
                dividerThickness: divider
            ) == .noLegalSeat
        )

        let thickness = 671.0
        let target = 335.5
        #expect(
            seat.decide(thickness: thickness, ratio: 0.5, current: 200, dividerThickness: divider)
                == .request(position: target)
        )
        seat.observed(landed: false)
        // Same thickness, but a divider as thick as the split: no legal seat.
        for _ in 0 ..< 3 {
            #expect(
                seat.decide(thickness: thickness, ratio: 0.5, current: 200, dividerThickness: thickness)
                    == .noLegalSeat
            )
        }
        #expect(
            seat.decide(thickness: thickness, ratio: 0.5, current: 200, dividerThickness: divider)
                == .request(position: target)
        )
        seat.observed(landed: false)
        // Two real refusals so far. A third ask is still granted; a fourth
        // would be `.spent`, so any count the no-legal-seat path added or
        // reset shows up here.
        #expect(
            seat.decide(thickness: thickness, ratio: 0.5, current: 200, dividerThickness: divider)
                == .request(position: target)
        )
        seat.observed(landed: false)
        #expect(
            seat.decide(thickness: thickness, ratio: 0.5, current: 200, dividerThickness: divider)
                == .spent
        )
    }

    /// Within a half point, the seat has landed. A non-zero count is spent
    /// intention, not a stuck ask, and it resets.
    ///
    /// The band is pinned from both sides: a first child 0.6 points off the
    /// target is still a request, 0.4 points off settles. The reset is pinned
    /// without reading the count: two refusals, a settle, then two more
    /// refusals must leave one ask in the budget, which holds only if the
    /// settle zeroed it. The settle comes before the third refusal because
    /// `.spent` is decided ahead of `.settled`: a spent split stops asking
    /// even when the seat would have landed.
    @Test func currentWithinToleranceSettlesAndResetsTheCount() {
        var seat = SplitSeat()
        let thickness = 671.0
        let ratio = 0.5
        let divider = 1.0
        let target = 335.5

        #expect(
            seat.decide(thickness: thickness, ratio: ratio, current: 200, dividerThickness: divider)
                == .request(position: target)
        )
        seat.observed(landed: false)
        #expect(
            seat.decide(thickness: thickness, ratio: ratio, current: target + 0.6, dividerThickness: divider)
                == .request(position: target)
        )
        seat.observed(landed: false)

        #expect(
            seat.decide(thickness: thickness, ratio: ratio, current: target + 0.4, dividerThickness: divider)
                == .settled
        )

        for _ in 0 ..< 2 {
            #expect(
                seat.decide(thickness: thickness, ratio: ratio, current: 200, dividerThickness: divider)
                    == .request(position: target)
            )
            seat.observed(landed: false)
        }
        #expect(
            seat.decide(thickness: thickness, ratio: ratio, current: 200, dividerThickness: divider)
                == .request(position: target)
        )
    }

    /// A request that landed is not a refusal. Two misses, one landing, and the
    /// budget is whole again: two more misses still leave an ask, where a seat
    /// that counted the landing would be spent.
    @Test func aLandedRequestResetsTheCount() {
        var seat = SplitSeat()
        let ask = { (seat: inout SplitSeat) -> SplitSeat.Decision in
            seat.decide(thickness: 671, ratio: 0.5, current: 200, dividerThickness: 1)
        }
        for _ in 0 ..< 2 {
            #expect(ask(&seat) == .request(position: 335.5))
            seat.observed(landed: false)
        }
        #expect(ask(&seat) == .request(position: 335.5))
        seat.observed(landed: true)
        for _ in 0 ..< 2 {
            #expect(ask(&seat) == .request(position: 335.5))
            seat.observed(landed: false)
        }
        #expect(ask(&seat) == .request(position: 335.5))
    }

    /// The exact fit: two minimums plus the divider is the smallest split that
    /// still has a seat, and its one legal position is the minimum itself.
    /// One point less has none.
    @Test func exactFitHasOneLegalSeatAndOnePointLessHasNone() {
        var seat = SplitSeat()
        let divider = 8.0
        let exact = SplitSeat.minimumPaneThickness * 2 + divider
        #expect(
            seat.decide(thickness: exact, ratio: 0.5, current: 0, dividerThickness: divider)
                == .request(position: SplitSeat.minimumPaneThickness)
        )
        #expect(
            seat.decide(thickness: exact - 1, ratio: 0.5, current: 0, dividerThickness: divider)
                == .noLegalSeat
        )
    }

    /// Clamping the applied position and not the stored ratio is deliberate.
    /// The tree keeps what the user asked for; the seat only names a legal
    /// place to put the divider.
    @Test func requestedPositionIsClampedToTheLegalRange() {
        var seat = SplitSeat()
        let thickness = 400.0
        let divider = 8.0
        let lowest = SplitSeat.minimumPaneThickness
        let highest = thickness - SplitSeat.minimumPaneThickness - divider

        #expect(
            seat.decide(
                thickness: thickness,
                ratio: 0.05,
                current: 200,
                dividerThickness: divider
            ) == .request(position: lowest)
        )

        seat = SplitSeat()
        #expect(
            seat.decide(
                thickness: thickness,
                ratio: 0.95,
                current: 200,
                dividerThickness: divider
            ) == .request(position: highest)
        )
    }
}

extension SplitSeatTests {
    /// Three refusals at the 2026-07-31 thickness, so the next `decide` at that
    /// size is `.spent` unless something deliberate happens.
    private func spentSeat() -> SplitSeat {
        var seat = SplitSeat()
        for _ in 0 ..< 3 {
            _ = seat.decide(
                thickness: 671,
                ratio: 0.5,
                current: 200,
                dividerThickness: 1
            )
            seat.observed(landed: false)
        }
        return seat
    }
}
