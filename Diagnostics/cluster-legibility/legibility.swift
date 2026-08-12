import AppKit
import BaiaSettings
import PaneChrome

// Is the capsule's segment text legible over the pill's own fill, on realistic
// content, at both fill tiers — and does the attention dot stay distinguishable
// on both?
//
// `pane-glass-legibility` is the grading model, applied to the pill:
// segment ink is graded against WCAG AA's 4.5:1 (`measure.py`'s `FLOOR`, which
// is `PaneTheme.minimumTextContrast`, read off the package here rather than
// transcribed), ink is sampled as the brightest pixel in a glyph band (the
// fully-covered glyph core; antialiased edge pixels are excluded by
// construction), and the fill is sampled from a band that contains no ink —
// that probe's ink-contamination lesson, inherited.
//
// `cluster-wires` is the harness model: the shipped `PaneClusterView`,
// compiled verbatim, rendered offscreen through `cacheDisplay(in:to:)` with
// hand-fed segments. **No window server, no capture, no wallpaper, no tone
// response.** The pill's fill is plain translucent paint (`NSColor` at the
// material's alpha), not an `NSGlassEffectView`, so the offscreen render *is*
// the full drawing route — nothing a compositor would add is missing. That is
// also why every number this probe prints is deterministic and pinned in the
// README as an exact value, where pane-glass-legibility's absolutes are
// within-run only.
//
// Where alpha is in play the pill composites in two layers since 2026-08-12
// (the owner's read-through ruling): the backing — `theme.background` at
// `ChromeMaterials.PaneWash.floor` — onto the backdrop, then the material
// fill onto the backing. Two backdrops per arm: the dark theme document
// colour (`PaneTheme.darkPastel.background`, `#141414`), and the bright
// bound `#7c7c7c` the backing exists to survive. The prediction is not
// trusted blind: each arm renders the capsule over an opaque backdrop view
// and asserts the *measured* fill band equals the predicted composite within
// ±1 byte per channel, so the layer stack and AppKit's actual compositing
// are held to agree on every run. The prediction's per-channel arithmetic is
// `NSColor.blended(withFraction:of:)` — see `predictedBand` for why the
// package's sRGB flatten, exact in the dark regime, is not it.
//
// Every arm has a negative control, the house pattern (`override-wires` via
// `cluster-wires`): under `break` the graded ink — the theme foreground for
// the text arms, `ansi[1]` (the attention colour's source) for the dot arm —
// is deliberately set to the composited fill colour, and the arm must fail its
// threshold. The control runs the whole pipeline (theme, render, sampling,
// contrast), not just the arithmetic: a probe that sampled the wrong pixels or
// graded the wrong pair would pass its control-broken run, and `run.sh` fails
// loudly on that.

// MARK: - offscreen rendering

/// A full-bounds opaque fill for the capsule to composite over: the "document"
/// under the pill. Flipped to match the overlay family, so the capsule subview
/// and the container agree on where y = 0 is.
final class BackdropView: NSView {
    var colour: NSColor = .black
    override var isFlipped: Bool { true }
    override func draw(_: NSRect) {
        colour.setFill()
        bounds.fill()
    }
}

/// The capsule rendered over an opaque backdrop, as bytes.
/// `cluster-wires`' render helper with one addition: the view is wrapped in a
/// ``BackdropView`` first, so the bitmap holds AppKit's own composite of the
/// translucent pill over the document colour — the pixel an owner sees — and
/// the flatten arithmetic below can be checked against it rather than
/// substituted for it. `cacheDisplay(in:to:)` runs the real `draw(_:)` with no
/// window in the path.
func renderOverBackdrop(_ view: PaneClusterView, backdrop: RGB) -> NSBitmapImageRep {
    let size = view.intrinsicContentSize
    let container = BackdropView(frame: NSRect(origin: .zero, size: size))
    container.colour = NSColor(
        srgbRed: backdrop.red, green: backdrop.green, blue: backdrop.blue, alpha: 1
    )
    view.frame = container.bounds
    container.addSubview(view)
    container.layoutSubtreeIfNeeded()
    guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else {
        fatalError("no bitmap rep for the backdrop container")
    }
    container.cacheDisplay(in: container.bounds, to: rep)
    return rep
}

