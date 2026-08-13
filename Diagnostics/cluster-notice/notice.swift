import AppKit
import BaiaSettings
import PaneChrome

// Does the capsule actually *draw* a refusal notice — ink on the pill, not just
// a segment in a solved layout — and does that ink clear the same contrast floor
// every other capsule text clears?
//
// **This probe exists because a green test suite said yes and the running app
// said no.** On 2026-08-13 the three-second refusal notice was rehomed from the
// retired footer onto this capsule. The whole package suite passed, three probes
// passed, and the sentence never appeared on screen. Pixel measurement is what
// caught it: the capsule band stayed a uniform #171717, brightest luminance
// 0.318, for the whole life of the notice.
//
// The defect was upstream of the capsule entirely. `AppDelegate.sendToPrompt`
// guarded on `anchor?.kind == .repository` and returned *before*
// `PromptPath.resolve` ran, so `showNotice` was never called on a
// non-repository pane and the view was never handed a notice to draw. The row
// still flashed red — that comes off the `false` return in
// `FilesSurface.mouseUp`, not off the refusal reason — so the refusal looked
// like it had run. The fix split the predicate in `ProjectAnchor.Anchor`
// (`promptRoot` for what may be sent, `refusalRoot` for what may be resolved);
// `AnchorTests.aPlainAnchorCanExplainARefusalWithoutBecomingSendable` pins it,
// and the README says why this probe does not re-pin it.
//
// **What this probe closes is the other half: nobody had watched the shipped
// build draw the sentence.** One measurement of luminance 0.318 -> 0.825 exists
// and it is single-sourced — four hand-driven attempts to reproduce it failed on
// harness flakiness (expired automation sessions, stale `screencapture -l`
// buffers, tree row-order changes moving the target row) rather than on code. A
// claim reproduced by nobody is a claim, so the reading moves here, where it is
// deterministic and repeatable.
//
// **The harness is `cluster-legibility`'s, and so is the grading.** The shipped
// `PaneClusterView` is compiled verbatim — not sliced, not retyped — and
// rendered offscreen through `cacheDisplay(in:to:)`, so the pixels graded are
// the pixels the app draws and nothing reaches a compositor. The pill's paint is
// plain translucent `NSColor` (backing at `ChromeMaterials.PaneWash.floor`, then
// the material fill), never an `NSGlassEffectView`, so the offscreen render is
// the full drawing route. Contrast is graded against
// `PaneTheme.minimumTextContrast`, read off the package rather than transcribed,
// and never derived from the arm it grades — this repo has been burned by that
// shape four times.
//
// Three arms, each with a negative control that must fail:
//
//   draws       ink appears on the pill when a notice is handed in.
//               Control: the same capsule with `notice = nil`.
//   bare-shell  the case that broke — no branch, no markers, no agent — still
//               produces a visible capsule under a notice.
//               Control: bare shell with no notice at all.
//   legible     `PaneClusterInk.noticeInk`'s ink clears the text floor over the
//               pill's own composited face.
//               Control: ink set to that face.

// MARK: - offscreen rendering

/// A full-bounds opaque fill for the capsule to composite over: the "document"
/// under the pill. Flipped to match the overlay family, so the capsule subview
/// and the container agree on where y = 0 is.
///
/// **It is also the pill's superview, which this probe needs and
/// `cluster-legibility` does not.** The notice is the one segment measured
/// against a budget (`PaneClusterLayout.noticeTextBudget`), and
/// `PaneClusterView.noticeText` reads that budget off `superview?.bounds.width`.
/// A capsule rendered with no superview passes the sentence through unbudgeted,
/// which is the pre-installation case, not the drawn one. So the backdrop is
/// sized to a realistic pane and the capsule is measured inside it.
final class BackdropView: NSView {
    var colour: NSColor = .black
    override var isFlipped: Bool { true }
    override func draw(_: NSRect) {
        colour.setFill()
        bounds.fill()
    }
}

