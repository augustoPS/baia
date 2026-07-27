// Probe for the attention colour: does what is drawn follow `attentionAccent`
// and `alertBehavior`, at every site that draws it?
//
// Five questions, one arm each, and a `break` variant of every arm that damages
// the thing under test and expects the check to catch it. A check that has never
// failed proves nothing.
//
//   fill      the loud wash under an asking footer carries the resolved colour
//   quiet     the 2 pt line the quiet treatment draws carries it too
//   acked     the 6x6 pt acknowledged square carries it
//   frame     the whole-pane edge frame carries it, and the pane controller is
//             the thing that hands it over
//   conflict  nothing that is not the attention signal follows the setting
//
// The unit tests already say `PaneTheme.attentionColour(_:behavior:)` returns
// the right colour. That is the thing the drawing *calls*, and the last probe in
// this repo learned the difference the hard way: it verified a geometry helper
// while the `addClip()` that consumed it was covered by nothing. So every arm
// here reads pixels out of a real view, and every control damages the drawing
// rather than the resolution. The `fill`, `quiet`, `acked` and `frame` controls
// each render exactly what the code did before this feature existed, a site
// wired straight to `theme.alert`, and the arm has to notice.
//
// What an arm can and cannot see. Every arm computes its expectation by calling
// the function under test, because that is the only way to ask "does the drawing
// follow the resolution" without writing a second resolution to disagree with the
// first. On its own that is blind: mutate `attentionColour` to return one colour
// and the expectation moves with the drawing, so every coverage check stays green.
// `distinctness` is what closes it. Dark Pastel resolves the six settings onto
// three colours, so six rows that drew fewer than three were either handed a
// constant or sampled somewhere the colour never reaches, and every arm runs that
// gate. It was added after a mutation to `attentionColour` was caught by `fill`
// alone and walked past `quiet`, `acked`, `frame` and `conflict`.
//
// `run.sh` compiles `Sources/PaneStatusBarView.swift`, `Sources/PaneOverlayView.swift`
// and `Sources/WindowCorner.swift` verbatim, so the pixels measured are the ones
// the app draws.
//
// No screenshots. Every reading comes from a bitmap this process rasterizes
// itself through `cacheDisplay(in:to:)`.

import AppKit
import BaiaSettings
import PaneChrome
import WorkspaceLayout

// MARK: - Reading pixels

let scale = 2

/// One rasterized view.
struct Render {
    var pixels: [UInt8]
    var bytesPerRow: Int
    var width: Int
    var height: Int

    func pixel(x: Int, y: Int) -> Pixel {
        let offset = y * bytesPerRow + x * 4
        return Pixel(red: pixels[offset], green: pixels[offset + 1], blue: pixels[offset + 2])
    }
}

struct Pixel: Hashable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    var text: String { String(format: "#%02x%02x%02x", Int(red), Int(green), Int(blue)) }
}

/// Two colours are the same pixel when every channel is within `tolerance`.
///
/// Not exact equality. The drawing goes in as explicit sRGB and comes back out
/// of a bitmap whose colour space is whatever AppKit chose for a windowless
/// view, and a round trip through a wider space moves an 8-bit channel by one.
/// The `pipeline` gate below is what keeps this tolerance honest: if the round
/// trip ever moved a colour further than this, the bar's own background would
/// stop being found and every arm would fail rather than quietly widening.
func matches(_ pixel: Pixel, _ colour: RGB, tolerance: Int = 2) -> Bool {
    let target = Pixel(
        red: UInt8((colour.red * 255).rounded()),
        green: UInt8((colour.green * 255).rounded()),
        blue: UInt8((colour.blue * 255).rounded())
    )
    return abs(Int(pixel.red) - Int(target.red)) <= tolerance
        && abs(Int(pixel.green) - Int(target.green)) <= tolerance
        && abs(Int(pixel.blue) - Int(target.blue)) <= tolerance
}

