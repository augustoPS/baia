import AppKit
import BaiaSettings
import PaneChrome
import WorkspaceLayout

// The footer receives its value instead of owning it — and still keeps every
// invariant its `didSet` carried when it was the pane's store.
//
// **This probe exists because the behaviour it grades cannot fail in a package
// test.** On 2026-08-13 the canonical `PaneStatus` store moved off
// `PaneStatusBarView.status` onto `TerminalPaneController.status`, because five
// non-footer readers reached through a view that `chrome.cluster.mode: cluster`
// already hides and that is scheduled for deletion. The move is only safe if
// three things the footer's `didSet` does survive it, and all three are
// statements about an `NSView` and a `CALayer`:
//
//   1. change-gating — the same value handed in twice must not repaint.
//   2. the arrival pulse fires on the *transition* into asking, not on a
//      repaint that happens while the pane is already asking.
//   3. the wash's animations come off *before* the repaint, not after.
//
// None of those can be asked of a pure package: there is no `needsDisplay` to
// read and no layer to inspect. A package test asserting "setting the same value
// twice does not redraw" would pass in an empty harness where nothing redraws
// under any circumstances, which is worth nothing. So they are asked here, of
// the shipped view, with the real AppKit machinery underneath.
//
// **The shipped file is compiled verbatim** — not sliced, not retyped — the
// `cluster-notice` arrangement, including its note that a footer view reaches
// `WindowCorner` and nothing else in `Sources/`. `-default-isolation MainActor`
// matches the app target's `SWIFT_DEFAULT_ACTOR_ISOLATION`.
//
// **Safe from anywhere, including inside a baia pane.** No window is ever
// ordered on screen: the view is rendered through `cacheDisplay(in:to:)` into an
// offscreen bitmap, the same route `cluster-notice` and `cluster-legibility`
// take. Nothing reaches a compositor and nothing takes focus.
//
// Four arms, each with a negative control that must fail:
//
//   gated       a redundant write leaves the view clean, and a real change
//               dirties it. Control: the gate removed — the redundant write is
//               forced through the same body, which must dirty the view.
//   pulse       the transition none -> asking starts the wash animation.
//               Control: the same view already asking, handed a *different*
//               asking status, which must not re-pulse.
//   strip       acknowledging inside the pulse leaves the wash at 0 rather than
//               frozen at the alert colour. Control: the shipped bug's
//               ordering — strip after the repaint — which must freeze it at 1.
//   handed      the view draws whatever it is handed with no store of its own:
//               a controller-owned value reaches the pixels. Control: the value
//               withheld from the view, which must leave the capsule untinted.

// MARK: - offscreen rendering

/// Renders a view offscreen and returns its bitmap. Never ordered on screen.
@MainActor
func render(_ view: NSView) -> NSBitmapImageRep {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        fail("could not allocate a bitmap for the bar")
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

/// Whether any pixel in the bitmap is tinted — i.e. differs from the flat bar
/// beneath it by more than sampling noise. The capsule fill is the only thing
/// this bar paints that is not the bar itself.
func hasTintedPixel(_ rep: NSBitmapImageRep, unlike base: NSBitmapImageRep) -> Bool {
    for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 1) {
            guard let a = rep.colorAt(x: x, y: y), let b = base.colorAt(x: x, y: y)
            else { continue }
            let dr = abs(a.redComponent - b.redComponent)
            let dg = abs(a.greenComponent - b.greenComponent)
            let db = abs(a.blueComponent - b.blueComponent)
            if dr + dg + db > 0.05 { return true }
        }
    }
    return false
}

// MARK: - fixtures

/// A status with no agent: nothing to ask about, so `attention` is `.none`.
func restingStatus(anchorName: String = "baia") -> PaneStatus {
    PaneStatus(
        anchorName: anchorName,
        anchorIsRepository: true,
        isPinned: false,
        workingDirectory: nil,
        git: nil,
        agent: nil,
        notice: nil
    )
}

