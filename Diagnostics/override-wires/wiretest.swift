import AppKit
import BaiaSettings
import PaneChrome

// Does each chrome extra in `DesignOverrides` actually reach the pixel it claims
// to move, and does an undialled override leave the rendering exactly where it
// was?
//
// The package tests answer that for everything decidable without a view
// (`PaneThemeAdjustmentsTests`: the ink ratios, the hexes, the bar lift, the busy
// dot's colour). What they cannot reach is a `draw(_:)` — the lift's ring,
// highlight and shadow, the rim, the footer's dot as actually filled — because
// those live in `Sources/`, which has no test target. This probe is that half.
//
// **No window server, no capture, no wallpaper.** Every arm renders a real
// shipped view into an offscreen `NSBitmapImageRep` through `cacheDisplay(in:to:)`
// and reads the bytes back. That makes each arm deterministic and machine
// independent: no focus is taken, no window appears, nothing is composited
// against whatever the owner's desktop happens to be, and two runs a week apart
// compare the same numbers. `glass-backdrop` needs a real compositor because its
// question is what glass *samples*; this probe's question is what this app's own
// drawing code puts down, which the app decides on its own.
//
// **Two arms per knob, and both are load-bearing.** The nil arm asserts that a
// view handed the defaults renders byte-identically to one whose properties were
// never touched — that is the "overrides nil changes nothing" acceptance, checked
// against actual bytes rather than read off the `??`. The dialled arm asserts the
// rendering moved. A nil arm alone cannot tell a working wire from a dead one,
// and a dialled arm alone cannot tell a wire from a rewrite.
//
// Every arm has a negative control, the same discipline `footer-corners` runs
// under: `run.sh` inverts each control, so a control that stops failing fails the
// run as loudly as an arm that stops passing.

// MARK: - offscreen rendering

/// `view` rendered into a bitmap, as bytes.
///
/// `cacheDisplay(in:to:)` rather than `NSImage`/`lockFocus`: it runs the view's
/// own `draw(_:)` and its layer tree into a rep this function owns, with no
/// window, no screen and no compositor in the path. A view that draws nothing
/// comes back as the rep's cleared contents, which is a real answer here — "the
/// rim off draws nothing" is precisely one of the claims under test.
///
/// The rep is created through `bitmapImageRepForCachingDisplay(in:)` so its
/// colour space and bit depth are the ones AppKit would give the view itself,
/// rather than a format this file picked and the view then rendered into
/// differently.
func render(_ view: NSView, size: NSSize) -> NSBitmapImageRep {
    view.frame = NSRect(origin: .zero, size: size)
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        fatalError("no bitmap rep for \(type(of: view))")
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

/// Whether two renderings are the same bytes.
///
/// Byte equality rather than a tolerance, deliberately. The claim being checked
/// is "renders byte-identically", and a tolerance would let a wire that shifted
/// every pixel by one level pass as unchanged — which is exactly the kind of
/// drift a default silently pinned to the wrong constant produces.
func identical(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
    guard let left = a.representation(using: .png, properties: [:]),
          let right = b.representation(using: .png, properties: [:])
    else { fatalError("a rep would not encode") }
    return left == right
}

/// How many of the two renderings' pixels differ, which is what separates "this
/// knob moved something" from "this knob moved the thing it names".
func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
    var count = 0
    for y in 0 ..< a.pixelsHigh {
        for x in 0 ..< a.pixelsWide {
            if a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { count += 1 }
        }
    }
    return count
}

// MARK: - fixtures

let paneSize = NSSize(width: 300, height: 120)

// `barSize`, `makeBar(theme:)` and the `busy-dot` and `bar-lift` arms lived
// here until 2026-08-13, when `Sources/PaneStatusBarView.swift` was deleted.
// They checked that `busyDotInk` and `barLift` reached a rendering, and the
// only view that ever rendered either was the footer. The two dials are still
// in `PaneThemeAdjustments`, so the question "does this dial reach a pixel"
// is re-aimable rather than answered — but at nothing yet: no surviving view
// draws a busy dot or lifts a bar. Dropped rather than half-ported, and left
// as a note so a future reader knows these dials lost their pixel witness
// instead of never having had one.