func rasterize(_ view: NSView) -> Render? {
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    // Retagged into sRGB before anything is read, because the colours going in
    // were built with `NSColor(srgbRed:...)` and a bitmap in a wider space would
    // report them as different numbers than the ones the theme holds.
    let sRGB = rep.colorSpace == .sRGB
        ? rep
        : (rep.converting(to: .sRGB, renderingIntent: .default) ?? rep)
    guard let data = sRGB.bitmapData else { return nil }
    return Render(
        pixels: Array(UnsafeBufferPointer(start: data, count: sRGB.bytesPerRow * sRGB.pixelsHigh)),
        bytesPerRow: sRGB.bytesPerRow,
        width: sRGB.pixelsWide,
        height: sRGB.pixelsHigh
    )
}

/// How much of a region carries `colour`, and what it carries instead.
func coverage(_ render: Render, _ colour: RGB, region: (x: Range<Int>, y: Range<Int>)) -> (
    fraction: Double, total: Int, commonest: Pixel
) {
    var hits = 0
    var total = 0
    var tally: [Pixel: Int] = [:]
    for y in region.y where y >= 0 && y < render.height {
        for x in region.x where x >= 0 && x < render.width {
            let pixel = render.pixel(x: x, y: y)
            total += 1
            tally[pixel, default: 0] += 1
            if matches(pixel, colour) { hits += 1 }
        }
    }
    let commonest = tally.max { $0.value < $1.value }?.key ?? Pixel(red: 0, green: 0, blue: 0)
    return (total == 0 ? 0 : Double(hits) / Double(total), total, commonest)
}

func wholeBar(_ render: Render) -> (x: Range<Int>, y: Range<Int>) {
    (x: 0 ..< render.width, y: 0 ..< render.height)
}

// MARK: - The bars under test

let barWidth = 300.0

/// Every combination of the two keys, and what `PaneTheme` resolves each to.
///
/// Six rows collapsing onto three colours on Dark Pastel, which is the point of
/// running all six rather than one per key: `accent` + `noCollision` and `alert`
/// + anything land on the same red, so an arm that only checked one row could
/// pass while the other five drew whatever they liked.
let combinations: [(accent: AttentionAccent, behavior: AlertBehavior)] =
    AttentionAccent.allCases.flatMap { accent in
        AlertBehavior.allCases.map { (accent: accent, behavior: $0) }
    }

func status(
    attention: PaneStatus.Attention,
    conflicted: Bool = false
) -> PaneStatus {
    PaneStatus(
        anchorName: "baia",
        anchorIsRepository: true,
        isPinned: false,
        workingDirectory: nil,
        git: PaneStatus.Git(
            head: "main",
            hasUpstream: true,
            ahead: 0,
            behind: 0,
            dirty: false,
            untracked: 0,
            conflicted: conflicted ? 2 : 0,
            operation: nil,
            isLinkedWorktree: false
        ),
        agent: PaneStatus.Agent(
            label: "claude",
            wantsAttention: attention != .none,
            isAcknowledged: attention == .acknowledged
        )
    )
}

/// A real `PaneStatusBarView`, configured the way `ConfigurationCenter` configures
/// one, rendered.
///
/// `drawnAccent` and `drawnBehavior` are what the *view* is told. They are separate
/// arguments from what the caller expects so a control can hand the view the
/// shipped defaults while the arm still checks against the combination under
/// test: that is precisely the code as it stood before this feature, a wash wired
/// to `theme.alert` whatever the config said.
func renderBar(
    theme: PaneTheme,
    drawnAccent: AttentionAccent,
    drawnBehavior: AlertBehavior,
    attention: PaneStatus.Attention,
    style: AttentionStyle,
    conflicted: Bool = false
) -> Render? {
    let bar = PaneStatusBarView(
        frame: NSRect(x: 0, y: 0, width: barWidth, height: PaneStatusBarMetrics.height)
    )
    bar.theme = theme
    bar.isWindowActive = true
    bar.isFocused = false
    bar.attentionStyle = style
    bar.attentionAccent = drawnAccent
    bar.alertBehavior = drawnBehavior
    bar.status = status(attention: attention, conflicted: conflicted)
    return rasterize(bar)
}

