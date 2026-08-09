import AppKit
import BaiaSettings
import PaneChrome
import SwiftUI
import WorkspaceLayout

// The pane-glass-stacking spike: when a pane-wide `NSGlassEffectView` plane goes
// in behind the whole pane, what happens to the footer's own glass backing that
// already lives inside the pane's bounds?
//
// `PaneStatusBarView`'s sibling-glass audit (Task 5) says the moment a second
// glass element joins the footer, both belong in one `NSGlassEffectContainerView`,
// per the HIG's ban on stacked glass (glass sampling glass). Pane-as-glass is
// that moment arriving from the other direction: the footer's backing would sit
// on top of the pane's plane. Two candidate resolutions, measured side by side
// with the violation they both avoid:
//
//   ABSORB     one pane-wide plane, no footer glass at all; the footer's content
//              draws directly over the plane's bottom strip, and the plane's own
//              mask carries the window's bottom corners.
//   CONTAINER  plane + separate footer glass, grouped in one
//              `NSGlassEffectContainerView` (spacing 0), the HIG-permitted shape.
//   VIOLATION  plane + separate footer glass, hand-stacked, no container — the
//              naive port of today's hierarchy, the thing the HIG bans.
//
// Two further arms were added on 2026-08-09, after ABSORB shipped (a15d28e,
// cbf3f90). The four above are a *mock* — a transcribed squircle, a drawn
// stand-in footer — so they measure the arrangement rather than the code. These
// two measure the code:
//
//   SHIPPED-ABSORB     `Sources/PaneGlassPlane.swift` and
//                      `Sources/PaneStatusBarView.swift` compiled VERBATIM into
//                      this binary, with the real `WindowCorner` mask: a
//                      `PaneGlassPlaneView` + `PaneGlassWashView` pair at pane
//                      size, hosted the way `TerminalPaneController
//                      .installGlassPlane()` hosts them, with a real
//                      `PaneStatusBarView` (`resolvedChrome = .glass`, so it
//                      draws no fill) over the bottom `PaneStatusBarMetrics
//                      .height` points. Acceptance: NO luminance step at the
//                      footer's top edge beyond the 1-2 unit noise floor the
//                      spike measured between ABSORB and CONTAINER.
//   SHIPPED-VIOLATION  the negative control, per the damage-the-feature rule:
//                      the same shipped arrangement with the deleted
//                      hand-stacked footer glass put back — one bare
//                      `NSGlassEffectView` under the bar region. The seam must
//                      RETURN (+19..21/255 over the dark half in the original
//                      spike). `run.sh` inverts it: if the control stops
//                      showing a seam, the shipped assertion proves nothing and
//                      the run fails.
//
// This binary never becomes key and never activates. `NSApp.setActivationPolicy(
// .accessory)` plus `orderFrontRegardless()` is the `SAFE_PROBES` standard
// (`glass-backdrop` is the precedent: windows on screen ~15 s, keyboard never
// leaves the owner). Every window overrides `canBecomeKey`/`canBecomeMain` to
// false and nothing here calls `makeKey` or `activate`.
//
// Every comparison is within-run: `all-arms-screen.png` carries every arm in a
// single frame (by-eye only — stacked 16 pt apart the planes sample each
// other, see the group-portrait comment in main), and the measured captures
// are taken solo, each carrying raw-backdrop margin strips as its own tone
// reference. Capture rules are
// `glass-backdrop`'s, and the route this probe measures through is `-R`, not
// `-l`: the first run of this probe found the pane-wide plane's `-l` buffer is
// a flat unsampled slab (`#141414`, text ink on top) at every settle while the
// `-R` grab carries the full white/black split — the same window-server-level
// compositing glass-backdrop's README documents for its 220 pt sidebar column.
// A 22 pt strip composites its sampling into its own window's buffer; a
// pane-sized `NSGlassEffectView` does not. `-l` is still captured, because its
// alpha channel is the one route that carries each arm's corner mask exactly
// (α=0 outside the squircle).

// MARK: - the window corner squircle

/// The window's bottom-corner squircle, mirrored from `Sources/WindowCorner.swift`
/// (radius 16, `.continuous`), which the probe cannot import: it lives in the app
/// target, not a package. The construction is copied exactly — SwiftUI
/// `UnevenRoundedRectangle` rather than `NSBezierPath(roundedRect:)`, because the
/// system corner is a squircle and a circular arc is visibly the wrong shape.
/// If `WindowCorner.radius` moves, this constant is stale; the README names that
/// caveat.
enum ProbeCorner {
    static let radius: Double = 16

