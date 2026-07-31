import Foundation

/// How far one press of a grow key moves the divider, given how long the key has
/// been down.
///
/// **A constant could not answer both halves of what the key is for.**
/// ``PaneTree/keyboardResizeStep`` was chosen against two failures at once and the
/// reasoning stands, but it missed a third thing: a terminal reflows in whole
/// columns, so a constant 0.025 of a 1400 point window is a four-column jump
/// arriving at the system repeat rate, and the jump is what the owner felt on
/// 2026-07-30. It read as steps rather than as a resize. Below one column a press
/// moves the divider without moving anything readable, so smoothness was never
/// available: one cell is the quantum.
///
/// The answer is a ramp. A tap is one cell, which is the smallest move that
/// changes what the terminal shows and the precision the key was missing; a held
/// key reaches the old 0.025 in four repeats, about a third of a second, and
/// crosses the whole range in twenty presses where it used to take eighteen. Both
/// failures the constant was chosen against are dropped without taking either
/// trade.
///
/// **One cell is 0.005 here rather than a measurement.** This type has no idea
/// what a point is, for the reason ``PaneTree/adjustingRatio(forPane:direction:by:)``
/// gives: a step in points would move a nested divider by a larger share of its
/// own split than the root one by the same key. 0.005 of a 1400 point window is
/// seven points, near enough one column at the sizes this is used at, and it is
/// the largest such number that divides the clamp range whole.
///
/// Nested splits shrink it the same way they shrink the constant, which the
/// clamp's own note already records: 0.05 nested twice is a fraction of the
/// window. A first press deep in a grid moves less than a column, and the answer
/// there is to hold the key, which is what a ramp makes work.
public struct KeyboardResizeRamp: Equatable, Sendable {
    /// The rungs a press climbs before the plateau, in cells.
    ///
    /// Arithmetic, one cell to four, then ``PaneTree/keyboardResizeStep`` for as
    /// long as the key is down. Four rungs rather than more because the sum has to
    /// leave a whole number of plateau steps in the range: these four spend 0.05 of
    /// the 0.45 from centre to stop, and the remaining 0.40 is sixteen steps
    /// exactly, so a held key still lands *on* the stop rather than a step short of
    /// it with a remainder it can never spend. `theRampDividesTheClampRange` is
    /// that arithmetic asserted rather than trusted.
    private static let rungs = [0.005, 0.010, 0.015, 0.020]

    /// The direction the run is in, and nil before the first press.
    private var direction: FocusDirection?

    /// When the last press arrived, on whatever clock the caller is reading.
    private var lastPress: Double?

    /// How many presses into the current run, which is the index into the ladder.
    private var repeats = 0

    public init() {}

    /// The step for a press in `direction` at `time`, continuing the run if the
    /// last press was no more than `gap` ago in the same direction.
    ///
    /// **`gap` is the caller's, because only the caller knows the key repeat
    /// settings.** The app reads `NSEvent.keyRepeatDelay` and
    /// `NSEvent.keyRepeatInterval` rather than guessing, since someone who set a
    /// slow initial delay would otherwise have every first repeat read as a fresh
    /// tap and never reach the plateau at all.
    ///
    /// **A tap is always one cell, however many taps.** The run restarts whenever
    /// the gap is exceeded, so pressing deliberately four times moves four cells
    /// rather than climbing the ladder. That is what makes the key usable for the
    /// nudge it was unusable for before, and it is why this counts presses rather
    /// than accumulating a velocity that decays.
    ///
    /// A direction change restarts it too. Growing left and then right is two
    /// intentions, and carrying speed across the turn would overshoot the size the
    /// first one was aiming at.
    public mutating func step(
        growing direction: FocusDirection,
        at time: Double,
        continuingWithin gap: Double
    ) -> Double {
        let continues = direction == self.direction
            && lastPress.map { time - $0 <= gap && time >= $0 } ?? false
        repeats = continues ? repeats + 1 : 0
        self.direction = direction
        lastPress = time
        return Self.rungs.indices.contains(repeats)
            ? Self.rungs[repeats]
            : PaneTree.keyboardResizeStep
    }

    /// Ends the run, so the next press is a tap again.
    ///
    /// Called when focus moves. A focus change means the chord was released and
    /// another one pressed, and a divider at a fresh pane should start where every
    /// other first press starts rather than at whatever speed the last one reached.
    public mutating func release() {
        direction = nil
        lastPress = nil
        repeats = 0
    }
}