// MARK: - The pipeline gate
//
// Run at the top of every pixel arm. If the colours coming back out of a bitmap
// were not the colours that went in, every arm below would fail for a reason
// that has nothing to do with the feature, and this says so first.

func colourPipelineIsHonest(_ theme: PaneTheme) -> Bool {
    guard let render = renderBar(
        theme: theme,
        drawnAccent: .alert,
        drawnBehavior: .stock,
        attention: .none,
        style: .loud
    ) else {
        print("  FAIL: the bar rendered nothing, so nothing was measured")
        return false
    }
    let bar = coverage(render, theme.barBackground, region: wholeBar(render))
    print(String(
        format: "  pipeline: %.1f%% of a quiet bar is barBackground %@, commonest pixel %@",
        bar.fraction * 100, theme.barBackground.hexString, bar.commonest.text
    ))
    guard bar.fraction > 0.5 else {
        print("    FAIL: the colours read back are not the colours drawn, so no arm below means anything")
        return false
    }
    return true
}

// MARK: - The distinctness gate
//
// Run at the end of every pixel arm, over the commonest pixel each of the six
// rows drew. See the note at the top of the file: without this an arm proves
// plumbing and nothing about the resolution it is plumbed to.

func distinctness(_ drawn: Set<Pixel>, _ what: String) -> Bool {
    print("  distinct \(what) drawn across the six rows: \(drawn.count)")
    guard drawn.count >= 3 else {
        print("    FAIL: the six settings drew fewer than the three colours they resolve to")
        return false
    }
    return true
}

// MARK: - fill

/// The loud wash, which is also what the 510 ms arrival pulse animates.
func fillArm(breakIt: Bool) -> Bool {
    let theme = PaneTheme.darkPastel
    guard colourPipelineIsHonest(theme) else { return false }

    var ok = true
    var drawn: Set<Pixel> = []
    for combination in combinations {
        let expected = theme.attentionColour(combination.accent, behavior: combination.behavior)
        // The control draws the shipped defaults whatever the arm asked for, which
        // is the wash as it was before this feature: wired to `theme.alert`.
        guard let render = renderBar(
            theme: theme,
            drawnAccent: breakIt ? .alert : combination.accent,
            drawnBehavior: breakIt ? .stock : combination.behavior,
            attention: .asking,
            style: .loud
        ) else { return false }

        let measured = coverage(render, expected, region: wholeBar(render))
        drawn.insert(measured.commonest)
        print(String(
            format: "  %@/%@ expects %@: %.1f%% of the bar, commonest %@",
            combination.accent.rawValue, combination.behavior.rawValue,
            expected.hexString, measured.fraction * 100, measured.commonest.text
        ))
        // Half the bar rather than all of it: the text, the hairline and the
        // busy dot are drawn over the wash and are entitled to their pixels.
        guard measured.fraction > 0.5, matches(measured.commonest, expected) else {
            print("    FAIL: the wash is not the colour the setting resolves to")
            ok = false
            continue
        }
    }

    return distinctness(drawn, "washes") && ok
}

// MARK: - quiet

/// The 2 pt line the quiet treatment spends instead of the bar's background.
func quietArm(breakIt: Bool) -> Bool {
    let theme = PaneTheme.darkPastel
    guard colourPipelineIsHonest(theme) else { return false }

    var ok = true
    var drawn: Set<Pixel> = []
    let lineHeight = 2 * scale
    for combination in combinations {
        let expected = theme.attentionColour(combination.accent, behavior: combination.behavior)
        guard let render = renderBar(
            theme: theme,
            drawnAccent: breakIt ? .alert : combination.accent,
            drawnBehavior: breakIt ? .stock : combination.behavior,
            attention: .asking,
            style: .quiet
        ) else { return false }

        // Row 0 of the bitmap is the top of the bar, and the view is flipped, so
        // the line the unfocused bar draws at y 0 is at the top of the bitmap.
        let line = coverage(render, expected, region: (x: 0 ..< render.width, y: 0 ..< lineHeight))
        // Below the line the bar has to be its own background. A quiet treatment
        // that filled the bar would pass the check above and be the loud one.
        let body = coverage(
            render, theme.barBackground,
            region: (x: 0 ..< render.width, y: (lineHeight + 2) ..< render.height)
        )
        drawn.insert(line.commonest)
        print(String(
            format: "  %@/%@ expects %@: line %.1f%%, body still barBackground %.1f%%",
            combination.accent.rawValue, combination.behavior.rawValue,
            expected.hexString, line.fraction * 100, body.fraction * 100
        ))
        guard line.fraction > 0.98 else {
            print("    FAIL: the quiet line is not the colour the setting resolves to, it is \(line.commonest.text)")
            ok = false
            continue
        }
        guard body.fraction > 0.5 else {
            print("    FAIL: the bar under the line is filled, so this is not the quiet treatment at all")
            ok = false
            continue
        }
    }
    return distinctness(drawn, "lines") && ok
}