    /// The squircle with the *visual-bottom* corners rounded, in this probe's
    /// layer space. The shape names its rounded corners "top", and that is not
    /// a mistake: the first run of this probe rounded "bottom" (the shipped
    /// spelling, correct inside `PaneStatusBarView`'s flipped hierarchy) and
    /// the corner probes came back with the *top* corners transparent — a
    /// probe-built glass view's `CAShapeLayer` mask evaluates in y-up layer
    /// coordinates even under a flipped superview, so SwiftUI's y-down "bottom"
    /// lands at the visual top. Measured, then inverted here; the corner probes
    /// in `run.sh` re-verify the orientation on every run (top corners must
    /// read as glass, bottom corners as α=0).
    static func cgPath(in rect: NSRect) -> CGPath {
        UnevenRoundedRectangle(
            topLeadingRadius: radius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: radius,
            style: .continuous
        ).path(in: rect).cgPath
    }

    /// The mask `PaneStatusBarView.updateGlassMask()` builds — a `CAShapeLayer`
    /// carrying the window squircle in the view's own bounds — modulo the
    /// orientation note on ``cgPath(in:)``.
    static func mask(_ view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let mask = CAShapeLayer()
        mask.frame = view.bounds
        mask.path = cgPath(in: view.bounds)
        layer.mask = mask
    }
}

// MARK: - the controlled backdrop

/// A full-screen window of pure white beside pure black, seam vertical at the
/// screen's midline, ordered below the probe windows. Copied from
/// `glass-backdrop/backdroptest.swift`: the desktop cannot be the backdrop,
/// because glass adapts to what is behind it and a wallpaper-graded arm is
/// different on every machine. The mid-grey rulers make displaced edges visible
/// to a human eye comparing arms.
final class BackdropWindow: NSWindow {
    static func make(covering frame: NSRect) -> BackdropWindow {
        let window = BackdropWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // `.floating`, not glass-backdrop's `.normal - 1`. At `normal - 1` any
        // ordinary window that happens to sit in the capture region — and this
        // probe was bitten by one mid-run — slots between the backdrop and the
        // pane, and the glass samples *it* instead of the controlled field:
        // the margin tone references caught a solo capture whose "white"
        // margin read `#3a4554`. Floating puts the backdrop above every
        // normal-level window, so the backdrop really is the thing sampled.
        // The cost is honest and stated: for ~20 s the whole screen is a
        // white/black field with the probe panes on it. No focus moves.
        window.level = .floating
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        window.contentView = BackdropView(frame: NSRect(origin: .zero, size: frame.size))
        return window
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }
}

final class BackdropView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_: NSRect) {
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height).fill()
        NSColor.black.setFill()
        NSRect(
            x: bounds.width / 2,
            y: 0,
            width: bounds.width - bounds.width / 2,
            height: bounds.height
        ).fill()

        NSColor(white: 0.5, alpha: 1).setFill()
        var y = bounds.height * 0.25
        while y < bounds.height {
            NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
            y += 24
        }
    }
}

// MARK: - pane content stand-ins

/// A flipped plain container, so frames and the corner mask share the shipped
/// footer's coordinate convention (top-left origin).
class FlippedView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// Terminal-ish rows above the footer, drawn as a sibling above the glass the
/// way ghostty's grid sits above pane chrome. Rows stop 70 pt short of the
/// bottom on purpose: the surface measurement band (y 0.79–0.88 of the pane)
/// must contain glass only, no ink, or the band mean is part text.
final class TerminalTextView: FlippedView {
    override func draw(_: NSRect) {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(white: 0.86, alpha: 1),
        ]
        var y: CGFloat = 8
        var row = 0
        while y < bounds.height - 70 {
            let line = row % 3 == 0
                ? "$ git status --porcelain=v2 --branch  # row \(row)"
                : "  MM Sources/PaneStatusBarView.swift          \(row)"
            line.draw(at: NSPoint(x: 8, y: y), withAttributes: attributes)
            y += font.boundingRectForFont.height + 3
            row += 1
        }
    }
}

