import AppKit
import PaneChrome

/// What a sidebar row looks like while it is being pointed at, pressed, and
/// answered.
///
/// Design v3 §2.3. Clicking a row writes a path onto the focused pane's prompt,
/// which is a real action with a real refusal, so the row owes four answers it
/// had none of: that it can be clicked, that it is being clicked, that the click
/// landed, and that it did not.
///
/// **Owned by the rows view rather than drawn by a control.** Every state here is
/// a fill and an ink, never a geometry: nothing moves, nothing resizes, and no
/// view in this column ever takes first responder, which is the constraint the
/// whole sidebar is built under.
///
/// **One clock, driven by hand.** The fades are interpolated in the view's own
/// `draw(_:)` rather than through `CALayer.opacity` the way the footer's frame
/// once
/// is, because a row is not a view: it is a rect inside one, and per-row layers
/// for a list that can hold a thousand entries is the wrong shape. A timer steps
/// the levels and invalidates only the rows that moved.
@MainActor
final class RowFeedback {
    /// How a click was answered. Landed and refused are deliberately not
    /// symmetric, and capture 10 is the argument.
    ///
    /// A landed click already has a loud confirmation: zsh brackets the inserted
    /// path and draws it highlighted on the prompt line, which is the largest
    /// thing on screen and exactly where the next keystroke goes. A second
    /// announcement here would be the app saying the same thing twice, so landing
    /// is the pressed fill released, marking which row was hit and nothing more.
    ///
    /// A refusal carries `alert` and takes the path's ink with it, because
    /// nothing else happens at all: the prompt does not move, and the only other
    /// signal is a beep, which is inaudible on a muted machine and
    /// indistinguishable from every other beep on an audible one.
    enum Answer { case landed, refused }

    /// `reducesMotion` is read at every transition rather than once, because the
    /// user can flip the setting while the app runs and the next click has to
    /// honour it. The default reads the workspace; a probe passes its own so the
    /// two policies can be graded in one process without touching the system.
    init(
        reducesMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        redraw: @escaping (Int) -> Void
    ) {
        self.reducesMotion = reducesMotion
        self.redraw = redraw
    }

    /// One tracking area per row the clip view can currently show, which is how a
    /// drawn list learns which row the pointer is over.
    ///
    /// **Enter and exit rather than `.mouseMoved`, which never arrives.** A single
    /// area over the whole view with `.mouseMoved` set was the first shape, and it
    /// produced entered and exited faithfully and not one move: traced on
    /// 2026-07-29 with `acceptsMouseMovedEvents` confirmed true on the window and a
    /// local `.mouseMoved` monitor beside it, and neither the owner nor the monitor
    /// saw a single event. Enter and exit are the mechanism that works, so the
    /// resolution has to come from the areas rather than from the event.
    ///
    /// Bounded by the *visible* rect and not by the list: a repository of ten
    /// thousand files is thirteen areas in a 220 pt section, rebuilt when the rows
    /// change or the clip view scrolls.
    static func trackingAreas(
        rows: Int,
        rowHeight: Double,
        in view: NSView,
        owner: AnyObject
    ) -> [NSTrackingArea] {
        let visible = view.visibleRect
        guard rows > 0, !visible.isEmpty else { return [] }
        let first = max(0, Int(visible.minY / rowHeight))
        let last = min(rows - 1, Int(visible.maxY / rowHeight))
        guard first <= last else { return [] }
        return (first ... last).compactMap { index in
            let row = NSRect(
                x: 0,
                y: Double(index) * rowHeight,
                width: view.bounds.width,
                height: rowHeight
            ).intersection(visible)
            guard !row.isEmpty else { return nil }
            return NSTrackingArea(
                rect: row,
                options: [.mouseEnteredAndExited, .activeInKeyWindow],
                owner: owner,
                userInfo: [Self.rowKey: index]
            )
        }
    }

    /// The row an enter or exit belongs to.
    static func row(of event: NSEvent) -> Int? {
        event.trackingArea?.userInfo?[Self.rowKey] as? Int
    }

    private static let rowKey = "baia.row"

    /// The row under the pointer, or nil when the pointer is elsewhere.
    var hovered: Int? {
        didSet {
            guard hovered != oldValue else { return }
            if let oldValue { fade(oldValue, to: 0, over: Self.hoverDuration) }
            if let hovered { fade(hovered, to: 1, over: Self.hoverDuration) }
        }
    }

    /// The row being held down. No transition either way: a press is a direct
    /// answer to a finger and anything that eased into it would read as lag.
    var pressed: Int? {
        didSet {
            guard pressed != oldValue else { return }
            if let oldValue { redraw(oldValue) }
            if let pressed { redraw(pressed) }
        }
    }