// MARK: - acked

/// The 6x6 pt square an acknowledged pane keeps.
func ackedArm(breakIt: Bool) -> Bool {
    let theme = PaneTheme.darkPastel
    guard colourPipelineIsHonest(theme) else { return false }

    // The mark's own rectangle, from the constants the view draws it with, pulled
    // in one pixel so the antialiased edge is nobody's evidence.
    let markSize = 6.0
    let left = Int(PaneStatusBarMetrics.horizontalInset) * scale + 1
    let right = Int(PaneStatusBarMetrics.horizontalInset + markSize) * scale - 1
    let top = Int((PaneStatusBarMetrics.height - markSize) / 2) * scale + 1
    let bottom = Int((PaneStatusBarMetrics.height + markSize) / 2) * scale - 1

    var ok = true
    var drawn: Set<Pixel> = []
    for combination in combinations {
        let expected = theme.attentionColour(combination.accent, behavior: combination.behavior)
        guard let render = renderBar(
            theme: theme,
            drawnAccent: breakIt ? .alert : combination.accent,
            drawnBehavior: breakIt ? .stock : combination.behavior,
            attention: .acknowledged,
            style: .loud
        ) else { return false }

        let mark = coverage(render, expected, region: (x: left ..< right, y: top ..< bottom))
        drawn.insert(mark.commonest)
        // The mark is the smallest thing on the bar that is not grey. If the whole
        // bar came back in this colour the check above would pass on a footer that
        // had filled itself, which is the loud treatment and not this one.
        let whole = coverage(render, expected, region: wholeBar(render))
        print(String(
            format: "  %@/%@ expects %@: square %.1f%% of %d px, whole bar %.1f%%",
            combination.accent.rawValue, combination.behavior.rawValue,
            expected.hexString, mark.fraction * 100, mark.total, whole.fraction * 100
        ))
        guard mark.fraction > 0.98 else {
            print("    FAIL: the acknowledged square is \(mark.commonest.text), not the resolved colour")
            ok = false
            continue
        }
        guard whole.fraction < 0.1 else {
            print("    FAIL: the whole bar carries this colour, so what was measured is a fill, not a mark")
            ok = false
            continue
        }
    }
    return distinctness(drawn, "squares") && ok
}

// MARK: - frame