/// The footer's drawn content — capsule and segments — at the real metrics, read
/// off `PaneChrome` at run time rather than transcribed, same rule as
/// `glass-backdrop`. Drawn as a sibling *above* the glass in every arm, which is
/// the shipped hierarchy (`PaneStatusBarView` adds its glass below
/// `attentionWash`; content never goes through `contentView`). Identical across
/// arms, so any footer-band difference between arms is the glass arrangement and
/// nothing else.
///
/// No hairline: the shipped 1 pt hairline would land inside the measurement band
/// (y 0.9875–0.9979 of the pane), and it is identical across arms anyway.
final class FooterTextView: FlippedView {
    override func draw(_: NSRect) {
        let capsule = PaneStatusBarMetrics.attentionCapsuleFrame(glyphWidth: 7)
        let capsuleRect = NSRect(
            x: capsule.x, y: capsule.y, width: capsule.width, height: capsule.height
        )
        NSColor(srgbRed: 0.92, green: 0.55, blue: 0.15, alpha: 0.9).setFill()
        NSBezierPath(
            roundedRect: capsuleRect,
            xRadius: capsuleRect.height / 2,
            yRadius: capsuleRect.height / 2
        ).fill()

        let glyph: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        "!".draw(
            at: NSPoint(x: capsuleRect.midX - 2.5, y: capsuleRect.minY + 2),
            withAttributes: glyph
        )

        let text: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(white: 0.92, alpha: 1),
        ]
        let x = PaneStatusBarMetrics.horizontalInset + capsule.width
            + PaneStatusBarMetrics.capsuleGap
        "baia · main ↑1↓2*3 · claude · ~/Projects/baia".draw(
            at: NSPoint(x: x, y: PaneStatusBarMetrics.baselineFromTop - 11),
            withAttributes: text
        )
    }
}

// MARK: - the arms

enum Arm: String, CaseIterable {
    /// One pane-wide plane; the footer's own backing is deleted and its content
    /// draws directly on the plane's bottom strip. The window-corner mask has to
    /// live on the shared plane.
    case absorb

    /// Plane + separate footer glass, both children of one
    /// `NSGlassEffectContainerView` with `spacing = 0` — the arrangement the
    /// audit comment says the HIG permits. The footer glass keeps its own
    /// corner mask, and whether that mask survives the container's managed
    /// merge is one of the things the captures answer.
    case container

    /// Plane + separate footer glass, hand-stacked with no container: glass
    /// directly sampling glass, the arrangement the HIG bans. Captured to show
    /// what the ban visibly costs — or that it costs nothing visible here,
    /// which would be just as much a finding.
    case violation

    /// Supplementary to `container`, prompted by the first run: the corner
    /// probes there showed *every* corner opaque, i.e. the container dropped
    /// the `CAShapeLayer` masks its child glass views carried. If child masks
    /// do not survive the container's managed merge, the practical fallback is
    /// one mask on the container itself — both shapes share the same bottom
    /// corners, so a pane-shaped outer mask serves footer and plane alike.
    /// This arm is that fallback, so the run answers whether it works rather
    /// than leaving it to the spec to guess.
    case containerOutermask = "container-outermask"

    /// The shipped arrangement, built from the shipped types rather than from
    /// a mock: `PaneGlassPlaneView` + `PaneGlassWashView` + a real
    /// `PaneStatusBarView` under `resolvedChrome = .glass`. See
    /// ``shippedPaneStack(root:paneBounds:footerFrame:handStackedFooterGlass:)``.
    case shippedAbsorb = "shipped-absorb"

    /// ``shippedAbsorb`` with the deleted footer glass put back, hand-stacked.
    /// The negative control: it must show the seam the shipped arm must not.
    case shippedViolation = "shipped-violation"

    /// The four mock arms, which answered the spec's fork. Kept as a group
    /// because the README's finding table and the corner-probe table are about
    /// these four and their transcribed squircle.
    static let mockArms: [Arm] = [.absorb, .container, .violation, .containerOutermask]

    /// The two arms built from `Sources/`. Measured with the same bands as the
    /// mock arms, but asserted rather than tabulated: the shipped one must show
    /// no step, the control must show one.
    static let shippedArms: [Arm] = [.shippedAbsorb, .shippedViolation]
}