/// A lift view in the state that actually draws: visible, and with the window's
/// bottom corners rounded so the ring and the highlight both follow a curve
/// rather than a rectangle.
func makeLift(
    parameters: PaneLiftParameters = .shipped,
    rim: PaneRimParameters = .off
) -> PaneLiftView {
    let view = PaneLiftView(frame: NSRect(origin: .zero, size: paneSize))
    view.bottomCorners = [.left, .right]
    view.parameters = parameters
    view.rim = rim
    view.isVisible = true
    return view
}

/// The shipped palette, and a second one so no arm can pass by a coincidence of
/// the default theme.
let darkTheme = PaneTheme.darkPastel

// MARK: - arms

/// The arms' shared state: what has failed so far, and whether this run is a
/// negative control.
///
/// Held on an enum rather than as top-level `var`s so the whole file compiles
/// under the app target's own `-default-isolation MainActor`, which is what makes
/// "the shipped files are compiled verbatim under the rules they ship under" true
/// of this probe as well as of `footer-corners`.
@MainActor enum State {
    static var failures: [String] = []
    static var broken = false
}

@MainActor func check(_ passed: Bool, _ what: String) {
    print("  \(passed ? "ok  " : "FAIL") \(what)")
    if !passed { State.failures.append(what) }
}

@MainActor var broken: Bool { State.broken }

func armLiftNil() {
    print("== lift-nil: an untouched lift and an explicitly-shipped one render the same bytes")
    // The untouched view is never handed a `parameters` value at all, so this
    // compares the property's *default* against `.shipped` rather than comparing
    // `.shipped` with itself. That is what makes it an assertion about the
    // default rather than a tautology.
    let untouched = PaneLiftView(frame: NSRect(origin: .zero, size: paneSize))
    untouched.bottomCorners = [.left, .right]
    untouched.isVisible = true

    let explicit = makeLift(parameters: broken
        ? PaneLiftParameters(
            enabled: true, ringSpread: 4, ringAlpha: 0.9,
            innerHighlightOffsetY: 6, innerHighlightAlpha: 0.9,
            shadowDropOffsetY: 12, shadowDropBlur: 34, shadowDropAlpha: 0.6,
            duration: 0.22
        )
        : .shipped)

    check(
        identical(render(untouched, size: paneSize), render(explicit, size: paneSize)),
        "PaneLiftParameters.shipped renders what the untouched default renders"
    )
}

func armLiftRing() {
    print("== lift-ring: ringAlpha and ringSpread move the ring")
    let shipped = render(makeLift(), size: paneSize)

    var dialled = PaneLiftParameters.shipped
    if !broken { dialled.ringAlpha = 0.9 }
    check(
        !identical(shipped, render(makeLift(parameters: dialled), size: paneSize)),
        "ringAlpha 0.22 -> 0.9 changes the rendering"
    )

    var wider = PaneLiftParameters.shipped
    if !broken { wider.ringSpread = 6 }
    let widerRep = render(makeLift(parameters: wider), size: paneSize)
    check(!identical(shipped, widerRep), "ringSpread 0.5 -> 6 changes the rendering")
    // A wider ring covers strictly more of the pane's edge than a hairline, so
    // the count of moved pixels is the direction the knob names rather than
    // merely "something moved".
    check(
        differingPixels(shipped, widerRep) > 200,
        "ringSpread 6 moves a band of pixels, not a hairline"
    )
}

func armLiftHighlight() {
    print("== lift-highlight: innerHighlightAlpha and its offset move the top edge")
    let shipped = render(makeLift(), size: paneSize)

    var faded = PaneLiftParameters.shipped
    if !broken { faded.innerHighlightAlpha = 0 }
    check(
        !identical(shipped, render(makeLift(parameters: faded), size: paneSize)),
        "innerHighlightAlpha 0.30 -> 0 changes the rendering"
    )

    var taller = PaneLiftParameters.shipped
    if !broken { taller.innerHighlightOffsetY = 8 }
    check(
        !identical(shipped, render(makeLift(parameters: taller), size: paneSize)),
        "innerHighlightOffsetY 1 -> 8 changes the rendering"
    )
}