    /// Marks a row answered, which fades out from wherever the press left it.
    ///
    /// 220 ms, and no rise: the fill is already on screen under the finger, so
    /// animating it up first would be a flash the release did not earn. The
    /// refusal's ink rides the same level, so the two read as one gesture with two
    /// outcomes.
    ///
    /// **Reduce Motion removes the fade, not the answer.** The outcome's hold time
    /// is separate from its motion: with motion, the level fades from 1 to 0 over
    /// `answerDuration`; without it, the level sits at 1 for the same
    /// `answerDuration` and then drops in one step. Either way the result is on
    /// screen for as long, drawn in the same fill and ink, and is redrawn at once
    /// so the first frame after the click shows it.
    ///
    /// A newer answer on the same row replaces a pending hold rather than stacking
    /// two, and the hold reads the policy at the moment of the answer: toggling
    /// Reduce Motion under a pending hold neither cancels it nor animates it.
    func answer(_ answer: Answer, at row: Int) {
        answers[row] = answer
        levels[row] = 1
        holds[row]?.timer.invalidate()
        holds[row] = nil
        guard reducesMotion() else {
            fade(row, to: 0, over: Self.answerDuration)
            return
        }
        targets[row] = nil
        redraw(row)
        heldGeneration += 1
        let generation = heldGeneration
        holds[row] = (generation, Timer.scheduledTimer(withTimeInterval: Self.answerDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.release(row, generation: generation) }
        })
    }

    /// The fill a row is drawn with, or nil for a row with nothing on it.
    func fill(_ row: Int, in theme: PaneTheme) -> (colour: RGB, alpha: Double)? {
        if pressed == row, answers[row] == nil {
            return (theme.background.blended(with: theme.inkFocus, fraction: 0.16), 1)
        }
        guard let level = levels[row], level > 0 else { return nil }
        if let answer = answers[row] {
            let colour = switch answer {
            case .landed: theme.background.blended(with: theme.inkFocus, fraction: 0.16)
            case .refused: theme.background.blended(with: theme.alert, fraction: 0.24)
            }
            return (colour, level)
        }
        return (theme.selectedRowBackground, level)
    }

    /// The ink a refused row's path takes, or nil for every other row.
    ///
    /// Only the refusal touches the text. Hover and press are surfaces the row
    /// sits on; a refusal is a statement about the row itself.
    func ink(_ row: Int, in theme: PaneTheme) -> (colour: RGB, alpha: Double)? {
        guard answers[row] == .refused, let level = levels[row], level > 0 else { return nil }
        return (theme.alert, level)
    }

    /// Drops every level without animating, for a list that has been replaced
    /// under the pointer. A fade that outlived its row would colour whatever
    /// arrived at that index.
    func reset() {
        let touched = Set(levels.keys).union(answers.keys)
        levels = [:]
        answers = [:]
        targets = [:]
        timer?.invalidate()
        timer = nil
        for hold in holds.values { hold.timer.invalidate() }
        holds = [:]
        for row in touched { redraw(row) }
    }

    // MARK: - The clock

    private let redraw: (Int) -> Void
    private let reducesMotion: () -> Bool
    private var levels: [Int: Double] = [:]
    private var targets: [Int: (level: Double, step: Double)] = [:]
    private var answers: [Int: Answer] = [:]
    private var timer: Timer?
    /// One still-outcome hold per answered row under Reduce Motion. A second
    /// answer on the same row replaces the hold rather than stacking two.
    ///
    /// Each hold carries a generation beside its timer, and the timer's block
    /// captures **the generation** rather than the timer. `Timer` is not
    /// `Sendable`, so the block's own task-isolated parameter cannot cross into
    /// a main-actor closure: passing it there is a Swift 6 data-race error
    /// (`#SendingRisksDataRace`), which is what an identity check written as
    /// `holds[row] === timer` cost. A `UInt64` is `Sendable` and answers the same
    /// question, so the guard survives without weakening isolation anywhere.
    private var holds: [Int: (generation: UInt64, timer: Timer)] = [:]

    /// Monotonic, app-lifetime, never reused. A per-row counter would do, and
    /// this is one counter rather than a second dictionary to keep in step.
    private var heldGeneration: UInt64 = 0

    private static let hoverDuration = 0.15
    private static let answerDuration = 0.22
    private static let tick = 1.0 / 60

    private func fade(_ row: Int, to level: Double, over duration: Double) {
        guard !reducesMotion() else {
            // A pointer leaving a held outcome must not cut the hold short; the
            // hold's own release clears the answer when its time is up.
            if level == 0, holds[row] != nil { return }
            levels[row] = level
            targets[row] = nil
            if level == 0 { answers[row] = nil }
            redraw(row)
            return
        }
        targets[row] = (level, Self.tick / duration)
        start()
    }

    /// The end of a held outcome. The answer goes in one step, so the next hover
    /// of that row is drawn as a hover and not in `alert`. Only the hold that is
    /// still current may release: one that `answer(_:at:)` or `reset()` replaced
    /// or cancelled has nothing left to clear. A pointer that arrived on the row
    /// during the hold keeps its hover fill instead of going dark under it.
    private func release(_ row: Int, generation: UInt64) {
        guard holds[row]?.generation == generation else { return }
        holds[row] = nil
        answers[row] = nil
        if hovered == row {
            levels[row] = 1
        } else {
            levels[row] = nil
            targets[row] = nil
        }
        redraw(row)
    }

    private func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
    }

    private func step() {
        for (row, target) in targets {
            let current = levels[row] ?? 0
            let next = current < target.level
                ? min(target.level, current + target.step)
                : max(target.level, current - target.step)
            levels[row] = next
            if next == target.level {
                targets[row] = nil
                // An answer outlives its fade only as long as the fade: leaving it
                // behind would draw the next hover of that row in `alert`.
                if next == 0 {
                    levels[row] = nil
                    answers[row] = nil
                }
            }
            redraw(row)
        }
        if targets.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }
}
