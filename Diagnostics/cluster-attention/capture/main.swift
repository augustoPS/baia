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

/// The pill on a backdrop, so the capture shows what the eye would see rather
/// than a pill floating on transparency.
@MainActor func write(_ view: PaneClusterView, _ name: String, pad: Double = 16) {
    view.layoutSubtreeIfNeeded()
    let size = view.intrinsicContentSize
    let width = size.width > 0 ? size.width : view.bounds.width
    view.frame = NSRect(x: 0, y: 0, width: width, height: PaneClusterMetrics.height)
    view.layoutSubtreeIfNeeded()

    let canvas = NSView(frame: NSRect(
        x: 0, y: 0, width: width + pad * 2, height: PaneClusterMetrics.height + pad * 2
    ))
    canvas.wantsLayer = true
    // The pane behind the pill, so the capture reads like the app.
    canvas.layer?.backgroundColor = NSColor(
        srgbRed: CGFloat(PaneTheme.darkPastel.background.red),
        green: CGFloat(PaneTheme.darkPastel.background.green),
        blue: CGFloat(PaneTheme.darkPastel.background.blue),
        alpha: 1
    ).cgColor
    view.frame.origin = NSPoint(x: pad, y: pad)
    canvas.addSubview(view)

    canvas.layoutSubtreeIfNeeded()
    canvas.displayIfNeeded()
    guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return }
    canvas.cacheDisplay(in: canvas.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    let path = out + "/" + name + ".png"
    try? png.write(to: URL(fileURLWithPath: path))
    print("  \(name).png  \(Int(width))x\(Int(PaneClusterMetrics.height))pt")
}

MainActor.assumeIsolated {
    print("levels, at the width the pill wants:")
    for (level, name) in [
        (PaneStatus.Attention.none, "1-none"),
        (.asking, "2-asking"),
        (.acknowledged, "3-acknowledged"),
        (.done, "4-done"),
    ] as [(PaneStatus.Attention, String)] {
        write(makeView(level, width: 400), name)
    }

    // The judgment the measurement cannot make: an asking pane on a pane too
    // narrow to seat its own pill. The capsule floor with attention alone went
    // 22 -> 37 when the dot gained its glyph, so this is where that shows.
    print("")
    print("narrow panes, asking (the overflow question):")
    for width in [120.0, 80.0, 60.0, 40.0] {
        write(makeView(.asking, width: width), "narrow-\(Int(width))")
    }
}
