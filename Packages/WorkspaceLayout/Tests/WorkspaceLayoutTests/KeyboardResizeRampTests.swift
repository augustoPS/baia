import Testing

@testable import WorkspaceLayout

/// The ramp's two halves, and the arithmetic that keeps a held key landing on the
/// stop.
///
/// Times are seconds on an arbitrary clock, which is all the type is told. The gap
/// stands in for `NSEvent.keyRepeatDelay + NSEvent.keyRepeatInterval`, about half a
/// second at the macOS defaults.
@Suite struct KeyboardResizeRampTests {
    private let gap = 0.5

    /// One cell, which is the precision the constant did not have.
    @Test func aTapIsOneCell() {
        var ramp = KeyboardResizeRamp()
        #expect(ramp.step(growing: .left, at: 0, continuingWithin: gap) == 0.005)
    }

    /// Four deliberate taps are four cells, not a climb. Someone nudging a divider
    /// presses repeatedly, and a ramp that read that as a hold would take the
    /// precision back.
    @Test func tapsDoNotClimb() {
        var ramp = KeyboardResizeRamp()
        let steps = (0 ..< 4).map { ramp.step(growing: .left, at: Double($0), continuingWithin: gap) }
        #expect(steps == [0.005, 0.005, 0.005, 0.005])
    }

    /// Held, it climbs the four rungs and stays at the plateau.
    @Test func aHeldKeyReachesThePlateauInFourRepeats() {
        var ramp = KeyboardResizeRamp()
        let steps = (0 ..< 7).map {
            ramp.step(growing: .left, at: Double($0) * 0.09, continuingWithin: gap)
        }
        #expect(steps == [0.005, 0.010, 0.015, 0.020, 0.025, 0.025, 0.025])
        #expect(steps.dropFirst(4).allSatisfy { $0 == PaneTree.keyboardResizeStep })
    }

    /// Turning around is a second intention, and speed must not cross the turn.
    @Test func changingDirectionStartsOver() {
        var ramp = KeyboardResizeRamp()
        for press in 0 ..< 6 {
            _ = ramp.step(growing: .left, at: Double(press) * 0.09, continuingWithin: gap)
        }
        #expect(ramp.step(growing: .right, at: 0.54, continuingWithin: gap) == 0.005)
    }

    /// A focus change released the chord, whatever the clock says.
    @Test func releasingStartsOver() {
        var ramp = KeyboardResizeRamp()
        for press in 0 ..< 6 {
            _ = ramp.step(growing: .left, at: Double(press) * 0.09, continuingWithin: gap)
        }
        ramp.release()
        #expect(ramp.step(growing: .left, at: 0.54, continuingWithin: gap) == 0.005)
    }

    /// A clock that went backwards is not a continuation. Nothing in the app can
    /// produce one, since `systemUptime` is monotonic, but the comparison is
    /// arithmetic on a caller's number and a negative gap would read as inside the
    /// window.
    @Test func aBackwardClockStartsOver() {
        var ramp = KeyboardResizeRamp()
        for press in 0 ..< 6 {
            _ = ramp.step(growing: .left, at: Double(press) * 0.09, continuingWithin: gap)
        }
        #expect(ramp.step(growing: .left, at: -10, continuingWithin: gap) == 0.005)
    }

    /// The property the rung count was chosen for: held from the centre, the ramp
    /// spends the range exactly, so the last press lands on the stop rather than
    /// short of it with a remainder it can never spend.
    ///
    /// Twenty presses where the constant took eighteen, which at the default repeat
    /// rate is the second and a half the constant's own comment claims, plus two
    /// repeats.
    @Test func theRampDividesTheClampRange() {
        var ramp = KeyboardResizeRamp()
        var travelled = 0.0
        var presses = 0
        let span = 0.5 - PaneTree.clampedRatio(0)
        while travelled < span, presses < 100 {
            travelled += ramp.step(growing: .left, at: Double(presses) * 0.09, continuingWithin: gap)
            presses += 1
        }
        #expect(presses == 20)
        #expect(abs(travelled - span) < 1e-9)
    }

    /// The same walk against the tree it is for, rather than against arithmetic: it
    /// stops, it stops on the stop, and pressing again reports nothing to do.
    @Test func aHeldKeyCrossesToTheStopAndRefusesThere() {
        let a = PaneID()
        let b = PaneID()
        var tree = PaneTree.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        var ramp = KeyboardResizeRamp()
        var presses = 0
        while presses < 100 {
            let delta = ramp.step(growing: .left, at: Double(presses) * 0.09, continuingWithin: gap)
            guard let grown = tree.adjustingRatio(forPane: b, direction: .left, by: delta) else { break }
            tree = grown
            presses += 1
        }
        #expect(presses == 20)
        #expect(tree.ratio(at: SplitPath()) == PaneTree.clampedRatio(0))
    }
}