/// The capsule rendered over an opaque backdrop inside a pane-sized superview,
/// as bytes.
///
/// `cluster-legibility`'s `renderOverBackdrop` with the pane added. The capsule
/// is installed first and only then given its segments, in that order and for a
/// stated reason: the notice's width is solved against the superview's width, so
/// a capsule handed its segments before it has a pane measures the sentence
/// against no budget and then never re-measures (`remeasure()` runs from the
/// `segments` setter, and setting the same value again is guarded out).
/// `cacheDisplay(in:to:)` runs the real `draw(_:)` with no window in the path.
@MainActor func renderInPane(
    _ view: PaneClusterView,
    segments: [PaneClusterSegment],
    backdrop: RGB,
    paneWidth: Double
) -> (rep: NSBitmapImageRep, pane: NSRect, capsule: NSRect) {
    let pane = NSRect(x: 0, y: 0, width: paneWidth, height: 120)
    let container = BackdropView(frame: pane)
    container.colour = nsSRGB(backdrop)
    container.addSubview(view)

    // Installed, then fed. See this function's doc for why the order is
    // load-bearing.
    view.segments = segments

    let size = view.intrinsicContentSize
    // The pill as the controller pins it: top-trailing, at the resolved corner
    // inset. Pinned rather than placed at the origin so the rendered geometry is
    // the shipped geometry — and so a notice that overran its budget would run
    // off the pane's leading edge here exactly as it would on screen.
    view.frame = NSRect(
        x: pane.width - PaneClusterMetrics.cornerInset - size.width,
        y: PaneClusterMetrics.cornerInset,
        width: size.width,
        height: size.height
    )
    container.layoutSubtreeIfNeeded()

    guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else {
        fatalError("no bitmap rep for the pane container")
    }
    container.cacheDisplay(in: container.bounds, to: rep)
    return (rep, pane, view.frame)
}

/// The pixel at a point given in the container's own points, as package `RGB`,
/// whatever scale the rep rendered at. Through `.sRGB` explicitly, matching the
/// space `PaneOverlayView.nsColor` draws in. `cluster-legibility`'s `sample`.
func sample(at point: NSPoint, in rep: NSBitmapImageRep, size: NSSize) -> RGB {
    let scale = Double(rep.pixelsWide) / Double(size.width)
    guard let colour = rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale)),
          let srgb = colour.usingColorSpace(.sRGB)
    else { fatalError("no pixel at \(point)") }
    return RGB(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
}