/// A status whose agent is waiting unacknowledged, which is what
/// `PaneStatus.Attention` reads as `.asking` and what tints the capsule.
func askingStatus(label: String = "claude") -> PaneStatus {
    var status = restingStatus()
    status.agent = PaneStatus.Agent(label: label, wantsAttention: true)
    return status
}

@MainActor
func makeBar() -> PaneStatusBarView {
    let bar = PaneStatusBarView(frame: NSRect(x: 0, y: 0, width: 420, height: 22))
    bar.theme = .darkPastel
    bar.attentionStyle = .loud
    bar.attentionAccent = .alert
    // Laid out once so the capsule has a rect to be drawn into; a zero-size
    // subview tree would make every arm trivially "untinted".
    bar.layoutSubtreeIfNeeded()
    return bar
}

/// Arms the repaint detector: writes a value into the wash that only a real
/// `invalidate()` can overwrite.
///
/// This is the instrument, and `needsDisplay` deliberately is not — see
/// `PaneStatusBarView.poisonWashForTesting()` for the four configurations in
/// which the dirty flag read identically for a gated write and an ungated one.
@MainActor
func arm(_ bar: PaneStatusBarView) {
    bar.poisonWashForTesting()
}

/// Whether the poison survived, i.e. whether the repaint was gated away.
@MainActor
func poisonSurvived(_ bar: PaneStatusBarView) -> Bool {
    bar.washOpacityForTesting == PaneStatusBarView.washPoisonForTesting
}

// MARK: - harness

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
    exit(1)
}

func check(_ condition: Bool, _ message: String) {
    if !condition { fail(message) }
}

// MARK: - arms

/// A redundant write must not dirty the view; a real change must.
///
/// Both halves are the arm. "Setting the same value twice does not redraw" is
/// only meaningful beside "and setting a different value does", or it passes in
/// a harness where nothing ever redraws — which is the failure mode this whole
/// probe was written against.
@MainActor
func armGated(broken: Bool) {
    let bar = makeBar()
    let status = restingStatus()
    bar.status = status

    arm(bar)
    if broken {
        // The control is the once-a-second poll with the gate taken off: the
        // same value handed in again, written straight past the observer and
        // then repainted, which is what the footer would do if the `guard`
        // were deleted. It must overwrite the poison — proving the arm's
        // "poison survived" is a real observation of a repaint that did not
        // happen, not an artefact of a harness where nothing ever repaints.
        bar.setStatusBypassingObserverForTesting(status)
        bar.applyStatusWithoutStrippingForTesting(status)
    } else {
        // The anchor tracker's redundant write: same value, second time.
        bar.status = status
    }

    check(
        poisonSurvived(bar),
        "an identical status repainted the bar: the change-gate is gone, and the "
            + "once-a-second anchor poll now repaints every pane's footer for nothing"
    )

    // The other half of the gate, and the arm is meaningless without it: a real
    // change must still get through. "Nothing repaints" would otherwise pass
    // the check above.
    //
    // **A resting change, deliberately not `askingStatus()`.** The transition
    // into asking fires `runArrivalPulse`, which writes the wash's opacity
    // directly, on a path that does not go through `invalidate` at all. Poisoned
    // opacity would then be cleared by the pulse rather than by the repaint this
    // half claims to watch, and the arm passed against a footer whose
    // `invalidate` had been deleted outright — the exact inertness the arm
    // exists to rule out, reintroduced by the one status that repairs itself
    // another way. Changing the anchor name repaints and does nothing else.
    arm(bar)
    bar.status = restingStatus(anchorName: "other")
    check(
        !poisonSurvived(bar),
        "a real change did not repaint the bar: the gate is swallowing real changes"
    )

    print("gated: redundant write repainted nothing, real change repainted")
}