/// The 2 pt frame around the whole pane, which is the other half of the loud
/// treatment.
///
/// Two gates, because the drawing and the decision live in different files and
/// only one of them can be rendered here. `PaneEdgeFrameView` compiles on its own
/// and its pixels are read below. `TerminalPaneController` cannot: it pulls in
/// libghostty and spawns a pty, and a probe that linked the terminal engine to
/// read four edges would be a probe nobody runs. So the assignment that hands the
/// frame its colour is read out of the shipped source instead, and the control
/// damages that line rather than the view it feeds.
func frameArm(breakIt: Bool) -> Bool {
    let theme = PaneTheme.darkPastel
    var ok = true
    var drawn: Set<Pixel> = []

    let thickness = 2 * scale
    for combination in combinations {
        let expected = theme.attentionColour(combination.accent, behavior: combination.behavior)
        let frame = PaneEdgeFrameView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        // The control hands the frame `theme.alert` whatever the setting resolves
        // to, which is the line as it stood before this feature.
        frame.colour = breakIt ? theme.alert : expected
        frame.isVisible = true
        guard let render = rasterize(frame) else { return false }

        let edges = [
            ("top", (x: 0 ..< render.width, y: 0 ..< thickness)),
            ("bottom", (x: 0 ..< render.width, y: (render.height - thickness) ..< render.height)),
            ("left", (x: 0 ..< thickness, y: 0 ..< render.height)),
            ("right", (x: (render.width - thickness) ..< render.width, y: 0 ..< render.height)),
        ]
        var worst = 1.0
        for (_, region) in edges {
            worst = min(worst, coverage(render, expected, region: region).fraction)
        }
        // The top edge's commonest pixel is what the distinctness gate reads. The
        // pixel half of this arm hands the view its colour, so on its own it can
        // only say that `PaneEdgeFrameView` strokes the four edges in whatever it
        // is given; six rows that all came back one colour say the resolution
        // feeding it is a constant.
        drawn.insert(coverage(render, expected, region: edges[0].1).commonest)
        let middle = coverage(
            render, expected,
            region: (x: (thickness + 2) ..< (render.width - thickness - 2),
                     y: (thickness + 2) ..< (render.height - thickness - 2))
        )
        print(String(
            format: "  %@/%@ expects %@: worst edge %.1f%%, interior %.1f%%",
            combination.accent.rawValue, combination.behavior.rawValue,
            expected.hexString, worst * 100, middle.fraction * 100
        ))
        guard worst > 0.98 else {
            print("    FAIL: an edge of the pane frame is not the colour the setting resolves to")
            ok = false
            continue
        }
        // A frame is an edge. A filled rectangle would clear the check above and
        // would be a coloured sheet over a live terminal.
        guard middle.fraction < 0.01 else {
            print("    FAIL: the frame filled the pane rather than outlining it")
            ok = false
            continue
        }
    }

    ok = distinctness(drawn, "frames") && ok
    ok = paneControllerHandsOverTheResolvedColour(breakIt: breakIt) && ok
    return ok
}

/// The assignment in `TerminalPaneController.applyPresentation`, read out of the
/// shipped file.
///
/// A source check and openly so. It is here because the pixel gate above proves
/// only that a `PaneEdgeFrameView` draws the colour it is given, and the thing
/// that can regress is the colour it is given: `edgeFrame.colour = theme.alert`
/// compiles, renders, and ignores the config entirely.
func paneControllerHandsOverTheResolvedColour(breakIt: Bool) -> Bool {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let path = root.appending(path: "Sources/TerminalPaneController.swift")
    guard var source = try? String(contentsOf: path, encoding: .utf8) else {
        print("  FAIL: could not read \(path.path(percentEncoded: false))")
        return false
    }
    // The control rewrites the shipped line to what it said before this feature.
    // Damaging the file rather than the expectation is the whole point: a control
    // that only moved the goalposts would pass over a pane frame wired to red.
    if breakIt {
        source = source.replacingOccurrences(
            of: "edgeFrame.colour = theme.attentionColour(attentionAccent, behavior: alertBehavior)",
            with: "edgeFrame.colour = theme.alert"
        )
    }

    let assignments = source
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("edgeFrame.colour =") }
    print("  TerminalPaneController assigns the frame's colour \(assignments.count) time(s):")
    for assignment in assignments { print("    \(assignment)") }
    guard assignments.count == 1 else {
        print("    FAIL: expected exactly one assignment, so that there is one place to be wrong")
        return false
    }
    guard assignments[0]
        == "edgeFrame.colour = theme.attentionColour(attentionAccent, behavior: alertBehavior)"
    else {
        print("    FAIL: the pane frame is not taking its colour from the setting")
        return false
    }
    return true
}

// MARK: - conflict