/// Relative luminance, WCAG's own definition — the same one `RGB.contrastRatio`
/// is built on, spelled here because the package exposes the ratio and not the
/// term. Used only to describe a band's brightness; every *grade* in this file
/// goes through `contrastRatio` against a package floor.
func luminance(_ rgb: RGB) -> Double {
    func channel(_ value: Double) -> Double {
        value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(rgb.red) + 0.7152 * channel(rgb.green) + 0.0722 * channel(rgb.blue)
}

/// Every pixel of a rect given in container points, as `RGB`.
func pixels(in rect: NSRect, rep: NSBitmapImageRep, size: NSSize) -> [RGB] {
    let scale = Double(rep.pixelsWide) / Double(size.width)
    var found: [RGB] = []
    for py in Int(rect.minY * scale) ..< Int(rect.maxY * scale) {
        for px in Int(rect.minX * scale) ..< Int(rect.maxX * scale) {
            guard let colour = rep.colorAt(x: px, y: py),
                  let srgb = colour.usingColorSpace(.sRGB) else { continue }
            found.append(RGB(
                red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent
            ))
        }
    }
    return found
}

/// The brightest pixel in a rect — `cluster-legibility`'s ink sampling: the
/// fully-covered glyph core, found by luminance sum, with antialiased edges
/// losing by construction.
func brightest(in rect: NSRect, rep: NSBitmapImageRep, size: NSSize) -> RGB {
    var best = -1.0
    var bestColour = RGB(red: 0, green: 0, blue: 0)
    for colour in pixels(in: rect, rep: rep, size: size) {
        let sum = colour.red + colour.green + colour.blue
        if sum > best {
            best = sum
            bestColour = colour
        }
    }
    return bestColour
}

/// Whether two colours agree within `tolerance` bytes on every channel.
func within(_ a: RGB, _ b: RGB, bytes tolerance: Double) -> Bool {
    abs(a.red - b.red) * 255 <= tolerance
        && abs(a.green - b.green) * 255 <= tolerance
        && abs(a.blue - b.blue) * 255 <= tolerance
}

func nsSRGB(_ rgb: RGB) -> NSColor {
    NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
}

func asRGB(_ colour: NSColor) -> RGB {
    guard let srgb = colour.usingColorSpace(.sRGB) else { fatalError("no sRGB form") }
    return RGB(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
}

// MARK: - fixtures

/// A real refusal sentence, not a placeholder: `PromptPath.Refusal.notUTF8`'s
/// own `notice` text, which is the longest of the three the resolver can produce
/// and therefore the one that exercises the budget. Copied rather than linked
/// because `PanePrompt` would add a package to the link line to supply one
/// string; the README names the source so a change there is findable.
let noticeText = "name is not valid UTF-8, so the shell cannot hold it: rename the file"

/// The pane the capsule is measured inside. 900 pt is a realistic half of a wide
/// window and comfortably wider than the sentence above needs, so the budget
/// does not cut it — a cut sentence is `PaneClusterLayout.noticeCut`'s subject
/// and is tested in the package, not here.
let paneWidth: Double = 900

/// The resting facts a repository pane wears, `cluster-legibility`'s own
/// fixture, built through the shipped derivation rather than hand-listed so the
/// probe cannot disagree with `PaneClusterSegments.build` about what a status
/// produces.
let repositoryStatus = PaneStatus(
    anchorName: "baia",
    anchorIsRepository: true,
    isPinned: false,
    workingDirectory: "/Users/x/Projects/baia",
    // `↑1*?3` at the pill, which is `PaneStatusSegments.markerText`'s rendering
    // of these numbers — the same marker string `cluster-legibility` hand-feeds
    // its fixture, produced here through the shipped derivation instead.
    git: PaneStatus.Git(
        head: "main",
        hasUpstream: true,
        ahead: 1,
        behind: 0,
        dirty: true,
        untracked: 3,
        conflicted: 0,
        operation: nil,
        isLinkedWorktree: false
    ),
    agent: PaneStatus.Agent(label: "working", wantsAttention: false)
)

/// **The pane that broke.** No repository, no agent, no attention: the bare
/// shell whose capsule is empty at rest. `PaneClusterSegments.build` answers
/// `[]` for this status and `[.notice]` once a notice is set, which
/// `PaneClusterSegmentsTests.aNoticeGivesABareShellPaneACapsule` pins at the
/// pure layer. This probe covers the drawn result of the same two states.
let bareShellStatus = PaneStatus(
    anchorName: "Projects",
    anchorIsRepository: false,
    isPinned: false,
    workingDirectory: "/Users/x/Projects",
    git: nil,
    agent: nil
)

/// A capsule in the state the pane feeds it, under glass chrome. Segments are
/// deliberately *not* set here — `renderInPane` sets them after installing the
/// view, because the notice's width is solved against the superview.
@MainActor func makeCapsule(theme: PaneTheme, focused: Bool) -> PaneClusterView {
    let view = PaneClusterView(frame: .zero)
    view.theme = theme
    view.resolvedChrome = .glass(.dark)
    view.isPaneFocused = focused
    view.isWindowActive = true
    return view
}

/// The status with a notice on it, through the shipped derivation.
func segments(of status: PaneStatus, notice: String?) -> [PaneClusterSegment] {
    var copy = status
    copy.notice = notice
    return PaneClusterSegments.build(from: copy)
}

/// The pill's fill band as `draw(_:)` composites it: the backing
/// (`theme.background` at the `PaneWash` floor) onto the backdrop, then the
/// material fill over it.
///
/// `cluster-legibility`'s `predictedBand`, blend arithmetic included: through
/// `NSColor.blended(withFraction:of:)` rather than the package's
/// `RGBA.composited(over:)`, because the rep `bitmapImageRepForCachingDisplay`
/// hands back is Generic RGB (gamma 1.8) and AppKit blends in the rep's space,
/// which `NSColor`'s calibrated blend reproduces to sub-byte. That probe's
/// README carries the full finding; it is cited here rather than re-derived.
func predictedBand(fill: RGBA, over backdrop: RGB) -> RGB {
    let backing = nsSRGB(backdrop).blended(
        withFraction: ChromeMaterials.PaneWash.floor,
        of: nsSRGB(PaneTheme.darkPastel.background)
    )!
    let band = backing.blended(withFraction: fill.alpha, of: nsSRGB(fill.rgb))!
    return asRGB(band)
}

// MARK: - arms

/// The arms' shared state, on an enum for `override-wires`' reason: the whole
/// file compiles under the app target's own `-default-isolation MainActor`.
@MainActor enum State {
    static var failures: [String] = []
    static var broken = false
}

@MainActor func check(_ passed: Bool, _ what: String) {
    print("  \(passed ? "ok  " : "FAIL") \(what)")
    if !passed { State.failures.append(what) }
}

@MainActor var broken: Bool { State.broken }

/// WCAG AA for body text, off the package. The same floor `cluster-legibility`
/// grades every other capsule segment against, and the reason this probe invents
/// no threshold of its own: the notice is capsule text and is held to the
/// standard capsule text is held to.
let textFloor = PaneTheme.minimumTextContrast

/// The backdrops every arm renders over — `cluster-legibility`'s pair, cited
/// rather than reinvented. The document colour is the realistic content behind
/// the pill; the bright bound is `glass-backdrop` finding 6b's `#7c7c7c`, the
/// brightest backdrop this repo has measured, and the one
/// `PaneClusterInk.worstFace` grades against.
let backdrops: [(name: String, colour: RGB)] = [
    ("the document colour", PaneTheme.darkPastel.background),
    ("the bright bound #7c7c7c", .eightBit(124, 124, 124)),
]

/// The band inside the pill that a notice's glyphs live in, in *container*
/// coordinates: the capsule's own frame, clamped to the middle 40% of its height
/// so the focused arm's 2 pt `inkFocus` stroke cannot pose as glyph ink, and
/// inset horizontally by the pill's own `horizontalInset` so the pill's
/// antialiased semicircular ends cannot either. `cluster-legibility`'s
/// ink-contamination lesson, inherited and applied in both directions.
func inkBand(of capsule: NSRect) -> NSRect {
    NSRect(
        x: capsule.minX + PaneClusterMetrics.horizontalInset,
        y: capsule.minY + capsule.height * 0.3,
        width: capsule.width - PaneClusterMetrics.horizontalInset * 2,
        height: capsule.height * 0.4
    )
}

/// How far above the resting fill a pixel must sit to count as ink, as a
/// contrast ratio against the measured band.
///
/// **1.5:1, and it is deliberately far below the legibility floor**, because
/// this is a different question. `legible` asks whether the sentence can be
/// *read*; `draws` asks whether anything was painted at all, and the defect it
/// exists to catch painted nothing — a uniformly #171717 band, ratio 1.00:1
/// against itself. A presence threshold set at the legibility floor would make
/// `draws` a duplicate of `legible` and would fail for a notice that rendered
/// perfectly well in a low-contrast theme. It is not derived from the arm it
/// grades: it is a fixed constant, and the control (a resting pill, which paints
/// no notice ink) is what proves it has teeth.
let presenceFloor = 1.5

/// One `draws` or `legible` reading: a capsule under a notice, rendered, its
/// pill band and its ink measured.
///
/// Shared by the two arms because they read the same render and differ only in
/// what they assert about it — running the render twice would be two chances for
/// the two arms to disagree about a pixel.
@MainActor func measureNotice(
    status: PaneStatus,
    notice: String?,
    theme: PaneTheme,
    backdrop: RGB,
    focused: Bool
) -> (band: RGB, ink: RGB, capsule: NSRect, hidden: Bool, rep: NSBitmapImageRep, pane: NSRect) {
    let capsule = makeCapsule(theme: theme, focused: focused)
    let (rep, pane, frame) = renderInPane(
        capsule,
        segments: segments(of: status, notice: notice),
        backdrop: backdrop,
        paneWidth: paneWidth
    )

    // The fill-only band: vertically centred inside the pill, one pill inset in
    // from its *trailing* edge. Inside the shape and outside every glyph by
    // construction — the notice is placed at `horizontalInset` from the leading
    // edge and cut to fit, so the trailing inset is the one strip of pill the
    // sentence cannot reach. `cluster-legibility` reads its band from the gap
    // between two segments; a notice takes the pill alone and has no gaps, so
    // the inset is the equivalent ink-free strip here.
    let bandPoint = NSPoint(
        x: frame.maxX - PaneClusterMetrics.horizontalInset / 2,
        y: frame.midY
    )
    let band = capsule.isHidden
        ? sample(at: NSPoint(x: pane.midX, y: pane.midY), in: rep, size: pane.size)
        : sample(at: bandPoint, in: rep, size: pane.size)
    let ink = capsule.isHidden
        ? band
        : brightest(in: inkBand(of: frame), rep: rep, size: pane.size)
    return (band, ink, frame, capsule.isHidden, rep, pane)
}

/// `draws`: hand the capsule a notice and assert the pill actually has the
/// sentence painted across it. **The arm that would have caught the original
/// defect had the notice reached the view** — the measurement that caught it
/// live was exactly this, a capsule band that stayed uniformly #171717,
/// brightest luminance 0.318, for the notice's whole life.
///
/// The control renders the same capsule with `notice = nil`. **That control is
/// the reason this arm asserts three things rather than one, and the first shape
/// of it was toothless — worth recording, because the toothless shape is the
/// obvious one.** A resting pill is not blank: it wears branch, markers, agent
/// and dot in bright theme foreground, so "is there ink brighter than the fill"
/// passes on a resting pill at 9.62:1 and the control never fails. Measured, not
/// reasoned about: the control passed on the first run of this file.
///
/// So the arm asserts what only a drawn notice can produce, in two parts:
///
///   - the ink found at the sentence's far end is the notice's *own* colour,
///     `PaneClusterInk.noticeInk`'s repaired alert red (`#ff9090` at the shipped
///     theme), which the resting segments' `theme.foreground` grey (`#bbbbbb`)
///     is not — **this is the check the control actually fails on**;
///   - and it clears the presence floor over the measured band, which is the
///     original "was anything painted at all" question, the one the live defect
///     answered with a uniform band at 1.00:1.
///
/// **The colour check is doing the work and the geometry is not, which is worth
/// stating because the comment here claimed otherwise until it was measured.**
/// The intent was that the tail rect would lie past a resting pill's trailing
/// end entirely; it does not. Both pills are pinned at the *same* trailing edge
/// (the controller constrains the capsule's trailing anchor), so a 141 pt
/// resting pill and a 485 pt notice pill overlap across the resting pill's whole
/// width, and the tail rect falls inside both. The tail is still the right place
/// to sample — it is where a sentence that was cut short or never drawn would
/// leave nothing — but the control's teeth come from the ink colour alone.
///
/// Each property is checked separately so a failure names which one went, rather
/// than reporting that something about the pill is wrong.
func armDraws() {
    print("== draws: a notice paints its sentence across the pill")
    let base = PaneTheme.darkPastel
    let expectedInk = PaneClusterInk.noticeInk(theme: base, chrome: .glass(.dark))

    for backdrop in backdrops {
        // Under the control the status carries no notice, so the capsule wears
        // its resting segments and no sentence is ever drawn.
        let notice: String? = broken ? nil : noticeText
        let measured = measureNotice(
            status: repositoryStatus,
            notice: notice,
            theme: base,
            backdrop: backdrop.colour,
            focused: false
        )

        check(
            !measured.hidden,
            "the capsule is visible over \(backdrop.name)"
        )

        // The measured band must be the composite the pill's own layers predict.
        // This is what proves the sampled pixel is the pill's fill and not some
        // other pixel of the pane — without it, a probe reading the backdrop
        // instead of the capsule would still report a contrast.
        let predicted = predictedBand(
            fill: MaterialSet.dark.fillChrome, over: backdrop.colour
        )
        check(
            within(measured.band, predicted, bytes: 1),
            "the pill band \(measured.band.hexString) is backing + fillChrome flattened over "
                + "\(backdrop.name) (predicted \(predicted.hexString), ±1 byte)"
        )

        // The far end of the sentence: the ink band's trailing quarter, which is
        // where a sentence that was cut short or never drawn leaves nothing.
        // Both pills are pinned at the same trailing edge, so this rect falls
        // inside a resting capsule too — see the arm's doc for why that is fine
        // and where the control's teeth actually are.
        let far = inkBand(of: measured.capsule)
        let tail = NSRect(
            x: far.maxX - far.width / 4, y: far.minY, width: far.width / 4, height: far.height
        )
        let tailInk = brightest(in: tail, rep: measured.rep, size: measured.pane.size)

        let ratio = tailInk.contrastRatio(against: measured.band)
        print(String(
            format: "       pill %.0f pt wide, band %@ (luminance %.3f), tail ink %@ (luminance %.3f) -> %.2f:1%@",
            measured.capsule.width,
            measured.band.hexString, luminance(measured.band),
            tailInk.hexString, luminance(tailInk),
            ratio,
            broken ? "  (control: no notice, so the pill wears its resting segments)" : ""
        ))

        check(
            within(tailInk, expectedInk, bytes: 2),
            "the ink at the sentence's far end \(tailInk.hexString) is noticeInk's answer "
                + "\(expectedInk.hexString) (±2 bytes) over \(backdrop.name)"
        )
        check(
            ratio >= presenceFloor,
            String(
                format: "the sentence is painted: ink reads %.2f:1 >= %.1f:1 over the pill on %@",
                ratio, presenceFloor, backdrop.name
            )
        )
    }
}

/// `bare-shell`: the specific case that broke. A pane with no repository, no
/// agent and no attention has an empty capsule at rest, and a notice must still
/// give it a visible pill with the sentence on it.
///
/// The pure layer of this is
/// `PaneClusterSegmentsTests.aNoticeGivesABareShellPaneACapsule`, which asserts
/// the roles `build` produces. This is the drawn half: a segment in a solved
/// layout is not a pixel, and the whole reason this probe exists is that the two
/// were confused for one another once already.
///
/// The control is the bare shell with no notice, which must render nothing
/// visible — `PaneClusterLayout.pillWidth` answers zero for an empty placement
/// and `remeasure()` hides the view. Asserting the arm without the control would
/// let a probe that always reported "visible" pass.
func armBareShell() {
    print("== bare-shell: a notice gives a pane with no resting facts a drawn capsule")
    let base = PaneTheme.darkPastel

    for backdrop in backdrops {
        let notice: String? = broken ? nil : noticeText
        let measured = measureNotice(
            status: bareShellStatus,
            notice: notice,
            theme: base,
            backdrop: backdrop.colour,
            focused: false
        )

        // Under the control this is the whole arm: a bare shell with no notice
        // has no capsule, so `hidden` is true and the check fails here, before
        // any ink is looked for.
        check(
            !measured.hidden,
            "the bare shell's capsule is visible over \(backdrop.name)"
        )
        guard !measured.hidden else {
            print("       (no capsule at all: pillWidth is 0 and the view hid itself)")
            continue
        }

        let predicted = predictedBand(
            fill: MaterialSet.dark.fillChrome, over: backdrop.colour
        )
        check(
            within(measured.band, predicted, bytes: 1),
            "the pill band \(measured.band.hexString) is backing + fillChrome flattened over "
                + "\(backdrop.name) (predicted \(predicted.hexString), ±1 byte)"
        )

        let ratio = measured.ink.contrastRatio(against: measured.band)
        print(String(
            format: "       pill %.0f×%.0f pt, band %@, ink %@ -> %.2f:1",
            measured.capsule.width, measured.capsule.height,
            measured.band.hexString, measured.ink.hexString, ratio
        ))
        check(
            ratio >= presenceFloor,
            String(
                format: "the bare shell's sentence is painted: %.2f:1 >= %.1f:1 over %@",
                ratio, presenceFloor, backdrop.name
            )
        )
    }
}

/// `legible`: the notice's ink must clear the floor every other capsule text
/// clears.
///
/// `PaneClusterInk.noticeInk(theme:chrome:)` is the derivation under test — the
/// repair chain that walks `theme.alert` up to the floor over the pill's worst
/// face. The floor is `PaneTheme.minimumTextContrast`, off the package, the same
/// one `cluster-legibility` grades its resting, focused and offer arms against.
/// No new threshold is invented here and none is derived from the measurement.
///
/// Both focus tiers are graded. `noticeInk` grades itself against `fillChrome`
/// on the argument that the resting fill is the worse of the two over a bright
/// backdrop, and this arm renders the pill wearing each fill in turn rather than
/// taking that argument on trust.
///
/// The control sets the drawn ink to the pill's own composited face, which is a
/// sentence painted the colour of what it sits on. **Damaging the theme would
/// not work here and the reason is worth stating**: `noticeInk` goes through
/// `PaneTheme.color(for:focused:on:)`, whose last resort is the best of the
/// stated colour, white and black, so no `theme.alert` handed in survives as an
/// unreadable one — the repair would rescue the control and the arm would pass
/// broken. `cluster-legibility`'s offer arms hit the same wall and made the same
/// move. So the control damages the graded *pixel*, downstream of the repair.
/// Everything under it — theme, render, band sampling, the grade — is the arm's
/// own, so a probe reading the wrong pixels still fails here.
func armLegible() {
    print("== legible: the notice ink clears PaneTheme.minimumTextContrast")
    let base = PaneTheme.darkPastel

    for (tier, fill, focused) in [
        ("fillChrome", MaterialSet.dark.fillChrome, false),
        ("fillThick", MaterialSet.dark.fillThick, true),
    ] {
        for backdrop in backdrops {
            let measured = measureNotice(
                status: repositoryStatus,
                notice: noticeText,
                theme: base,
                backdrop: backdrop.colour,
                focused: focused
            )

            let predicted = predictedBand(fill: fill, over: backdrop.colour)
            check(
                within(measured.band, predicted, bytes: 1),
                "the \(tier) band \(measured.band.hexString) is backing + \(tier) flattened over "
                    + "\(backdrop.name) (predicted \(predicted.hexString), ±1 byte)"
            )

            let ink = broken ? measured.band : measured.ink

            // The drawn ink must be `noticeInk`'s own answer, not merely some
            // bright pixel: without this the arm could pass on an antialiased
            // edge and never notice the sentence had gone. Two bytes, matching
            // `cluster-legibility`'s own tolerance for a drawn glyph core.
            if !broken {
                let expected = PaneClusterInk.noticeInk(theme: base, chrome: .glass(.dark))
                check(
                    within(ink, expected, bytes: 2),
                    "the drawn ink \(ink.hexString) is noticeInk's answer "
                        + "\(expected.hexString) (±2 bytes)"
                )
            }

            let ratio = ink.contrastRatio(against: measured.band)
            print(String(
                format: "       %@ ink %@ over %@ -> %.2f:1%@",
                tier, ink.hexString, measured.band.hexString, ratio,
                broken ? "  (control: ink set to the pill's own face)" : ""
            ))
            check(
                ratio >= textFloor,
                String(
                    format: "the notice reads %.2f:1 >= %.1f:1 (PaneTheme.minimumTextContrast) on the %@ fill over %@",
                    ratio, textFloor, tier, backdrop.name
                )
            )
        }
    }
}

// MARK: - main

@main
enum Probe {
    @MainActor static func main() {
        // Accessory, and nothing is ever ordered front: this probe opens no
        // window at all. The policy is set anyway so the process does not appear
        // in the Dock for the second it runs.
        NSApplication.shared.setActivationPolicy(.accessory)

        let arms: [String: @MainActor () -> Void] = [
            "draws": armDraws,
            "bare-shell": armBareShell,
            "legible": armLegible,
        ]

        State.broken = CommandLine.arguments.contains("break")

        guard let name = CommandLine.arguments.dropFirst().first, let arm = arms[name] else {
            print("usage: notice <\(arms.keys.sorted().joined(separator: "|"))> [break]")
            exit(2)
        }

        if State.broken { print("(negative control)") }
        arm()

        if State.failures.isEmpty {
            print("PASS")
            exit(0)
        }
        print("FAIL")
        exit(1)
    }
}