/// One pane-shaped window: transparent, non-opaque, a pane-wide glass plane at
/// the bottom of the z-order sampling the controlled backdrop through the
/// window, with terminal and footer content as siblings above — per arm.
final class PaneWindow: NSWindow {
    static func make(arm: Arm, contentRect: NSRect) -> PaneWindow {
        let window = PaneWindow(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Against the 26.2 regression (§6.8, forums 810314): glass in a
        // borderless *non-movable* transparent window stops re-sampling.
        // `glass-backdrop` sets this on every window and so does this probe.
        window.isMovable = true
        // Same level as the backdrop; ordering front after it puts the pane
        // above it within the level. See `BackdropWindow` for why floating.
        window.level = .floating
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]

        let size = contentRect.size
        let root = FlippedView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        window.contentView = root

        let barHeight = PaneStatusBarMetrics.height
        let paneBounds = NSRect(origin: .zero, size: size)
        let footerFrame = NSRect(
            x: 0,
            y: size.height - barHeight,
            width: size.width,
            height: barHeight
        )

        // The pane-wide plane, common to all three arms: untinted `regular`
        // glass, `cornerRadius = 0`, the window-corner squircle as a layer mask
        // — the same three settings the shipped footer backing uses
        // (`applyResolvedChrome()` + `updateGlassMask()`), applied pane-wide.
        func makePlane() -> NSGlassEffectView {
            let plane = NSGlassEffectView(frame: paneBounds)
            plane.style = .regular
            plane.cornerRadius = 0
            ProbeCorner.mask(plane)
            return plane
        }

        // The footer's own backing, as `PaneStatusBarView` builds it: untinted
        // `regular` glass, `cornerRadius = 0`, masked to the window's bottom
        // corners in its own 22 pt bounds (the curve is taller than the strip
        // and gets cut by the strip's top, exactly as shipped).
        func makeFooterGlass() -> NSGlassEffectView {
            let glass = NSGlassEffectView(frame: footerFrame)
            glass.style = .regular
            glass.cornerRadius = 0
            ProbeCorner.mask(glass)
            return glass
        }

        switch arm {
        case .absorb:
            root.addSubview(makePlane())
        case .container, .containerOutermask:
            let container = NSGlassEffectContainerView(frame: paneBounds)
            container.spacing = 0
            let row = FlippedView(frame: paneBounds)
            let plane = makePlane()
            row.addSubview(plane)
            let footerGlass = makeFooterGlass()
            row.addSubview(footerGlass, positioned: .above, relativeTo: plane)
            container.contentView = row
            root.addSubview(container)
            if arm == .containerOutermask {
                // The fallback the first run motivated: one mask on the
                // container. The children keep theirs too — the question is
                // whether the outer one clips what the inner ones could not.
                ProbeCorner.mask(container)
            } else {
                // Masks re-applied *after* the `contentView` assignment, so a
                // container that rebuilds its layer tree on assignment gets
                // the fairest possible chance of honouring them.
                ProbeCorner.mask(plane)
                ProbeCorner.mask(footerGlass)
            }
        case .violation:
            let plane = makePlane()
            root.addSubview(plane)
            root.addSubview(makeFooterGlass(), positioned: .above, relativeTo: plane)
        case .shippedAbsorb, .shippedViolation:
            // The shipped arms build their own content too — a real
            // `PaneStatusBarView` rather than `FooterTextView` — so they return
            // before the shared drawn stand-ins below.
            shippedPaneStack(
                root: root,
                paneBounds: paneBounds,
                footerFrame: footerFrame,
                handStackedFooterGlass: arm == .shippedViolation
            )
            return window
        }

        // Content siblings above the glass assembly, identical in every arm, so
        // the only thing that differs between arms is the glass arrangement.
        let terminal = TerminalTextView(frame: paneBounds)
        root.addSubview(terminal)
        let footer = FooterTextView(frame: footerFrame)
        root.addSubview(footer)

        return window
    }