/// The pixel at a point given in the view's own points, as package `RGB`,
/// whatever scale the rep rendered at. Through `.sRGB` explicitly, matching
/// the space `PaneOverlayView.nsColor` draws in.
func sample(at point: NSPoint, in rep: NSBitmapImageRep, size: NSSize) -> RGB {
    let scale = Double(rep.pixelsWide) / Double(size.width)
    guard let colour = rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale)),
          let srgb = colour.usingColorSpace(.sRGB)
    else { fatalError("no pixel at \(point)") }
    return RGB(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
}

/// The brightest pixel in a rect given in view points — pane-glass-legibility's
/// ink sampling: the fully-covered glyph core, found by luminance sum, with
/// antialiased edges losing by construction.
func brightest(in rect: NSRect, rep: NSBitmapImageRep, size: NSSize) -> RGB {
    let scale = Double(rep.pixelsWide) / Double(size.width)
    var best = -1.0
    var bestColour = RGB(red: 0, green: 0, blue: 0)
    for py in Int(rect.minY * scale) ..< Int(rect.maxY * scale) {
        for px in Int(rect.minX * scale) ..< Int(rect.maxX * scale) {
            guard let colour = rep.colorAt(x: px, y: py),
                  let srgb = colour.usingColorSpace(.sRGB) else { continue }
            let sum = srgb.redComponent + srgb.greenComponent + srgb.blueComponent
            if sum > best {
                best = sum
                bestColour = RGB(
                    red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent
                )
            }
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

// MARK: - fixtures

/// Realistic content: the capsule wearing all four segments, `cluster-wires`'
/// own fixture — a branch, a changes summary with the marker glyphs, an agent
/// verb, and the attention dot.
let segments: [PaneClusterSegment] = [
    PaneClusterSegment(role: .place, text: "main"),
    PaneClusterSegment(role: .changes, text: "↑1*?3"),
    PaneClusterSegment(role: .agent, text: "working"),
    PaneClusterSegment(role: .attention, text: ""),
]

/// A capsule under glass chrome in the state the pane feeds it. The theme is a
/// parameter because the negative controls hand in a damaged one.
func makeCapsule(theme: PaneTheme, focused: Bool) -> PaneClusterView {
    let view = PaneClusterView(frame: .zero)
    view.segments = segments
    view.theme = theme
    view.resolvedChrome = .glass(.dark)
    view.isPaneFocused = focused
    view.isWindowActive = true
    return view
}

/// The solved placement, recomputed with the view's own font and arithmetic
/// (the view's cache is private) — `cluster-wires`' helper, used to find the
/// fill-only gap, the glyph rects and the dot centre, never to re-test layout.
let placed: [PaneClusterLayout.Placed] = {
    let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    var widths: [PaneClusterSegmentRole: Double] = [:]
    for segment in segments {
        widths[segment.role] = segment.role == .attention
            ? PaneClusterMetrics.dotDiameter
            : Double(NSAttributedString(
                string: segment.text, attributes: [.font: font]
            ).size().width)
    }
    return PaneClusterLayout.solve(segments: segments, widths: widths)
}()

/// The fill-only sampling point: vertically centred in the gap between the
/// first two segments — inside the pill, clear of every glyph, clear of the
/// 2 pt inset focus stroke at the edges. The ink-free band, one pixel wide.
let gapPoint = NSPoint(
    x: placed[0].x + placed[0].width + PaneClusterMetrics.segmentGap / 2,
    y: PaneClusterMetrics.height / 2
)

/// The glyph band for a text segment: the segment's own width, held to the
/// middle 40% of the pill's height. The vertical clamp keeps the focused arm's
/// inset stroke (`PaneStatusBarMetrics.focusFrameWidth`, 2 pt at each edge)
/// out of the ink search, so a bright `inkFocus` ring cannot pose as glyph
/// ink — the ink-contamination lesson pointed the other way.
func glyphBand(_ placement: PaneClusterLayout.Placed) -> NSRect {
    NSRect(
        x: placement.x,
        y: PaneClusterMetrics.height * 0.3,
        width: placement.width,
        height: PaneClusterMetrics.height * 0.4
    )
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

/// WCAG AA for body text, off the package: the same 4.5 pane-glass-legibility's
/// `measure.py` spells as `FLOOR`.
let textFloor = PaneTheme.minimumTextContrast

/// WCAG 1.4.11 for non-text marks. pane-glass-legibility grades text only and
/// carries no non-text method, so this probe documents its own: contrast of
/// the dot's colour against the composited fill, against the 3:1 the non-text
/// success criterion names. A literal, because no package constant exists for
/// it; the README carries the citation.
let dotFloor = 3.0

/// The backdrops every arm renders over. The document colour is the realistic
/// content behind the pill; the bright bound is glass-backdrop finding 6b's
/// `#7c7c7c`, the brightest backdrop this repo has measured, standing in for
/// prompt text and bright content beneath the pill.
///
/// Two since 2026-08-12, when the pill grew its backing (`theme.background`
/// at `ChromeMaterials.PaneWash.floor`, painted under the material fill so
/// what is beneath never reads through — the owner's ruling). Before the
/// backing, the bright case was derived arithmetic in the README's "bound
/// this probe does not measure"; the backing is plain paint in the same
/// `draw(_:)`, so the case became renderable here and is measured. The bright
/// arm is also what makes the flatten cross-check see the backing at all:
/// over the document colour the backing composites to exactly the document
/// colour (background over background) and a missing backing would be
/// invisible, where over `#7c7c7c` its absence moves the band by ~29 bytes.
let backdrops: [(name: String, colour: RGB)] = [
    ("the document colour", PaneTheme.darkPastel.background),
    ("the bright bound #7c7c7c", .eightBit(124, 124, 124)),
]

/// The pill's fill band as `draw(_:)` composites it since 2026-08-12: the
/// backing first (`theme.background` at the `PaneWash` floor), the material
/// fill over it.
///
/// Blended through `NSColor.blended(withFraction:of:)` rather than the
/// package's `RGBA.composited(over:)`, and the difference is the compositing
/// space, found the day the bright backdrop joined: the rep
/// `bitmapImageRepForCachingDisplay(in:)` hands back is Generic RGB
/// (gamma 1.8), and AppKit blends in the rep's space, which `NSColor`'s own
/// calibrated blend reproduces to sub-byte on both backdrops. The package's
/// sRGB flatten is the same layer stack in sRGB bytes and agrees to sub-byte
/// over the dark document colour — which is the regime every pre-2026-08-12
/// pin lived in, and why the divergence stayed invisible — but lands ~6 bytes
/// dark of the measurement at the bright bound. The layer stack under
/// prediction is unchanged either way; only the per-channel arithmetic is
/// AppKit's, so the ±1 check keeps its teeth on both backdrops.
func predictedBand(fill: RGBA, over backdrop: RGB) -> RGB {
    let backing = nsSRGB(backdrop).blended(
        withFraction: ChromeMaterials.PaneWash.floor,
        of: nsSRGB(PaneTheme.darkPastel.background)
    )!
    let band = backing.blended(withFraction: fill.alpha, of: nsSRGB(fill.rgb))!
    return asRGB(band)
}

func nsSRGB(_ rgb: RGB) -> NSColor {
    NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
}

func asRGB(_ colour: NSColor) -> RGB {
    guard let srgb = colour.usingColorSpace(.sRGB) else { fatalError("no sRGB form") }
    return RGB(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
}

/// One text arm: the capsule at a fill tier, segment ink graded over the
/// composited pill fill. Shared by `resting` (fillChrome) and `focused`
/// (fillThick); the two arms differ only in which material the focus step
/// selects, and that selection is `cluster-wires`' focus arm's subject, not
/// this probe's.
@MainActor func gradeText(tier: String, fill: RGBA, focused: Bool) {
    let base = PaneTheme.darkPastel

    for backdrop in backdrops {
        // The composite, two layers since 2026-08-12: the backing (background
        // at the PaneWash floor) onto the backdrop, then the material fill
        // onto the backing — predictedBand's calibrated blend, and its doc
        // for where the package's sRGB flatten sits.
        let predicted = predictedBand(fill: fill, over: backdrop.colour)

        // The negative control: ink deliberately set to the composited fill
        // colour. Same render, same sampling, same grade — and the grade must
        // fail, or the probe is not measuring what it claims.
        var theme = base
        if broken { theme.foreground = predicted }

        let capsule = makeCapsule(theme: theme, focused: focused)
        let size = capsule.intrinsicContentSize
        let rep = renderOverBackdrop(capsule, backdrop: backdrop.colour)

        // The measured fill band must be the flatten's prediction: this is
        // what makes the arithmetic citable rather than assumed, and what
        // proves the graded backdrop is the pill's fill and not some other
        // pixel. On the bright backdrop it is also the backing's existence
        // check — without the backing the band lands ~29 bytes away.
        let band = sample(at: gapPoint, in: rep, size: size)
        check(
            within(band, predicted, bytes: 1),
            "the fill band \(band.hexString) is backing + \(tier) flattened over "
                + "\(backdrop.name) (predicted \(predicted.hexString), ±1 byte)"
        )

        // Worst case over the content: every text segment graded, the
        // minimum carries the assertion.
        var worst = Double.infinity
        var worstDetail = ""
        for placement in placed where placement.segment.role != .attention {
            let ink = brightest(in: glyphBand(placement), rep: rep, size: size)
            let ratio = ink.contrastRatio(against: band)
            print(String(
                format: "       %@ ink %@ over %@ -> %.2f:1",
                String(describing: placement.segment.role), ink.hexString, band.hexString, ratio
            ))
            if ratio < worst {
                worst = ratio
                worstDetail = String(describing: placement.segment.role)
            }
        }
        check(
            worst >= textFloor,
            String(
                format: "worst segment (%@) reads %.2f:1 >= %.1f:1 (PaneTheme.minimumTextContrast) on the %@ fill over %@",
                worstDetail, worst, textFloor, tier, backdrop.name
            )
        )
    }
}

func armResting() {
    print("== resting: segment ink over fillChrome composited on the document colour")
    gradeText(tier: "fillChrome", fill: MaterialSet.dark.fillChrome, focused: false)
}

func armFocused() {
    print("== focused: segment ink over fillThick composited on the document colour")
    gradeText(tier: "fillThick", fill: MaterialSet.dark.fillThick, focused: true)
}

func armDot() {
    print("== dot: the attention accent over both fills")
    let base = PaneTheme.darkPastel
    let set = MaterialSet.dark

    for (tier, fill, focused) in [
        ("fillChrome", set.fillChrome, false),
        ("fillThick", set.fillThick, true),
    ] {
        for backdrop in backdrops {
            let predicted = predictedBand(fill: fill, over: backdrop.colour)

            // The control damages the accent at its source: `attentionColour(.alert,
            // behavior: .stock)` resolves to `ansi[1]`, so a fill-coloured `ansi[1]`
            // is a dot the eye cannot find — and the grade must say so.
            var theme = base
            if broken { theme.ansi[1] = predicted }

            let capsule = makeCapsule(theme: theme, focused: focused)
            let size = capsule.intrinsicContentSize
            let rep = renderOverBackdrop(capsule, backdrop: backdrop.colour)

            let band = sample(at: gapPoint, in: rep, size: size)
            check(
                within(band, predicted, bytes: 1),
                "the fill band \(band.hexString) is backing + \(tier) flattened over "
                    + "\(backdrop.name) (predicted \(predicted.hexString), ±1 byte)"
            )

            // The dot's centre pixel: 6 pt of opaque accent, fully covered at
            // its centre, the same pixel cluster-wires reads. Sampled rather
            // than computed, so the grade is on what is drawn.
            guard let dot = placed.first(where: { $0.segment.role == .attention }) else {
                check(false, "the fixture has an attention dot")
                return
            }
            let centre = NSPoint(
                x: dot.x + PaneClusterMetrics.dotDiameter / 2,
                y: PaneClusterMetrics.height / 2
            )
            let dotInk = sample(at: centre, in: rep, size: size)
            let accent = theme.attentionColour(.alert, behavior: .stock)
            check(
                within(dotInk, accent, bytes: 1),
                "the dot centre \(dotInk.hexString) is the attention accent \(accent.hexString) (±1 byte)"
            )

            let ratio = dotInk.contrastRatio(against: band)
            check(
                ratio >= dotFloor,
                String(
                    format: "the dot reads %.2f:1 >= %.1f:1 (WCAG 1.4.11 non-text) over %@ over %@",
                    ratio, dotFloor, tier, backdrop.name
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
        // window at all. The policy is set anyway so the process does not
        // appear in the Dock for the second it runs.
        NSApplication.shared.setActivationPolicy(.accessory)

        let arms: [String: @MainActor () -> Void] = [
            "resting": armResting,
            "focused": armFocused,
            "dot": armDot,
        ]

        State.broken = CommandLine.arguments.contains("break")

        guard let name = CommandLine.arguments.dropFirst().first, let arm = arms[name] else {
            print("usage: legibility <\(arms.keys.sorted().joined(separator: "|"))> [break]")
            exit(2)
        }

        if State.broken { print("(negative control: the graded ink is set to the fill colour)") }
        arm()

        if State.failures.isEmpty {
            print("PASS")
            exit(0)
        }
        print("FAIL")
        exit(1)
    }
}