/// The pulse fires on the transition into asking, and not on a repaint that
/// happens while the pane is already asking.
@MainActor
func armPulse(broken: Bool) {
    let bar = makeBar()
    bar.status = restingStatus()

    if broken {
        // Already asking, then handed a *different* asking status. This is the
        // repaint-while-waiting case: `became` is `.asking` too, so the
        // transition test in the `didSet` must refuse to pulse. If the pulse
        // were decided by the state rather than by the transition, this would
        // animate — which is the "blinks again on every git poll" bug.
        bar.status = askingStatus(label: "claude")
        _ = render(bar)
        bar.status = askingStatus(label: "codex")
    } else {
        bar.status = askingStatus()
    }

    let keys = bar.pulseAnimationKeysForTesting
    check(
        keys.isEmpty == broken,
        broken
            ? "a pane that repainted while still waiting pulsed again: the arrival "
                + "pulse is being decided by the state instead of by the transition"
            : "the transition into asking started no pulse"
    )
    print("pulse: \(broken ? "no re-pulse while waiting" : "fires on transition") (keys: \(keys))")
}

/// Acknowledging inside the pulse must leave the wash off, not frozen at the
/// alert colour.
///
/// The shipped ordering strips the wash's animations *before* `invalidate()`,
/// because `invalidate` only writes the wash's opacity when no animation is
/// running. The control reproduces the old ordering by leaving the pulse
/// running across the write, which is exactly what stripping-after produced.
@MainActor
func armStrip(broken: Bool) {
    let bar = makeBar()
    bar.status = restingStatus()
    bar.status = askingStatus()
    check(!bar.pulseAnimationKeysForTesting.isEmpty, "no pulse to acknowledge inside of")

    // Acknowledged mid-pulse: the pane stops asking while the 0.51 s animation
    // is still on the wash. The only difference between the two paths is where
    // the strip happens.
    var acknowledged = askingStatus()
    acknowledged.agent?.isAcknowledged = true

    if broken {
        // The bug's ordering: the animation is still on the layer when the
        // opacity is written, so `invalidate`'s write is skipped and the model
        // value stays at 1 with the alert colour behind it.
        bar.applyStatusWithoutStrippingForTesting(acknowledged)
    } else {
        bar.status = acknowledged
    }

    // The claim, stated once and asserted the same way down both paths: a pane
    // that has been acknowledged shows no alert wash. The shipped ordering
    // reaches it; the pre-2026-08-09 ordering does not, and that is the whole
    // difference the control exists to expose.
    let opacity = bar.washOpacityForTesting
    check(
        opacity < 0.5,
        "acknowledging inside the 0.51 s pulse left the wash at \(opacity): the "
            + "footer is frozen as a solid alert band until something else repaints it"
    )
    print("strip: wash opacity \(opacity) after \(broken ? "un-stripped" : "acknowledged") write")
}

/// The view holds no store of its own: a value owned elsewhere and handed in is
/// what reaches the pixels.
///
/// This is the arm that would have caught the move going wrong in the other
/// direction — a footer that kept a private copy, or a controller that built the
/// value and forgot to hand it down.
@MainActor
func armHanded(broken: Bool) {
    let resting = makeBar()
    resting.status = restingStatus()
    let base = render(resting)

    let bar = makeBar()
    if !broken {
        // The controller owns it; the view is handed it. The value never
        // originates in the view.
        let ownedElsewhere = askingStatus()
        bar.status = ownedElsewhere
    }
    // The control withholds the hand-down, which is a controller that built the
    // status and never passed it on.
    let shot = render(bar)

    let tinted = hasTintedPixel(shot, unlike: base)
    check(
        tinted != broken,
        broken
            ? "the capsule tinted with nothing handed in, so the view is keeping a "
                + "store of its own"
            : "a handed-in asking status never reached the pixels"
    )
    print("handed: capsule \(tinted ? "tinted" : "untinted") \(broken ? "without" : "with") a handed value")
}

// MARK: - entry

@main
enum Probe {
    @MainActor static func main() {
        let args = CommandLine.arguments
        guard let arm = args.dropFirst().first else {
            fail("usage: store <arm> [break]")
        }
        let broken = args.contains("break")

        switch arm {
        case "gated": armGated(broken: broken)
        case "pulse": armPulse(broken: broken)
        case "strip": armStrip(broken: broken)
        case "handed": armHanded(broken: broken)
        default: fail("unknown arm \(arm)")
        }
    }
}
