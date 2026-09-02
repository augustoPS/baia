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
        #expect(seat.refusals == 0)
    }

    /// Within a half point, the seat has landed. A non-zero count is spent
    /// intention, not a stuck ask, and it resets.
    @Test func currentWithinToleranceSettlesAndResetsTheCount() {
        var seat = SplitSeat()
        let thickness = 671.0
        let ratio = 0.5
        let divider = 1.0
        #expect(
            seat.decide(
                thickness: thickness,
                ratio: ratio,
                current: 200,
                dividerThickness: divider
            ) == .request(position: 335.5)
        )
        seat.observed(landed: false)
        #expect(seat.refusals == 1)

        #expect(
            seat.decide(
                thickness: thickness,
                ratio: ratio,
                current: 335.5,
                dividerThickness: divider
            ) == .settled
        )
        #expect(seat.refusals == 0)
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
        #expect(highest == 296)
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