func armLiftEnabled() {
    print("== lift-enabled: switching the lift off takes the whole thing away")
    // Off is asserted against a view that was never made visible, not merely
    // against a different rendering: the claim `DesignOverrides.Chrome.Lift.enabled`
    // makes is "is the lift carrying its weight", which only means anything if
    // off is the same as absent.
    let absent = PaneLiftView(frame: NSRect(origin: .zero, size: paneSize))
    absent.bottomCorners = [.left, .right]

    var off = PaneLiftParameters.shipped
    if !broken { off.enabled = false }
    let disabled = makeLift(parameters: off)

    check(
        identical(render(absent, size: paneSize), render(disabled, size: paneSize)),
        "enabled = false renders what a lift that was never shown renders"
    )
}

func armRim() {
    print("== rim: off draws nothing, on draws the bright top edge")
    let withoutRim = render(makeLift(), size: paneSize)

    // Off is the default and the shipped rendering. This is the arm that says the
    // rim's first consumer added a knob without adding a pixel.
    check(
        identical(withoutRim, render(makeLift(rim: .off), size: paneSize)),
        "PaneRimParameters.off renders what the shipped lift renders"
    )

    var on = PaneRimParameters.off
    on.enabled = !broken
    on.topAlpha = 0.42
    let withRim = render(makeLift(rim: on), size: paneSize)
    check(!identical(withoutRim, withRim), "rim enabled changes the rendering")

    var brighter = on
    brighter.topAlpha = broken ? 0.42 : 0.95
    check(
        !identical(withRim, render(makeLift(rim: brighter), size: paneSize)),
        "rim topAlpha 0.42 -> 0.95 changes the rendering"
    )
}

func armSurfaceFill() {
    print("== surface-fill: each of the four roles resolves to its own colour, and nil to none")
    // The one wire with no `draw(_:)` behind it: a fill becomes an
    // `NSGlassEffectView.tintColor`, and what the compositor then does with a
    // tint is not something this process renders. So this arm checks the
    // resolution rather than a pixel, and the README says so rather than
    // claiming a pixel nobody saw move.
    check(SurfaceFill.colour(nil, in: .dark) == nil, "nil resolves to no tint at all")

    let roles: [DesignOverrides.Chrome.Material] = [.chrome, .sidebar, .thick, .menu]
    var seen: [NSColor] = []
    for role in roles {
        guard let colour = SurfaceFill.colour(role, in: .dark) else {
            check(false, "\(role) resolves to a colour")
            continue
        }
        check(true, "\(role) resolves to a colour")
        seen.append(colour)
    }
    // Four distinct colours, so no role is silently aliased onto another — which
    // is what a `default` in that switch would have allowed.
    let distinct = Set(seen.map { "\($0.redComponent),\($0.greenComponent),\($0.blueComponent),\($0.alphaComponent)" })
    check(
        distinct.count == (broken ? 5 : 4),
        "the four roles resolve to four distinct colours (\(distinct.count))"
    )

    // And the same four names answer differently under the light set, which is
    // what makes a dialled surface stay correct when the appearance flips.
    check(
        SurfaceFill.colour(.chrome, in: .dark) != SurfaceFill.colour(.chrome, in: .light),
        "one role resolves differently in the two material sets"
    )
}

// MARK: - main

@main
enum Probe {
    @MainActor static func main() {
        // Accessory, and nothing is ever ordered front: this probe opens no
        // window at all. The policy is set anyway so the process does not appear
        // in the Dock for the second it runs, the same courtesy every other probe
        // extends.
        NSApplication.shared.setActivationPolicy(.accessory)

        let arms: [String: @MainActor () -> Void] = [
            "lift-nil": armLiftNil,
            "lift-ring": armLiftRing,
            "lift-highlight": armLiftHighlight,
            "lift-enabled": armLiftEnabled,
            "rim": armRim,
            "surface-fill": armSurfaceFill,
        ]

        State.broken = CommandLine.arguments.contains("break")

        guard let name = CommandLine.arguments.dropFirst().first, let arm = arms[name] else {
            print("usage: wiretest <\(arms.keys.sorted().joined(separator: "|"))> [break]")
            exit(2)
        }

        if State.broken { print("(negative control: the thing under test is damaged)") }
        arm()

        if State.failures.isEmpty {
            print("PASS")
            exit(0)
        }
        print("FAIL")
        exit(1)
    }
}