/// Red still means conflict.
///
/// `PaneTheme.alert` is the conflicted-tree marker and the `!` glyph as well as
/// the attention colour, and only the attention colour follows the setting. A
/// pane with a conflicted tree and no agent asking must therefore render
/// identically under all six combinations: if the git segments had been helpfully
/// wired up too, the six bars would differ and this counts the pixels that did.
func conflictArm(breakIt: Bool) -> Bool {
    let theme = PaneTheme.darkPastel
    guard colourPipelineIsHonest(theme) else { return false }

    // Anti-vacuity, and it runs in both modes because it is not what the control
    // damages. An arm built on equality passes when it is blind, and this one is
    // blind twice over: a comparison of six identical footers is trivially equal,
    // and the expectations below come from the function under test. So the six
    // settings are first made to prove they can move a pixel at all, on a pane that
    // *is* asking, where they are supposed to differ.
    var drawn: Set<Pixel> = []
    for combination in combinations {
        guard let render = renderBar(
            theme: theme,
            drawnAccent: combination.accent,
            drawnBehavior: combination.behavior,
            attention: .asking,
            style: .loud,
            conflicted: true
        ) else { return false }
        let expected = theme.attentionColour(combination.accent, behavior: combination.behavior)
        drawn.insert(coverage(render, expected, region: wholeBar(render)).commonest)
    }
    guard distinctness(drawn, "asking bars") else { return false }

    // The control asks the equality question of a pane that *is* asking, where the
    // six settings are supposed to differ, so the comparison below has to fail.
    let attention: PaneStatus.Attention = breakIt ? .asking : .none

    guard let reference = renderBar(
        theme: theme,
        drawnAccent: combinations[0].accent,
        drawnBehavior: combinations[0].behavior,
        attention: attention,
        style: .loud,
        conflicted: true
    ) else { return false }

    // The conflict marker has to actually be on the bar, or this compares six
    // copies of a footer with nothing red on it and calls that a result.
    let marker = theme.color(for: .alert, focused: false, on: theme.barBackground)
    let markerPixels = coverage(reference, marker, region: wholeBar(reference))
    print(String(
        format: "  the conflict marker %@ covers %d px of the bar",
        marker.hexString, Int(markerPixels.fraction * Double(markerPixels.total))
    ))
    guard markerPixels.fraction * Double(markerPixels.total) > 20 else {
        print("    FAIL: no conflict marker was drawn, so there is nothing here to leave alone")
        return false
    }

    var ok = true
    for combination in combinations.dropFirst() {
        guard let render = renderBar(
            theme: theme,
            drawnAccent: combination.accent,
            drawnBehavior: combination.behavior,
            attention: attention,
            style: .loud,
            conflicted: true
        ) else { return false }
        var differing = 0
        for y in 0 ..< render.height {
            for x in 0 ..< render.width where render.pixel(x: x, y: y) != reference.pixel(x: x, y: y) {
                differing += 1
            }
        }
        print("  \(combination.accent.rawValue)/\(combination.behavior.rawValue): \(differing) px differ from the first row")
        guard differing == 0 else {
            print("    FAIL: the setting moved a pixel on a pane that is not asking")
            ok = false
            continue
        }
    }
    return ok
}

// MARK: - Entry

@main
enum Probe {
    @MainActor static func main() {
        let app = NSApplication.shared
        // Nothing here needs the screen, so nothing here takes it.
        app.setActivationPolicy(.accessory)

        let arm = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
        let breakIt = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "break"
        print("== \(arm)\(breakIt ? " (negative control: the drawing is damaged)" : "")")

        let ok: Bool
        switch arm {
        case "fill": ok = fillArm(breakIt: breakIt)
        case "quiet": ok = quietArm(breakIt: breakIt)
        case "acked": ok = ackedArm(breakIt: breakIt)
        case "frame": ok = frameArm(breakIt: breakIt)
        case "conflict": ok = conflictArm(breakIt: breakIt)
        default:
            print("usage: attentiontest fill|quiet|acked|frame|conflict [break]")
            ok = false
        }

        print(ok ? "PASS" : "FAIL")
        fflush(stdout)
        exit(ok ? 0 : 1)
    }
}