    /// The shipped pane-as-glass stack, from the shipped sources.
    ///
    /// Every glass and chrome view here is the app's own type, compiled
    /// verbatim by `run.sh` (`PaneGlassPlane.swift`, `PaneStatusBarView.swift`,
    /// `WindowCorner.swift`, and `PaneOverlayView.swift`, which
    /// `PaneStatusBarView` needs only to link). Nothing about the arrangement is
    /// transcribed: the plane's `style`/`cornerRadius`, the wash above it, and
    /// the `WindowCorner.cgPath` mask on both are the four lines
    /// `TerminalPaneController.installGlassPlane()` and
    /// `updateGlassPlaneMasks()` write, in the same order.
    ///
    /// Two deliberate differences from a live pane, both harmless to what is
    /// measured. There is no ghostty surface between the wash and the bar — the
    /// terminal text is the same `TerminalTextView` stand-in the mock arms draw,
    /// because a real surface needs Metal and a PTY and paints nothing into
    /// either measurement band. And the bar is frame-set rather than
    /// autolayout-pinned, since this window has no pane tree to constrain
    /// against; the bar's own drawing reads `bounds`, so the route in does not
    /// reach the pixels.
    ///
    /// - Parameter handStackedFooterGlass: the negative control. True puts one
    ///   bare `NSGlassEffectView` back under the bar region — the backing
    ///   `a15d28e` deleted — hand-stacked on the plane with no container, which
    ///   is the arrangement the `violation` arm measured as a +19..21/255 seam
    ///   over dark content. The seam must come back, or the shipped arm's
    ///   no-step assertion is measuring nothing.
    private static func shippedPaneStack(
        root: NSView,
        paneBounds: NSRect,
        footerFrame: NSRect,
        handStackedFooterGlass: Bool
    ) {
        // `TerminalPaneController.installGlassPlane()`, line for line.
        let plane = PaneGlassPlaneView(frame: paneBounds)
        plane.style = .regular
        plane.wantsLayer = true
        plane.cornerRadius = 0
        root.addSubview(plane)

        let wash = PaneGlassWashView(frame: paneBounds)
        wash.wantsLayer = true
        // `updateGlassWashColour()`'s derivation. Both inputs are read off the
        // packages at run time — `PaneTheme.darkPastel.background` and
        // `ChromeMaterials.PaneWash.opacity` — so a move of the wash floor
        // reaches this probe without an edit, the same rule the footer metrics
        // follow. Only the `RGB` -> `NSColor` step is spelled here rather than
        // called: the shipped call goes through `ChangesSurface.nsColor`, which
        // lives in a 583-line file that builds a whole scrolling changes view,
        // and linking that to reach a six-line explicit-sRGB conversion would
        // drag the probe into the app target for nothing. The conversion is
        // identical (`srgbRed:green:blue:alpha:`, deliberately not the
        // calibrated-space initializer, for the reason `PaneStatusBarView
        // .nsColor` documents).
        //
        // `backgroundOpacity` comes off `Settings.default` rather than being
        // named here, and that matters more than it looks: at 1 the wash is
        // fully opaque (`max(1, floor)`) and there is no glass left to measure —
        // the first run of these arms passed 1, and both captures came back with
        // the white and the dark half of the backdrop reading the same 20.00,
        // i.e. a pane sampling nothing. 1 is not even a state glass reaches;
        // `windowIsTransparent(backgroundOpacity:appearance:)` gates the whole
        // glass path on `< 1`.
        let washBackground = PaneTheme.darkPastel.background
        wash.colour = NSColor(
            srgbRed: CGFloat(washBackground.red),
            green: CGFloat(washBackground.green),
            blue: CGFloat(washBackground.blue),
            alpha: CGFloat(ChromeMaterials.PaneWash.opacity(
                backgroundOpacity: Settings.defaultSettings.backgroundOpacity,
                floorOverride: nil
            ))
        )
        root.addSubview(wash, positioned: .above, relativeTo: plane)

        // The control: the footer backing ABSORB deleted, put back by hand
        // above the plane and the wash, in the bar's own bounds with the same
        // corner mask the retired `updateGlassMask()` gave it.
        if handStackedFooterGlass {
            let footerGlass = NSGlassEffectView(frame: footerFrame)
            footerGlass.style = .regular
            footerGlass.cornerRadius = 0
            footerGlass.wantsLayer = true
            let mask = CAShapeLayer()
            mask.frame = NSRect(origin: .zero, size: footerFrame.size)
            mask.path = ProbeCorner.cgPath(in: mask.frame)
            footerGlass.layer?.mask = mask
            root.addSubview(footerGlass, positioned: .above, relativeTo: wash)
        }

        // Terminal ink above the glass, as in every other arm. The measurement
        // bands are clear of it by construction (`TerminalTextView` stops 70 pt
        // short of the bottom).
        root.addSubview(TerminalTextView(frame: paneBounds))

        // The shipped footer: glass chrome, window active, both bottom corners
        // (this probe's pane is the whole window). Under `.glass` `draw(_:)`
        // paints no fill, which is the property the no-step assertion is about:
        // if that skip ever regressed, the footer band would step away from the
        // surface band whatever the glass underneath it did.
        //
        // `isFocused` is false, and that is a measurement decision rather than
        // a claim about the common state. The focus frame is a 2 pt stroke on
        // the bar's own top edge (`drawBarFrame`, flipped, `y: 0`), which in
        // pane coordinates is y 178-180 — the exact rows the seam band reads.
        // The first run of these arms had it on and both arms measured a +27
        // and +44 "step" that was the stroke, not the glass. It draws
        // identically in the shipped arm and in its control, so it would not
        // have made the control pass falsely; it would have hidden whatever the
        // glass was doing underneath it in both. An unfocused pane is what the
        // other three panes on a four-pane screen look like anyway.
        let bar = PaneStatusBarView(frame: footerFrame)
        bar.resolvedChrome = .glass(.dark)
        bar.theme = .darkPastel
        bar.isFocused = false
        bar.isWindowActive = true
        bar.bottomCorners = .both
        bar.status = PaneStatus(
            anchorName: "baia",
            anchorIsRepository: true,
            isPinned: false,
            workingDirectory: nil,
            git: PaneStatus.Git(
                head: "main",
                hasUpstream: true,
                ahead: 1,
                behind: 2,
                dirty: true,
                untracked: 3,
                conflicted: 0,
                operation: nil,
                isLinkedWorktree: false
            ),
            agent: PaneStatus.Agent(label: "claude", wantsAttention: false)
        )
        root.addSubview(bar)

        // `updateGlassPlaneMasks()`, after the views are in the hierarchy and
        // sized, exactly as the controller calls it at the end of
        // `installGlassPlane()`. Both views declare `isFlipped: true`, which is
        // `WindowCorner.cgPath`'s stated precondition and the thing cbf3f90
        // fixed; a regression there rounds the TOP corners and the corner probes
        // in `run.sh` catch it.
        for masked in [plane, wash] as [NSView] {
            guard let layer = masked.layer else { continue }
            let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
            mask.frame = masked.bounds
            mask.path = WindowCorner.cgPath(in: masked.bounds, corners: .both)
            layer.mask = mask
        }
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }
}

