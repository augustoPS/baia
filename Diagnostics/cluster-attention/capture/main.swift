// Renders the capsule at every attention level, for the owner's eye.
//
// Not a check and never run by `run.sh`: the two things left open on the
// capsule's attention treatment are judgments a measurement cannot make, so this
// exists to put them on screen rather than to assert anything.
//
//   1. the narrow-pane overflow, which grew from 22 pt to 37 pt when the bare
//      dot became a capsule with a glyph
//   2. the four levels beside each other at a readable size
//
// Writes PNGs to the directory given as the first argument. Opens no window and
// takes no focus; every pixel comes from `cacheDisplay(in:to:)`.

import AppKit
import BaiaSettings
import PaneChrome
import WorkspaceLayout

let out = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSTemporaryDirectory() + "baia-capsule-capture"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

@MainActor func makeView(
    _ attention: PaneStatus.Attention,
    width: Double,
    theme: PaneTheme = .darkPastel
) -> PaneClusterView {
    let view = PaneClusterView(
        frame: NSRect(x: 0, y: 0, width: width, height: PaneClusterMetrics.height)
    )
    view.theme = theme
    let status = PaneStatus(
        anchorName: "baia",
        anchorIsRepository: true,
        isPinned: false,
        workingDirectory: nil,
        git: nil,
        agent: PaneStatus.Agent(
            label: "claude",
            wantsAttention: attention == .asking || attention == .acknowledged,
            isAcknowledged: attention == .acknowledged,
            isBusy: false,
            hasFinishedUnseen: attention == .done
        )
    )
    view.segments = PaneClusterSegments.build(from: status)
    view.needsDisplay = true
    return view
}

/// The pill inside a pane of `paneWidth`, captured with the pane around it.
///
/// **The pane is the point, not scenery.** `remeasure()` takes its budget from
/// `superview.bounds.width` and is explicitly unbudgeted with no superview, so a
/// capture that sized the view to its own intrinsic width measured a pill that
/// had never been asked to fit anything. That was this harness's first version:
/// every "narrow" capture came back at the same 85 pt, because the budget never
/// applied. The view is installed and left alone now, and the pane is drawn with
/// it so the overflow is visible as overflow rather than as a cropped pill.
@MainActor func write(_ view: PaneClusterView, _ name: String, paneWidth: Double, pad: Double = 16) {
    let pane = NSView(frame: NSRect(x: 0, y: 0, width: paneWidth, height: 60))
    pane.wantsLayer = true
    pane.layer?.backgroundColor = NSColor(
        srgbRed: CGFloat(PaneTheme.darkPastel.background.red),
        green: CGFloat(PaneTheme.darkPastel.background.green),
        blue: CGFloat(PaneTheme.darkPastel.background.blue),
        alpha: 1
    ).cgColor
    pane.addSubview(view)
    pane.layoutSubtreeIfNeeded()

    // Re-assign the segments now that the view has a superview, because that is
    // what triggers `remeasure()` and `remeasure()` is what applies the budget.
    // Setting them before installation measures against no pane at all, which is
    // the unbudgeted path and is how this harness first reported every narrow
    // capture at the same width.
    // Through empty, because `didSet` guards on inequality and assigning the
    // same value back is a no-op that measures nothing.
    let carried = view.segments
    view.segments = []
    view.segments = carried
    pane.layoutSubtreeIfNeeded()

    // Pinned top-right the way `TerminalPaneController` pins it, so a pill wider
    // than its pane hangs off the leading edge exactly as it would on screen.
    let width = view.intrinsicContentSize.width
    view.frame = NSRect(
        x: paneWidth - width - PaneClusterMetrics.cornerInset,
        y: PaneClusterMetrics.cornerInset,
        width: width,
        height: PaneClusterMetrics.height
    )
    pane.layoutSubtreeIfNeeded()

    // The canvas is wider than the pane so a pill overflowing to the left is
    // still captured rather than clipped at the image edge. The pane's own
    // bounds are the darker rectangle inside it.
    let canvas = NSView(frame: NSRect(
        x: 0, y: 0, width: paneWidth + pad * 2, height: 60 + pad * 2
    ))
    canvas.wantsLayer = true
    canvas.layer?.backgroundColor = NSColor(white: 0.36, alpha: 1).cgColor
    pane.frame.origin = NSPoint(x: pad, y: pad)
    canvas.addSubview(pane)

    canvas.layoutSubtreeIfNeeded()
    canvas.displayIfNeeded()
    guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return }
    canvas.cacheDisplay(in: canvas.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: out + "/" + name + ".png"))
    let overflow = width - (paneWidth - PaneClusterMetrics.cornerInset * 2)
    let note = overflow > 0.5 ? "  OVERFLOWS by \(Int(overflow.rounded()))pt" : ""
    print("  \(name).png  pane \(Int(paneWidth))pt, pill \(Int(width.rounded()))pt\(note)")
}

MainActor.assumeIsolated {
    print("levels, at the width the pill wants:")
    for (level, name) in [
        (PaneStatus.Attention.none, "1-none"),
        (.asking, "2-asking"),
        (.acknowledged, "3-acknowledged"),
        (.done, "4-done"),
    ] as [(PaneStatus.Attention, String)] {
        write(makeView(level, width: 400), name, paneWidth: 400)
    }

    // The judgment the measurement cannot make: an asking pane on a pane too
    // narrow to seat its own pill. The capsule floor with attention alone went
    // 22 -> 37 when the dot gained its glyph, so this is where that shows.
    print("")
    print("narrow panes, asking (the overflow question):")
    for width in [140.0, 100.0, 70.0, 50.0, 30.0] {
        write(makeView(.asking, width: width), "narrow-\(Int(width))", paneWidth: width)
    }
}