// MARK: - capture (glass-backdrop's rules)

func runScreencapture(_ arguments: [String], to path: String) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x"] + arguments + [path]
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        FileHandle.standardError.write("capture failed to launch: \(error)\n".data(using: .utf8)!)
        return false
    }
    return task.terminationStatus == 0 && FileManager.default.fileExists(atPath: path)
}

/// The global-display rect for `screencapture -R`, from an AppKit frame:
/// origin flips against the main screen's full frame (not the visible frame),
/// each edge rounded and the size derived from the rounded edges.
func displayRect(for frame: NSRect) -> String? {
    guard let main = NSScreen.screens.first else { return nil }
    let left = frame.minX.rounded()
    let right = frame.maxX.rounded()
    let top = (main.frame.maxY - frame.maxY).rounded()
    let bottom = (main.frame.maxY - frame.minY).rounded()
    return "\(Int(left)),\(Int(top)),\(Int(right - left)),\(Int(bottom - top))"
}

/// How far beyond the window's frame each `-R` grab reaches, in points. The
/// margin strips are raw controlled backdrop — white on the left, black on the
/// right — captured in the same frame as the arm, so every solo capture
/// carries its own tone reference: if the display's response drifted between
/// two solo grabs, their margin strips disagree and the analysis can see it
/// rather than mistake drift for an arm difference.
let captureMargin: CGFloat = 40

/// One window, photographed twice: `-R` (the measured route — a pane-sized
/// `NSGlassEffectView` composites at the window-server level, so its `-l`
/// buffer is a flat unsampled slab however long the probe settles, the same
/// behaviour glass-backdrop documents for its sidebar column) and `-l` for the
/// mask geometry, whose alpha channel is exact (α=0 outside the squircle).
/// `-R` absolutes carry the display's tone response at capture time and are
/// within-run only; every comparison this probe makes is within-run.
func capture(window: NSWindow, to path: String) -> Bool {
    guard runScreencapture(["-l", String(window.windowNumber)], to: path) else {
        return false
    }
    if let rect = displayRect(for: window.frame.insetBy(dx: -captureMargin, dy: -captureMargin)) {
        let screenPath = path.replacingOccurrences(of: ".png", with: "-screen.png")
        _ = runScreencapture(["-R", rect], to: screenPath)
    }
    return true
}

/// Reads one pixel out of a fresh capture, for the sampled-check only; the
/// README's numbers come from `Diagnostics/lib/pixel.py` against the files.
func samplePixel(_ path: String, fx: Double, fy: Double) -> (Int, Int, Int)? {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return nil }
    let x = min(max(Int(Double(cg.width) * fx), 0), cg.width - 1)
    let y = min(max(Int(Double(cg.height) * fy), 0), cg.height - 1)

    var pixel = [UInt8](repeating: 0, count: 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: &pixel,
              width: 1,
              height: 1,
              bitsPerComponent: 8,
              bytesPerRow: 4,
              space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }
    context.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
    return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
}

/// Did the glass sample? Two samples either side of the seam differ by tens of
/// units when it did and by a rounding error when it did not.
///
/// Reads the `-R` companion, never the `-l` file: pane-wide glass composites
/// at the window-server level, so the `-l` buffer is flat regardless of how
/// long the run settles — checking it would loop all six attempts on every
/// arm, which is exactly what the first run of this probe did.
func sampledAcross(_ path: String, left: Double, right: Double, y: Double) -> Bool {
    let screenPath = path.replacingOccurrences(of: ".png", with: "-screen.png")
    let readable = FileManager.default.fileExists(atPath: screenPath) ? screenPath : path
    guard let l = samplePixel(readable, fx: left, fy: y),
          let r = samplePixel(readable, fx: right, fy: y) else { return false }
    let delta = abs(l.0 - r.0) + abs(l.1 - r.1) + abs(l.2 - r.2)
    return delta > 12
}

/// Runs the run loop rather than sleeping: a glass view that has not had a
/// display pass captures as an unsampled slab.
func settle(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

// MARK: - main

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSTemporaryDirectory() + "baia-pane-glass-stacking"

try? FileManager.default.createDirectory(
    atPath: outputDirectory, withIntermediateDirectories: true
)

let app = NSApplication.shared
// `.accessory`, never `.regular`; every window below is `orderFrontRegardless()`,
// never `makeKeyAndOrderFront`. The SAFE_PROBES standard.
app.setActivationPolicy(.accessory)

guard let screen = NSScreen.main else {
    FileHandle.standardError.write("no screen\n".data(using: .utf8)!)
    exit(1)
}

let screenFrame = screen.frame

// The panes stack vertically, every one centred on the backdrop's vertical
// seam, so each arm carries the bright half on its left and the dark half on
// its right — the same local backdrop for all of them, which is what makes the
// arm-to-arm band deltas mean something. 200 pt per pane rather than a pane's
// realistic height, so four arms fit a 900 pt laptop screen; the footer strip
// is still the real 22 pt read off `PaneStatusBarMetrics`.
let arms = Arm.allCases
let paneWidth: CGFloat = 720
let paneHeight: CGFloat = 200
let paneGap: CGFloat = 16
// The group portrait's stack is the four mock arms only, and the layout is
// sized for them. Six 200 pt panes do not fit a 900 pt screen, and the two
// shipped arms have no business in that frame anyway: it is a by-eye
// side-by-side of the spec's fork, which they postdate. They are laid out
// underneath it and only ever photographed solo, which is the measured route
// for every arm.
let portraitArms = Arm.mockArms
let stackHeight = paneHeight * CGFloat(portraitArms.count)
    + paneGap * CGFloat(portraitArms.count - 1)
let stackBottom = screenFrame.midY - stackHeight / 2

let backdrop = BackdropWindow.make(covering: screenFrame)
backdrop.orderFrontRegardless()
settle(0.6)

var failures = 0
var windows: [(Arm, PaneWindow)] = []
var portraitWindows: [PaneWindow] = []
for arm in arms {
    let frame: NSRect
    if let index = portraitArms.firstIndex(of: arm) {
        frame = NSRect(
            x: screenFrame.midX - paneWidth / 2,
            y: stackBottom
                + CGFloat(portraitArms.count - 1 - index) * (paneHeight + paneGap),
            width: paneWidth,
            height: paneHeight
        )
    } else {
        // A shipped arm: the portrait stack's own top slot, reused. It is
        // only ever captured solo, with every other pane ordered out, so it
        // can share a frame with an arm it is never on screen beside — and it
        // must be somewhere the controlled backdrop actually reaches.
        //
        // The first version of this parked the shipped arms below the stack
        // and the captures came back with the Dock across the footer band and
        // the desktop wallpaper behind the glass: the Dock outranks
        // `.floating`, so a pane placed over it is neither backed by the
        // controlled field nor unobstructed. Screen-centred, which the four
        // mock arms already are, is the safe region — the backdrop covers the
        // whole screen but only the middle of it is free of system chrome.
        frame = NSRect(
            x: screenFrame.midX - paneWidth / 2,
            y: stackBottom + CGFloat(portraitArms.count - 1) * (paneHeight + paneGap),
            width: paneWidth,
            height: paneHeight
        )
    }
    let window = PaneWindow.make(arm: arm, contentRect: frame)
    windows.append((arm, window))
    if portraitArms.contains(arm) {
        window.orderFrontRegardless()
        portraitWindows.append(window)
    }
}

// One `-R` over the whole stack first, while every mock arm is on screen: the
// one file in which those four share a single tone-curve instant, for by-eye
// comparison. Not the measured file: with the stack 16 pt apart, a plane
// samples its glass neighbours above and below — the first all-on-screen run
// measured the sandwiched arms' planes up to 26 units darker than the same
// plane at the stack's edge, which is the neighbour bleeding in, not the arm.
settle(2.0)
let union = portraitWindows.map(\.frame).reduce(portraitWindows[0].frame) { $0.union($1) }
if let rect = displayRect(for: union.insetBy(dx: -12, dy: -12)) {
    if runScreencapture(["-R", rect], to: outputDirectory + "/all-arms-screen.png") {
        print("captured all-arms-screen.png")
    } else {
        print("CAPTURE FAILED all-arms-screen")
        failures += 1
    }
}

// The measured captures are solo: one arm on screen at a time, every other
// pane ordered out, so nothing but the controlled backdrop is within sampling
// reach. Cross-arm tone stability is carried by each capture's own margin
// strips (see `captureMargin`).
//
// The sampled-check reads the footer's clean bottom band (no glyphs reach it;
// the descenders end ~2.5 pt below the bar's baseline), either side of the
// seam, through the margined `-R` companion. The README bands are pixel.py's
// business.
let screenW = Double(paneWidth + captureMargin * 2)
let screenH = Double(paneHeight + captureMargin * 2)
let footerCheckY = (Double(captureMargin) + 0.99 * Double(paneHeight)) / screenH
let footerCheckL = (Double(captureMargin) + 0.2 * Double(paneWidth)) / screenW
let footerCheckR = (Double(captureMargin) + 0.8 * Double(paneWidth)) / screenW

let baseSettle: TimeInterval = 0.8

for (arm, window) in windows {
    for (_, other) in windows where other !== window { other.orderOut(nil) }
    window.orderFrontRegardless()
    let path = outputDirectory + "/pane-" + arm.rawValue + ".png"
    var written = false
    for attempt in 1 ... 6 {
        settle(baseSettle * Double(attempt))
        guard capture(window: window, to: path) else {
            print("CAPTURE FAILED pane-\(arm.rawValue)")
            failures += 1
            written = true
            break
        }
        if sampledAcross(path, left: footerCheckL, right: footerCheckR, y: footerCheckY) {
            print("captured pane-\(arm.rawValue).png\(attempt > 1 ? " (settled on attempt \(attempt))" : "")")
            written = true
            break
        }
    }
    if !written {
        print("CAPTURE UNSAMPLED pane-\(arm.rawValue) — glass did not sample in 6 attempts")
        failures += 1
    }
    window.orderOut(nil)
}

backdrop.orderOut(nil)

print("")
print("output: \(outputDirectory)")
if failures > 0 {
    print("FAILED \(failures) capture(s)")
    exit(1)
}
print("PASS all captures written")
