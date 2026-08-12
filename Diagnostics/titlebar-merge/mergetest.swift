import AppKit
import PaneChrome
import WorkspaceLayout

// Can the titlebar band and the sidebar column read as ONE glass panel?
//
// The window ships two separate `NSGlassEffectView` planes. `TitlebarGlassBacking`
// lives in the window's FRAME VIEW (`contentView.superview`), because the band sits
// above `contentView` and no public API hands it over; `SidebarGlassBacking` lives
// inside `contentView`, added below every sibling of `SidebarHost.view`. Two planes
// sampling independently meet at the top of the sidebar column, and the owner sees a
// seam there.
//
// A seam is a *step* in luminance down a vertical strip crossing the boundary. A
// merged panel is *continuous*. That is the whole measurement, and it is why every
// arm below is captured over the same controlled backdrop and read down the same
// strip: the arms differ only in how the two glass shapes are arranged.
//
// This binary never becomes key and never activates. `NSApp.setActivationPolicy(
// .accessory)` plus `orderFrontRegardless()` is the `SAFE_PROBES` standard that
// `glass-backdrop` meets, and this probe meets it the same way — including the
// windows it briefly puts on screen. A focus steal mid-capture would land keystrokes
// in whatever the owner was typing into.
//
// The captures are read through `-R`, not `-l`, and that is forced rather than
// chosen: see `capture(window:to:)`. These windows are `.titled` with a real toolbar,
// and the titlebar band is composited by the window server over the window's own
// backing store. `-l` returns the backing store alone, which for arm 1 contains the
// frame-view glass but not what AppKit paints over it.

// MARK: - the controlled backdrop

/// A full-screen window of pure white above pure black, ordered below the probe
/// window.
///
/// **Split horizontally, where `glass-backdrop` splits vertically, and the rotation
/// is the measurement.** That probe asked whether a 22 pt bar adapts to what is
/// behind it, so it needed the bar to cross a *vertical* seam left-to-right. This
/// probe asks whether two stacked glass planes step at their shared *horizontal*
/// boundary. A vertical backdrop seam would put the same backdrop luminance above
/// and below the titlebar/column boundary, which is exactly the axis the strip is
/// read down — every arm would measure the same flat backdrop and the probe would
/// grade nothing.
///
/// So the halves meet on a horizontal line, and the probe window is positioned so
/// that line sits well clear of the titlebar/column boundary. The strip therefore
/// crosses a boundary where the *backdrop* is one constant colour, and any step it
/// finds is the glass, not the wallpaper. The backdrop's own seam is what proves the
/// glass is sampling at all.
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
        // **Above `.normal`, not below it, and this line is the fix for the defect
        // that made every absolute number this probe published meaningless.**
        //
        // The backdrop used to sit at `.normal - 1`, copied from `glass-backdrop`.
        // At that level it loses to *every ordinary window on screen*: the owner's
        // terminal, an editor, anything. `orderFrontRegardless()` only orders a
        // window to the front of its own level, so no amount of re-asserting can
        // lift a `.normal - 1` window above a `.normal` one. Two runs of the
        // unchanged probe minutes apart measured arm 1 at 38.00 and at 1.26, and
        // the second run's capture is a photograph of the operator's terminal read
        // through the glass — legible text, in every arm, not just arm 1.
        //
        // `glass-backdrop` never hit it because its probe windows are `.borderless`
        // and it never competes with a titled window for the same level. Titled
        // windows are the difference, and the README records the failure mode
        // without having closed it.
        //
        // So the backdrop is lifted to `.floating`, above `.normal` where every
        // ordinary window lives, and the probe window is lifted one step higher
        // still (see `ProbeWindow.init`) and explicitly ordered above the backdrop
        // before each capture. The ordering is then a property of the levels rather
        // than of what else happens to be on screen, and `assertBackdrop` below
        // proves it per arm rather than trusting it.
        window.level = .floating
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        let view = BackdropView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = view
        return window
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }
}

final class BackdropView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_: NSRect) {
        // White on top, black below. The probe window sits entirely within the
        // white half (see `probeFrame` in main), so the strip reads one backdrop
        // luminance from top to bottom and a step in it can only be the glass.
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height / 2).fill()
        NSColor.black.setFill()
        NSRect(
            x: 0,
            y: bounds.height / 2,
            width: bounds.width,
            height: bounds.height - bounds.height / 2
        ).fill()

        // Vertical mid-grey rulers. A human comparing two arms by eye needs
        // something with structure behind the glass: a plane that samples carries
        // the rulers through softened, and a step between two planes shows as the
        // rulers shifting or changing contrast across the boundary. A flat fill
        // behind glass can hide a merge failure that structure reveals.
        // **Started from x = 0 rather than from a quarter across, so the rulers
        // reach behind the probe window's COLUMN as well as behind its panes.**
        //
        // They used to start at `bounds.width * 0.25`, which is to the right of
        // where the 260 pt column lands, so the strip ran down a perfectly
        // featureless field. That is visible in the first corrected capture: flat
        // grey behind the column, rulers only over the surface stand-in. The
        // consequence was a noise floor of exactly 0.00 at all five positions and
        // therefore a threshold of 0.00, which would fail an arm on a single
        // quantisation step.
        //
        // A floor measured over a flat field is not this pipeline's floor. The
        // measurement the floor has to bound reads glass over *structure* — the
        // backdrop's rulers are what the boundary step is a discontinuity in — so
        // the floor has to be measured over structure too, or it is bounding a
        // quieter problem than the one being graded.
        NSColor(white: 0.5, alpha: 1).setFill()
        var x: CGFloat = 0
        while x < bounds.width {
            NSRect(x: x, y: 0, width: 1, height: bounds.height).fill()
            x += 24
        }

        // **Horizontal rulers as well, and they are what the noise floor is
        // measured on.** The vertical rulers above are constant down any vertical
        // line, so a strip read top-to-bottom crosses none of their structure: with
        // only those, the column still measures a dead-flat field and the floor
        // still comes out 0.00.
        //
        // The strip is a vertical read, so the structure it has to cross is
        // horizontal. These lines give the column exactly what the surface
        // stand-in's text gives the panes — something for the glass to carry, and
        // something for the pipeline to quantise — so the floor is measured over a
        // region with the same character as the boundary it bounds.
        //
        // Offset from the vertical rulers' 24 pt so the two grids do not beat
        // against each other into a coarser pattern than either.
        var y: CGFloat = 0
        while y < bounds.height {
            NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
            y += 19
        }
    }
}

// MARK: - the pane stand-in

/// The terminal surface stand-in: the theme background at the shipped well opacity
/// over a non-opaque window, so the backdrop shows through exactly as it does under
/// a real pane.
///
/// A plain fill rather than a live ghostty surface. That substitution is sound here
/// for the reason `glass-backdrop` gives for its own: what glass samples is the
/// composited pixels beneath its frame, and an alpha fill over the backdrop
/// composites to the same pixels whether a Metal layer or `NSColor` put them there.
/// This probe never asks a grid question, so it needs no PTY.
///
/// It sits to the *right* of the column and below the band, which is where the panes
/// actually are. It is not what the strip reads — the strip runs down the column —
/// but it has to be present, because a column with nothing beside it is not the
/// window whose seam the owner sees.
final class SurfaceStandIn: NSView {
    /// The shipped well opacity, matching `glass-backdrop`'s stand-in.
    static let wellOpacity: CGFloat = 0.42

    var themeBackground: NSColor = .init(
        srgbRed: 18.0 / 255, green: 20.0 / 255, blue: 24.0 / 255, alpha: 1
    )

    override var isFlipped: Bool { true }

    override func draw(_: NSRect) {
        themeBackground.withAlphaComponent(Self.wellOpacity).setFill()
        bounds.fill()

        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(white: 0.86, alpha: 1),
        ]
        var y: CGFloat = 8
        var row = 0
        while y < bounds.height {
            let line = row % 3 == 0
                ? "$ git status --porcelain=v2 --branch  # row \(row)"
                : "  MM Sources/SurfaceHosts.swift              \(row)"
            line.draw(at: NSPoint(x: 8, y: y), withAttributes: attributes)
            y += font.boundingRectForFont.height + 3
            row += 1
        }
    }
}

/// The column's own content: a heading and file rows, drawn so the column is not an
/// empty pane of glass.
///
/// Deliberately drawn *clear of the strip's x range*. The strip reads glass, and ink
/// inside it would be measured as a step that has nothing to do with the seam. See
/// `stripX` in main for the coordination.
final class ColumnContent: NSView {
    override var isFlipped: Bool { true }

    override func draw(_: NSRect) {
        let heading: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor(white: 0.86, alpha: 1),
        ]
        let row: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(white: 0.90, alpha: 1),
        ]
        // x = 110 puts every glyph to the right of the strip, which reads
        // x-fractions well left of it.
        "FILES".draw(at: NSPoint(x: 110, y: 10), withAttributes: heading)
        var y: CGFloat = 30
        for name in ["Sources", "  SurfaceHosts.swift", "  WorkspaceWindow…", "Packages", "  PaneChrome"] {
            name.draw(at: NSPoint(x: 110, y: y), withAttributes: row)
            y += 20
        }
    }
}

// MARK: - the arms

enum Arm: String, CaseIterable {
    /// Arm 1, the control. Today's arrangement, reproduced rather than described:
    /// a `TitlebarGlassBacking` in the window's frame view and a separate
    /// `SidebarGlassBacking` inside `contentView`, both `.regular`, both
    /// `cornerRadius = 0`, both untinted. This is what the seam looks like now.
    case shippedTwoPlanes = "1-shipped-two-planes"

    /// Arm 2. Both planes as children of one `NSGlassEffectContainerView`, which is
    /// the API Apple provides for making adjacent glass shapes read as one.
    ///
    /// **The container's placement is the unknown this probe was commissioned to
    /// settle**, and the arm reports what it found rather than assuming. See
    /// `ContainerPlacement` and the README.
    case containerMerged = "2-container-merged"

    /// Arm 3. `.fullSizeContentView` with ONE glass plane spanning the band and the
    /// column, so there is no boundary to step across because there is only one
    /// sampling shape.
    case fullSizeOnePlane = "3-fullsize-one-plane"

    /// Arm 4. The same geometry with no glass at all: flat fills at the same frames.
    /// The control that says how much of any difference above is glass rather than
    /// layout. If arm 1's step survives here, the step is the layout's, not the
    /// material's.
    case flatControl = "4-flat-control"

    var usesGlass: Bool { self != .flatControl }

    /// **Arm 2 needs `.fullSizeContentView` too, and that is a finding rather than
    /// a convenience.** The container merges its own subviews, so both planes must
    /// live in `contentView` — and without `.fullSizeContentView` the content view
    /// stops below the titlebar, leaving the band region with no glass in it at
    /// all. The first run of this arm captured exactly that: a bare strip of
    /// backdrop where the band should be, traffic lights gone with it. Extending
    /// the content view under the titlebar is what gives the container a band
    /// region to put a plane in.
    ///
    /// The consequence is the headline cost: **the container route and the
    /// single-plane route need the same window-level change.** See the README.
    var wantsFullSizeContentView: Bool { self == .fullSizeOnePlane || self == .containerMerged }

    /// Whether the band's glass is a separate shape from the column's.
    ///
    /// True for arms 1 and 2 (two shapes, merged or not) and false for arm 3, which
    /// has one shape by construction.
    var hasTwoShapes: Bool { self == .shippedTwoPlanes || self == .containerMerged }
}

/// Where arm 2's `NSGlassEffectContainerView` ended up, which is a *finding* rather
/// than a configuration.
///
/// The honest arrangement is a container holding both the band plane and the column
/// plane while each stays in the hierarchy it ships in. That is structurally
/// impossible and the probe records why rather than papering over it:
/// `NSGlassEffectContainerView` merges the glass views that are its **subviews**, and
/// a view has exactly one superview. A plane in the frame view and a plane in
/// `contentView` cannot both be subviews of one container without one of them
/// leaving its hierarchy — at which point it is no longer where the app puts it.
///
/// So the arm is built the second way the brief allows: both planes in ONE hierarchy,
/// inside one container. It measures **the merge itself**, and says nothing about the
/// app's ability to reach that arrangement. What the app would have to change is in
/// the README's verdict.
enum ContainerPlacement {
    /// Both planes are subviews of one container. What this arm actually builds.
    case singleHierarchy

    var note: String {
        switch self {
        case .singleHierarchy:
            "container holds both planes in ONE hierarchy (contentView); the app's "
                + "frame-view/contentView split cannot be spanned by a container"
        }
    }
}

// MARK: - the probe window

/// One arm's window: a real titled window with a toolbar, a titlebar band, and a
/// sidebar-width column, over the controlled backdrop.
///
/// Everything about the window that is not the arm's variable is held at the app's
/// own values, read off the packages at run time where they exist
/// (`SidebarGeometry.default.width`) rather than transcribed, so an arm claiming to
/// reproduce the shipped arrangement cannot grade against a number that has moved.
final class ProbeWindow: NSWindow {
    let arm: Arm
    /// Held for the run. `NSWindow.toolbar` does not keep a toolbar alive on its
    /// own, and a deallocated toolbar takes the titlebar material with it — the
    /// retention `WorkspaceWindowController` documents on its own `toolbar`.
    private var heldToolbar: NSToolbar?
    private var heldViews: [NSView] = []

    /// What the arm ended up doing, for the run's report. Non-nil for arm 2 only.
    private(set) var placement: ContainerPlacement?

    /// Where the band plane and the column plane MEET, as a fraction of the
    /// window's frame height measured from its top edge.
    ///
    /// **Recorded by the arm that built the planes, rather than computed from the
    /// window afterwards, and getting that wrong cost this probe a wrong verdict.**
    /// The obvious formula is `(frame.height - contentLayoutRect.height) /
    /// frame.height` — the band as a share of the window — and it is wrong for two
    /// of the four arms. The frame includes chrome that is not the content view, so
    /// the fraction it produces is not where these particular planes abut: under
    /// arm 2 the two planes meet at the *content view's* own top inset, and the
    /// window-derived number pointed the strip at a row well above it, where the
    /// reading was the bare backdrop against the band. That is how a container arm
    /// that visibly merges was graded `SEAM` at 113.
    ///
    /// So each arm reports the y it actually built to, in window-frame terms.
    private(set) var planeBoundary: Double = 0

    /// The column plane's top edge in the content view's own (unflipped)
    /// coordinates, recorded by `buildArm` as it places the plane.
    private var recordedColumnTop: CGFloat?

    /// Whether the traffic lights survived this arm's arrangement, and whether they
    /// remained hit-testable. Both are asked of AppKit after the window is built.
    private(set) var trafficLightReport: String = ""

    init(arm: Arm, contentRect: NSRect) {
        self.arm = arm

        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if arm.wantsFullSizeContentView { style.insert(.fullSizeContentView) }

        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: .buffered,
            defer: false
        )

        title = "baia"
        subtitle = "~/Projects/baia"

        // The window arrangement `WorkspaceWindowController.applyTransparency()`
        // ships under a translucent theme: non-opaque, with a background one step
        // off clear. `.clear` is deliberately NOT used — that file measures the
        // titlebar material rendering as nothing over a clear background, and this
        // probe would then be grading a bare band rather than the app's.
        isOpaque = false
        backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.005)
        hasShadow = false

        // Against the 26.2 regression `glass-backdrop` honours (Apple forums
        // 810314): glass in a non-movable transparent window stops re-sampling as
        // content moves beneath it. A probe that left this false would measure the
        // bug rather than the material.
        isMovable = true
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]

        // One step above the backdrop's `.floating`, which is what makes the
        // stacking a property of the levels rather than of ordering luck. The
        // backdrop is above every ordinary window and this window is above the
        // backdrop, so the only thing the glass can sample is the controlled
        // white/black field. Ordering alone could not achieve this: within one
        // level `orderFrontRegardless()` is a race against whatever else is on
        // screen, and losing it is exactly the defect being fixed here.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

        // The empty toolbar is what gives the window a titlebar band at all on
        // macOS 26, and `.unifiedCompact` is the metric the app buys with it.
        // Reproduced rather than skipped: without the toolbar the band is a
        // different height and a different material, and the arm would be measuring
        // a window baia does not ship.
        let toolbar = NSToolbar(identifier: "probe.titlebar-merge.\(arm.rawValue)")
        heldToolbar = toolbar
        self.toolbar = toolbar
        toolbarStyle = .unifiedCompact

        let content = NSView(frame: .zero)
        content.wantsLayer = true
        contentView = content

        // The band height is read off the window rather than written as 40, for the
        // reason `layoutTitlebarGlass()` gives: it is whatever the window is
        // currently spending on chrome, so a toolbar metric this probe does not
        // control cannot leave the glass short of the band it is backing.
        let bandHeight = frame.height - contentLayoutRect.height
        let columnWidth = CGFloat(SidebarGeometry.default.width)

        // **Every frame below is derived from the LIVE content view, never from the
        // `contentRect` this window was asked for**, and the first version of this
        // probe got that wrong in a way the captures made obvious.
        //
        // `NSWindow(contentRect:)` does not give the content view that rect. Adding
        // a toolbar grows it: a 380 pt request measured 438 pt here, because
        // `.unifiedCompact` hands the content view the band's height back. Sizing
        // the glass against the requested 380 left a bare 58 pt strip of backdrop
        // between the band and the column — visible in the first run's capture as a
        // white gap, and read by the strip as a step that was the probe's own bug
        // rather than a seam.
        //
        // The content view is also **unflipped**: y = 0 is its BOTTOM edge. A column
        // anchored at y = 0 with the content view's full height reaches the top; one
        // sized to the requested rect stops short. Both mistakes were in the first
        // version at once.
        let bounds = content.bounds

        buildArm(
            content: content,
            bandHeight: bandHeight,
            columnWidth: columnWidth,
            contentBounds: bounds
        )

        recordTrafficLights()

        // The plane boundary, converted from the column plane's own top edge into
        // the fraction of the window frame the strip reads in. `convert(_:to: nil)`
        // goes to window coordinates, whose origin is the frame's bottom-left, so
        // the fraction from the TOP is `1 - y / frame.height`.
        if let columnTopInWindow = recordedColumnTop {
            let inWindow = content.convert(NSPoint(x: 0, y: columnTopInWindow), to: nil)
            planeBoundary = 1.0 - Double(inWindow.y / frame.height)
        }
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }

    /// Builds one arm's view arrangement.
    ///
    /// The three glass arms differ in exactly one thing — how many sampling shapes
    /// the band and the column are, and whether a container manages them — and
    /// everything else is held identical so a step in the strip cannot come from a
    /// frame that moved.
    private func buildArm(
        content: NSView,
        bandHeight: CGFloat,
        columnWidth: CGFloat,
        contentBounds: NSRect
    ) {
        // **The content view is UNFLIPPED: y = 0 is its bottom edge.** Every frame
        // below is written in those terms, and the band is therefore at the TOP,
        // which is `height - bandHeight`. The first version of this probe wrote
        // flipped frames and produced a column anchored to the wrong edge.
        let width = contentBounds.width
        let height = contentBounds.height

        // Under `.fullSizeContentView` (arm 3) the content view spans the whole
        // window and the band region is its own top `bandHeight` points. Under every
        // other arm the content view already sits below the band, so its full height
        // IS the region below the band. That difference is the arm, and it is the
        // reason `columnTop` is computed rather than assumed: in one case the column
        // stops short of the content view's top edge, in the other it reaches it.
        let contentSpansBand = arm.wantsFullSizeContentView
        let columnTop = contentSpansBand ? height - bandHeight : height

        // Where the column plane's top edge lands, in this content view's own
        // coordinates. Arm 2 overrides it, because its band plane lives inside the
        // content view and the two planes therefore meet lower than the content
        // view's top edge. See `planeBoundary`.
        recordedColumnTop = columnTop

        // The pane stand-in, to the right of the column and below the band. It fills
        // the region the column does not, so no bare backdrop is left between them:
        // a gap there reads to the strip as a step and is the probe's bug, not a
        // seam. The first run left exactly such a gap.
        let surface = SurfaceStandIn(frame: NSRect(
            x: columnWidth,
            y: 0,
            width: width - columnWidth,
            height: columnTop
        ))
        surface.autoresizingMask = [.width, .height]

        switch arm {
        case .shippedTwoPlanes:
            // TWO planes, in TWO hierarchies. The app's arrangement.
            //
            // The band's plane goes in the frame view, exactly as
            // `applyTitlebarGlass()` puts it: `contentView.superview`, added below
            // every sibling so the traffic lights, the title and the toolbar render
            // over it. `titlebarAppearsTransparent` is what stops AppKit painting
            // the system slab over the top of it.
            titlebarAppearsTransparent = true

            let bandGlass = makeGlass()
            if let frameView = contentView?.superview {
                bandGlass.frame = NSRect(
                    x: 0,
                    y: frameView.bounds.height - bandHeight,
                    width: frameView.bounds.width,
                    height: bandHeight
                )
                frameView.addSubview(bandGlass, positioned: .below, relativeTo: nil)
                heldViews.append(bandGlass)
            }

            // The column's plane goes inside `contentView`, below every sibling, as
            // `SidebarHost.applyResolvedChrome()` puts it. It reaches the content
            // view's top edge, which is where the band begins: the two planes MEET,
            // and the boundary between them is what the strip measures.
            let columnGlass = makeGlass()
            columnGlass.frame = NSRect(x: 0, y: 0, width: columnWidth, height: columnTop)
            content.addSubview(columnGlass, positioned: .below, relativeTo: nil)
            heldViews.append(columnGlass)

            content.addSubview(surface)
            addColumnContent(to: content, columnWidth: columnWidth, height: columnTop)

        case .containerMerged:
            // TWO planes in ONE hierarchy, inside one container.
            //
            // The band plane cannot stay in the frame view: a container merges its
            // own subviews, and a view has one superview. So this arm keeps both
            // planes in `contentView` and puts them in a container there. See
            // `ContainerPlacement` for why that is a finding rather than a shortcut,
            // and the README for what the app would have to change.
            //
            // The band plane sits at the content view's TOP `bandHeight` points,
            // which is the region directly under the titlebar band, and the column
            // plane runs from the bottom up to meet it. Adjacent, sharing one
            // container.
            placement = .singleHierarchy
            titlebarAppearsTransparent = true

            let container = NSGlassEffectContainerView(frame: contentBounds)
            // `spacing = 0` keeps the two shapes distinct while sharing one sampling
            // pass, which is the merge behaviour `glass-backdrop`'s finding 5
            // already measured on the capsule. A non-zero spacing would dissolve
            // them into one blob and measure a different question.
            container.spacing = 0
            container.autoresizingMask = [.width, .height]

            let bandGlass = makeGlass()
            bandGlass.frame = NSRect(
                x: 0, y: height - bandHeight, width: width, height: bandHeight
            )

            let columnGlass = makeGlass()
            columnGlass.frame = NSRect(
                x: 0, y: 0, width: columnWidth, height: height - bandHeight
            )
            // Both planes are inside the content view here, and `columnTop` already
            // equals `height - bandHeight` because this arm sets
            // `wantsFullSizeContentView`. Restated rather than left implicit: this
            // is the row the two planes abut at, and it is what the strip reads.
            recordedColumnTop = columnTop

            // The container's own `contentView` is the host holding both planes.
            // `NSGlassEffectContainerView` merges the glass views inside it; a host
            // view is what gives them a common parent to be merged in.
            let host = NSView(frame: contentBounds)
            host.autoresizingMask = [.width, .height]
            host.addSubview(bandGlass)
            host.addSubview(columnGlass)
            container.contentView = host
            heldViews += [container, host, bandGlass, columnGlass]

            content.addSubview(container, positioned: .below, relativeTo: nil)
            surface.frame = NSRect(
                x: columnWidth, y: 0, width: width - columnWidth, height: height - bandHeight
            )
            content.addSubview(surface)
            addColumnContent(to: content, columnWidth: columnWidth, height: height - bandHeight)

        case .fullSizeOnePlane:
            // ONE plane down the column, from the window's top edge to its bottom.
            //
            // **What "one plane" can and cannot mean here.** An `NSGlassEffectView`
            // is a rectangle, and the band-plus-column shape is an L. No single view
            // is an L. What this arm therefore builds is one plane covering the
            // COLUMN's full height including the band region — which is exactly the
            // strip's path — plus a separate plane for the band to the right of the
            // column, where the strip never reads.
            //
            // That is the honest version of the arm: down the strip there is one
            // sampling shape and no boundary, which is the claim being measured. It
            // is not a claim that the whole L is one view, and the README says so.
            titlebarAppearsTransparent = true

            let panel = makeGlass()
            panel.frame = NSRect(x: 0, y: 0, width: columnWidth, height: height)
            content.addSubview(panel, positioned: .below, relativeTo: nil)
            heldViews.append(panel)

            // The band to the right of the column still needs its glass, or the
            // window is not the app's. It is a separate shape by necessity and it is
            // NOT what the strip reads.
            let bandRemainder = makeGlass()
            bandRemainder.frame = NSRect(
                x: columnWidth,
                y: height - bandHeight,
                width: width - columnWidth,
                height: bandHeight
            )
            content.addSubview(bandRemainder, positioned: .above, relativeTo: panel)
            heldViews.append(bandRemainder)

            content.addSubview(surface)
            addColumnContent(to: content, columnWidth: columnWidth, height: columnTop)

        case .flatControl:
            // The same geometry, no glass. A flat fill at the column's frame, so a
            // reader can tell how much of any difference between the arms above is
            // the material and how much is the layout.
            //
            // The system slab is left ON (`titlebarAppearsTransparent` untouched),
            // because that is what flat chrome ships as: `applyTitlebarGlass()`'s
            // `.flat` case sets the flag false and lets AppKit paint the band.
            let columnFill = NSView(frame: NSRect(
                x: 0, y: 0, width: columnWidth, height: columnTop
            ))
            columnFill.wantsLayer = true
            columnFill.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 0.9).cgColor
            content.addSubview(columnFill)
            heldViews.append(columnFill)

            content.addSubview(surface)
            addColumnContent(to: content, columnWidth: columnWidth, height: columnTop)
        }
    }

    /// An `NSGlassEffectView` at the app's own settings.
    ///
    /// `.regular` and `cornerRadius = 0` and no tint. Reading those off the app
    /// source rather than inventing them is what makes arm 1 a control instead of
    /// a lookalike, and the two planes being identically configured is what makes
    /// any seam a sampling-boundary artifact rather than a style mismatch.
    ///
    /// **The untinted part is a condition, not a constant, and this comment said
    /// otherwise until 2026-08-12.** Both shipped planes also assign
    /// `tintColor = SurfaceFill.colour(fillMaterial, in: set)`
    /// (`WorkspaceWindowController.updateTitlebarGlassTint()`,
    /// `SurfaceHosts.updateGlassTint()`), so "these three and nothing else" was
    /// wrong. It resolves to no tint today because `fillMaterial` is nil on both,
    /// fed from two *independent* knobs: `chrome.surfaces.titlebar` and
    /// `chrome.surfaces.sidebar`, each defaulting nil and neither dialled.
    ///
    /// The consequence for anyone re-reading the numbers: dialling one knob and
    /// not the other lays a style mismatch on top of the sampling seam, and this
    /// probe would then be measuring the wrong arrangement. An arm carrying the
    /// real tints is the honest extension if that day comes.
    private func makeGlass() -> NSGlassEffectView {
        let glass = NSGlassEffectView(frame: .zero)
        glass.style = .regular
        glass.cornerRadius = 0
        glass.wantsLayer = true
        return glass
    }

    private func addColumnContent(to content: NSView, columnWidth: CGFloat, height: CGFloat) {
        let column = ColumnContent(frame: NSRect(x: 0, y: 0, width: columnWidth, height: height))
        content.addSubview(column)
        heldViews.append(column)
    }

    /// Asks AppKit whether the traffic lights survived this arm, and whether they
    /// are still hit-testable.
    ///
    /// **Measured, with the limit stated.** Visibility and frame are read off the
    /// real buttons. Hit-testability is asked as `frameView.hitTest` at each
    /// button's own centre, which answers "does a click at this point reach the
    /// button rather than something laid over it" — the failure mode a glass plane
    /// in the frame view could cause. What it does NOT do is synthesise a click and
    /// watch the window close: that needs a real CGEvent and a key window, and this
    /// probe takes no focus by construction. Drag is likewise not exercised.
    private func recordTrafficLights() {
        let buttons: [(String, NSWindow.ButtonType)] = [
            ("close", .closeButton),
            ("min", .miniaturizeButton),
            ("zoom", .zoomButton),
        ]
        var parts: [String] = []
        for (label, buttonType) in buttons {
            guard let button = standardWindowButton(buttonType) else {
                parts.append("\(label)=ABSENT")
                continue
            }
            let visible = !button.isHidden && button.alphaValue > 0
            // Hit test from the frame view, which is the coordinate space the
            // titlebar's glass is added into and therefore the space where an
            // interception would happen.
            var hit = "?"
            if let frameView = contentView?.superview {
                let centre = button.convert(
                    NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: frameView
                )
                let target = frameView.hitTest(centre)
                // The button itself or one of its descendants counts as reached.
                var reached = false
                var walk: NSView? = target
                while let node = walk {
                    if node === button { reached = true; break }
                    walk = node.superview
                }
                hit = reached ? "hit" : "BLOCKED(\(target.map { String(describing: type(of: $0)) } ?? "nil"))"
            }
            parts.append("\(label)=\(visible ? "visible" : "HIDDEN"),\(hit)")
        }
        // `isMovableByWindowBackground` is reported rather than exercised: dragging
        // needs a real event stream this probe cannot generate without focus. The
        // titlebar band's own drag is AppKit's and is not routed through any view
        // this probe adds, which is what the report says and what a later reader
        // should confirm by hand.
        parts.append("movableByBackground=\(isMovableByWindowBackground)")
        trafficLightReport = parts.joined(separator: " ")
    }
}

// MARK: - capture

/// Runs `screencapture` and reports whether it wrote the file.
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

/// Captures one window as the screen composite (`-R`), with the window's own
/// backing store (`-l`) beside it as a cross-check.
///
/// **`-R` is the measured file here, which is the opposite of `glass-backdrop`'s
/// choice, and the reason is the titlebar.** That probe measures borderless windows
/// whose glass composites into their own backing store, so `-l` sees the adaptation
/// and avoids `-R`'s display tone curve. These windows are `.titled` with a real
/// toolbar: the band is chrome the *window server* composites, and the frame-view
/// glass of arm 1 sits under material AppKit paints outside the content view's
/// backing store. An `-l` file of arm 1 does not contain the band as an owner sees
/// it, so it cannot answer whether the band steps against the column.
///
/// The cost is the one `glass-backdrop` documents: `-R` carries the display's
/// brightness and EDR response at capture time, so absolute values are not
/// comparable between runs or machines. **This probe's verdict is built only on
/// within-run comparisons** — every arm is captured in one run against one backdrop,
/// and the grading threshold is re-measured from that run's own noise floor rather
/// than frozen as a constant. It comes from a boundary-free region and never from an
/// arm under test. That is what makes an `-R`-based verdict safe here.
func capture(window: NSWindow, to path: String) -> Bool {
    guard let main = NSScreen.screens.first else { return false }

    // `screencapture -R` takes global display coordinates: origin at the top-left of
    // the main display, y growing downward, where AppKit hands out bottom-left
    // origins. Flipping against the main screen's `frame` (not `visibleFrame`, which
    // excludes the menu bar and would shift every capture down by its height) is the
    // conversion. Each edge is rounded and the size derived from the rounded edges,
    // so the files are consistent with each other.
    let frame = window.frame
    let left = frame.minX.rounded()
    let right = frame.maxX.rounded()
    let top = (main.frame.maxY - frame.maxY).rounded()
    let bottom = (main.frame.maxY - frame.minY).rounded()
    let rect = "\(Int(left)),\(Int(top)),\(Int(right - left)),\(Int(bottom - top))"

    guard runScreencapture(["-R", rect], to: path) else { return false }

    // Best-effort cross-check: losing it must not fail a run whose measured file was
    // written.
    let backingPath = path.replacingOccurrences(of: ".png", with: "-backing.png")
    _ = runScreencapture(["-l", String(window.windowNumber)], to: backingPath)
    return true
}

/// Reads one pixel out of a capture, by fraction of the image.
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

/// Rec. 709 relative luminance, the same weighting the rest of the Diagnostics
/// grading uses, on 0-255.
func luminance(_ c: (Int, Int, Int)) -> Double {
    0.2126 * Double(c.0) + 0.7152 * Double(c.1) + 0.0722 * Double(c.2)
}

/// True when a capture shows the glass has actually sampled its backdrop.
///
/// The controlled backdrop is what makes this answerable without a tolerance
/// argument: the probe window sits in the white half, and the *rulers* behind the
/// glass give the column structure to carry. Glass that has not sampled yet is flat
/// to within rounding; glass that has carries a difference between a ruler column and
/// the gap beside it, and those are tens of units apart.
///
/// This is the `recordSampled` check `glass-backdrop` introduced after a fixed
/// `settle()` published a wrong number: a larger glass view needs more time, and a
/// probe that hardcodes one budget reports "the column reads dark" when what it
/// measured was an unfinished frame.
func sampledVertically(_ path: String, x: Double, top: Double, bottom: Double) -> Bool {
    guard let a = samplePixel(path, fx: x, fy: top),
          let b = samplePixel(path, fx: x, fy: bottom) else { return false }
    // Either the two ends differ (the plane is carrying the backdrop's structure),
    // or the plane is not flat black/white (it composited something at all).
    let delta = abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
    let notDegenerate = luminance(a) > 4 && luminance(a) < 251
    return delta > 6 || notDegenerate
}

// MARK: - the backdrop assertion

/// What a backdrop check found, so a failure can name the arm and the numbers
/// rather than just failing.
struct BackdropCheck {
    let whiteLuminance: Double
    let blackLuminance: Double
    let passed: Bool

    var description: String {
        String(
            format: "white-half=%.1f black-half=%.1f",
            whiteLuminance, blackLuminance
        )
    }
}

/// Captures a strip of screen OUTSIDE the probe window and asserts it is the
/// controlled backdrop: one pixel in the white half, one in the black half.
///
/// **This is what makes the backdrop displacement impossible to reintroduce
/// silently, and it is deliberately independent of the level fix above.** The
/// levels make displacement not happen; this assertion makes a run where it
/// happened anyway *fail loudly*, naming the arm. Two mechanisms because the
/// failure being guarded is precisely the kind that survived a README paragraph
/// describing it: glass samples whatever is behind it at capture time, and a
/// capture over the wrong thing still looks like glass.
///
/// The sampled points are chosen to be unmistakable rather than approximately
/// right. They sit **outside the probe window's frame** — the window is 900 pt
/// wide and centred, so a point near the screen's left edge is clear of it — and
/// each is deep inside its own half, well away from the white/black boundary
/// where a rounding error could put a sample on the wrong side.
///
/// Pure white through `-R` does not read 255: the display's tone response crushes
/// it, and `glass-backdrop` records the same effect measuring 21% on its own
/// white half. So the thresholds are wide and asymmetric — the white half must be
/// *bright relative to the black half* and the black half genuinely dark — which
/// is a test the operator's terminal (a mid-grey field of text at luminance ~70
/// in both sample positions) fails decisively while any real backdrop passes.
func assertBackdrop(screen: NSScreen, to path: String) -> BackdropCheck? {
    let frame = screen.frame
    // A tall thin strip down the screen's left edge, crossing both halves and
    // clear of the 900 pt probe window centred on the screen.
    let stripWidth: CGFloat = 40
    let left = frame.minX.rounded()
    let top = (frame.maxY - frame.maxY).rounded()
    let height = frame.height.rounded()
    let rect = "\(Int(left)),\(Int(top)),\(Int(stripWidth)),\(Int(height))"
    guard runScreencapture(["-R", rect], to: path) else { return nil }

    // The backdrop view is flipped and fills white first, so the white half is the
    // TOP of the screen and the black half the bottom. Sampled around 0.25 and 0.75
    // of the strip's height, each the middle of its own half.
    //
    // **Averaged over several rows rather than read as one pixel**, because the
    // backdrop now carries horizontal rulers every 19 pt (see `BackdropView.draw`)
    // and a single sample can land on a mid-grey line. One ruler hit would drag a
    // white-half read down toward 128 and could fail a run whose backdrop was
    // perfectly correct. The rulers are 1 pt in 19, so a mean over a spread of rows
    // is dominated by the half's own colour and the check keeps a wide margin
    // either side.
    func meanLuminance(around fy: Double) -> Double? {
        let offsets = [-0.03, -0.015, 0.0, 0.015, 0.03]
        var total = 0.0
        for offset in offsets {
            guard let pixel = samplePixel(path, fx: 0.5, fy: fy + offset) else { return nil }
            total += luminance(pixel)
        }
        return total / Double(offsets.count)
    }

    guard let whiteLuminance = meanLuminance(around: 0.25),
          let blackLuminance = meanLuminance(around: 0.75) else { return nil }
    // The white half must be bright, the black half dark, and the two must be far
    // apart. The desktop failure reads roughly equal mid-greys in both positions
    // and fails the separation test even if one half sneaks past a bound.
    let passed = whiteLuminance > 140 && blackLuminance < 60
        && (whiteLuminance - blackLuminance) > 100
    return BackdropCheck(
        whiteLuminance: whiteLuminance,
        blackLuminance: blackLuminance,
        passed: passed
    )
}

/// Runs the run loop for a fixed interval without blocking the window server.
///
/// `Thread.sleep` would stop the run loop, and a glass view that has not had a
/// display pass captures as an unsampled slab. The window has to be composited
/// before it can be photographed.
func settle(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

// MARK: - the strip measurement

/// One arm's vertical strip: luminance sampled down a column of the capture that
/// crosses the titlebar/column boundary.
struct Strip {
    let arm: Arm
    /// `(y-fraction, luminance)` from the top of the window downward.
    let samples: [(Double, Double)]
    /// The largest single step between adjacent samples, and where it happened.
    let maxStep: Double
    let maxStepAt: Double
    /// The step measured across the boundary specifically, which is the number the
    /// verdict rests on: a seam is a step *there*, and a step anywhere else is
    /// something the arm is doing for another reason.
    let boundaryStep: Double
}

/// Samples a strip and finds its steps.
///
/// **The sample band is chosen to exclude everything that is not glass**, and each
/// exclusion is load-bearing:
///
/// - **Above `topSkip`**: the traffic lights, the title and the toolbar are drawn
///   over the band. A strip through them measures AppKit's controls, not the plane
///   beneath them. The strip's x is also well left of the title, and clear of the
///   buttons, so this is belt and braces.
/// - **Below `bottomSkip`**: nothing, but the band is kept away from the window's
///   bottom edge where a shadow or rounding could enter.
/// - **The strip's x**: inside the column and left of every glyph `ColumnContent`
///   draws. Ink inside the strip would read as a step that has nothing to do with the
///   seam.
func measureStrip(
    _ path: String,
    arm: Arm,
    x: Double,
    boundary: Double,
    topSkip: Double,
    bottomSkip: Double,
    steps: Int = 64
) -> Strip? {
    var samples: [(Double, Double)] = []
    for i in 0 ... steps {
        let fy = topSkip + (bottomSkip - topSkip) * Double(i) / Double(steps)
        guard let c = samplePixel(path, fx: x, fy: fy) else { return nil }
        samples.append((fy, luminance(c)))
    }

    var maxStep = 0.0
    var maxStepAt = 0.0
    for i in 1 ..< samples.count {
        let step = abs(samples[i].1 - samples[i - 1].1)
        if step > maxStep {
            maxStep = step
            maxStepAt = samples[i].0
        }
    }

    // The boundary step: the difference between the mean of the samples just above
    // the boundary and the mean of those just below it. A mean either side rather
    // than two single pixels, because a one-pixel read at the boundary can land on
    // the transition row itself and report half the step.
    let window = 0.04
    let above = samples.filter { $0.0 < boundary && $0.0 > boundary - window }.map(\.1)
    let below = samples.filter { $0.0 > boundary && $0.0 < boundary + window }.map(\.1)
    let boundaryStep: Double
    if above.isEmpty || below.isEmpty {
        boundaryStep = 0
    } else {
        boundaryStep = abs(
            above.reduce(0, +) / Double(above.count) - below.reduce(0, +) / Double(below.count)
        )
    }

    return Strip(
        arm: arm,
        samples: samples,
        maxStep: maxStep,
        maxStepAt: maxStepAt,
        boundaryStep: boundaryStep
    )
}

// MARK: - the noise floor

/// What "no step" looks like in this capture pipeline, measured rather than
/// assumed.
///
/// **This replaces a threshold that arm 1 defined and was then graded against.**
/// The old rule was `max(arm1 * 0.10, 2.0)`, printed as "10% of arm 1's measured
/// seam", and it is circular: arm 1 sets the bar it is measured by, so it reads
/// MERGED whatever it measures. The baseline run of the broken probe shows the
/// failure exactly — arm 1 measured 1.26 and was graded `MERGED (defines
/// threshold)` while arms 2 and 3, measuring 6.67 and 6.00, were graded SEAM.
/// The control passed and the candidates failed, which is the grading inverted.
///
/// The honest question is what magnitude of `boundaryStep` this pipeline produces
/// when there is **no boundary at all**. That is measurable: take the same
/// `boundaryStep` computation — mean of a band above a row, minus mean of a band
/// below it — and apply it at rows *inside one uniform region*, where both bands
/// are the same plane with nothing between them. Whatever it reports there is
/// sensor noise, dithering, the display's tone response and the sampling grid,
/// and none of it is a seam.
///
/// Measured across several positions rather than one, because a single position
/// could land somewhere unrepresentative. The floor reported is the **maximum**
/// across positions: the threshold has to clear the worst noise the pipeline
/// produces, not the average, or an arm could fail on a position that happens to
/// be noisy.
struct NoiseFloor {
    /// Every position's measured pseudo-step, for the report.
    let samples: [(Double, Double)]
    /// The largest, which is what the threshold is built on.
    let maxSpread: Double
    /// The mean, for the README's derivation.
    let meanSpread: Double

    var description: String {
        samples
            .map { String(format: "y=%.2f:%.2f", $0.0, $0.1) }
            .joined(separator: "  ")
    }
}

/// Measures the noise floor down a capture's uniform region.
///
/// The positions are all **below the plane boundary**, inside the column's own
/// glass, where every arm has one continuous plane and no arrangement under test
/// puts an edge. Sampling above the boundary would cross into the band, which is
/// the thing being measured and cannot also be the ruler.
///
/// The band half-width matches `measureStrip`'s `window` exactly, because a
/// threshold derived from a different averaging width than the measurement it
/// grades is not a threshold for that measurement.
///
/// **This pipeline's measured floor is genuinely 0.00, and that is a result rather
/// than a broken measurement.** `NSGlassEffectView` over the controlled backdrop
/// is a heavy blur: it dissolves even the backdrop's 1 pt rulers, so the column
/// reads one identical 8-bit value at every row (141.0 across all 56 samples below
/// the boundary, in every run measured). There is no sensor noise to find because
/// `screencapture` is a lossless read of a composited buffer, not a photograph.
///
/// So the floor is reported as measured, and the *threshold* adds the pipeline's
/// resolution limit to it rather than multiplying zero by two. See `main`.
func measureNoiseFloor(
    _ path: String,
    x: Double,
    positions: [Double],
    window: Double = 0.04,
    steps: Int = 64,
    topSkip: Double = 0.02,
    bottomSkip: Double = 0.90
) -> NoiseFloor? {
    // The same sample grid the strip uses, so the noise measured is the noise the
    // measurement sees rather than the noise of a finer or coarser read.
    var samples: [(Double, Double)] = []
    for i in 0 ... steps {
        let fy = topSkip + (bottomSkip - topSkip) * Double(i) / Double(steps)
        guard let c = samplePixel(path, fx: x, fy: fy) else { return nil }
        samples.append((fy, luminance(c)))
    }

    var results: [(Double, Double)] = []
    for position in positions {
        let above = samples.filter { $0.0 < position && $0.0 > position - window }.map(\.1)
        let below = samples.filter { $0.0 > position && $0.0 < position + window }.map(\.1)
        guard !above.isEmpty, !below.isEmpty else { continue }
        let spread = abs(
            above.reduce(0, +) / Double(above.count) - below.reduce(0, +) / Double(below.count)
        )
        results.append((position, spread))
    }
    guard !results.isEmpty else { return nil }
    let spreads = results.map(\.1)
    return NoiseFloor(
        samples: results,
        maxSpread: spreads.max() ?? 0,
        meanSpread: spreads.reduce(0, +) / Double(spreads.count)
    )
}

// MARK: - main

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSTemporaryDirectory() + "baia-titlebar-merge"

try? FileManager.default.createDirectory(
    atPath: outputDirectory, withIntermediateDirectories: true
)

let app = NSApplication.shared
// `.accessory`, never `.regular`. An accessory app has no Dock tile, no menu bar,
// and cannot become active, so the probe's windows are composited without the
// owner's focus ever moving. Every window below is `orderFrontRegardless()`, never
// `makeKeyAndOrderFront`.
app.setActivationPolicy(.accessory)

guard let screen = NSScreen.main else {
    FileHandle.standardError.write("no screen\n".data(using: .utf8)!)
    exit(1)
}

let screenFrame = screen.frame
let backdrop = BackdropWindow.make(covering: screenFrame)
backdrop.orderFrontRegardless()

// The probe window sits ENTIRELY WITHIN THE WHITE HALF of the backdrop, which is the
// opposite of `glass-backdrop`'s straddle and is what this question needs. The strip
// runs down the window vertically; if the backdrop's own seam crossed it, every arm
// would show a large step at that row and the glass's contribution would be buried
// under it. One constant backdrop luminance behind the whole strip means a step in
// the strip is the glass.
//
// White rather than black because a seam between two glass planes is a difference in
// how much backdrop each admits, and there is more to admit over white.
let probeWidth: CGFloat = 900
let probeHeight: CGFloat = 380

// **Positioned against `visibleFrame`, not `frame`, and that is not tidiness.**
// `NSWindow(contentRect:)` takes a CONTENT rect and grows the frame by the chrome
// this window asks for — measured here at 33 pt for a titled window before the
// toolbar, so a window placed by its content rect ends up 33 pt taller than the
// arithmetic that placed it. Centred in the screen's upper half that pushed the
// frame's top edge under the menu bar, and `screencapture -R` refuses a rect that
// overlaps it: the first run of this probe wrote no captures at all and reported
// "could not create image from rect" four times. Clamping the top edge into
// `visibleFrame` is what fixes it, and it has to account for the chrome the window
// has not been given yet.
let chromeAllowance: CGFloat = 60
let visible = screen.visibleFrame
// The white half is the TOP half in screen terms (the backdrop view is flipped, so
// its first fill is the top). The window is placed high in that half but clamped so
// its whole frame, chrome included, stays inside `visibleFrame`.
let desiredTop = min(
    screenFrame.midY + (screenFrame.height / 4) + probeHeight / 2,
    visible.maxY - chromeAllowance
)
let probeFrame = NSRect(
    x: screenFrame.midX - probeWidth / 2,
    y: desiredTop - probeHeight,
    width: probeWidth,
    height: probeHeight
)

settle(0.6)

var failures = 0
var strips: [Arm: Strip] = [:]
var reports: [String] = []
/// One line per arm recording that its capture had the controlled backdrop behind
/// it, with the measured luminances. Printed in the report so a reader can see the
/// assertion ran rather than assuming it did.
var backdropChecks: [String] = []
/// The pipeline's own noise floor, measured off the flat control's capture.
var noiseFloor: NoiseFloor?

/// Captures a window, re-settling and re-capturing until the file shows the glass has
/// sampled. Each retry waits longer than the last: the first failure is usually a
/// frame away, and a run that needs the last one is telling us something a constant
/// would have hidden.
func recordSampled(_ window: NSWindow, _ name: String, attempts: Int = 6, check: (String) -> Bool) -> String? {
    // **Ordered backdrop-first, then the probe window on top, and both are
    // re-asserted before every capture.** The ordering here is belt to the levels'
    // braces: the backdrop is `.floating` and the probe window one step above it,
    // so the stack is correct by construction, and these calls only make each
    // window frontmost *within its own level*. The previous version relied on
    // ordering alone across levels that put the backdrop underneath every ordinary
    // window, which cannot work — see `BackdropWindow.make`.
    backdrop.orderFrontRegardless()
    window.orderFrontRegardless()
    let path = outputDirectory + "/" + name + ".png"
    for attempt in 1 ... attempts {
        // Re-asserted inside the retry loop too: a retry re-orders the probe window
        // and would otherwise re-open the same hole on the attempt that succeeds.
        backdrop.orderFrontRegardless()
        window.orderFrontRegardless()
        settle(0.8 * Double(attempt))
        guard capture(window: window, to: path) else {
            print("CAPTURE FAILED \(name)")
            failures += 1
            return nil
        }
        if check(path) {
            print("captured \(name).png\(attempt > 1 ? " (settled on attempt \(attempt))" : "")")
            return path
        }
    }
    print("CAPTURE UNSAMPLED \(name) — glass did not sample its backdrop in \(attempts) attempts")
    failures += 1
    return nil
}

// Where the strip runs, and where the boundary is.
//
// x = 0.06 of the window width is inside the 260 pt column (which ends at 0.289 of
// 900) and well left of `ColumnContent`'s glyphs at x = 110 pt (0.122). It is also
// left of the traffic lights' x range in the band above, so the strip passes through
// band glass rather than through a button.
let stripX = 0.06

for arm in Arm.allCases {
    let window = ProbeWindow(arm: arm, contentRect: probeFrame)

    // The band height, for the report only. The strip's boundary is NOT derived
    // from it — see `ProbeWindow.planeBoundary` for why the obvious formula points
    // the strip at the wrong row for two of the four arms.
    let bandHeight = window.frame.height - window.contentLayoutRect.height
    let boundary = window.planeBoundary

    let name = "arm-" + arm.rawValue

    // **The backdrop is asserted for THIS arm, immediately before its capture, and
    // a failure ends the run naming the arm.** Per-arm rather than once at startup,
    // because displacement is not a startup condition: it happens when this arm's
    // titled window is ordered front, and an arm that lost the backdrop is the unit
    // of invalid data. Every absolute number from an arm captured over the wrong
    // thing is meaningless, so the run must not publish one.
    backdrop.orderFrontRegardless()
    window.orderFrontRegardless()
    settle(0.4)
    let backdropPath = outputDirectory + "/backdrop-check-" + arm.rawValue + ".png"
    guard let check = assertBackdrop(screen: screen, to: backdropPath) else {
        print("BACKDROP CHECK FAILED \(arm.rawValue) — could not capture the backdrop strip")
        failures += 1
        window.orderOut(nil)
        continue
    }
    if !check.passed {
        print("BACKDROP DISPLACED \(arm.rawValue) — \(check.description)")
        print("  the controlled white/black field is not behind this arm's window, so")
        print("  anything the glass sampled is whatever else was on screen. Refusing to")
        print("  publish a number for it. The strip is at \(backdropPath).")
        failures += 1
        window.orderOut(nil)
        continue
    }
    backdropChecks.append("\(arm.rawValue)  \(check.description)  OK")

    let captured = recordSampled(window, name) { path in
        // Sampled check for the glass arms; the flat control has nothing to sample
        // and is accepted on the first capture.
        arm.usesGlass ? sampledVertically(path, x: stripX, top: boundary + 0.05, bottom: 0.9) : true
    }

    if let captured,
       let strip = measureStrip(
           captured,
           arm: arm,
           x: stripX,
           boundary: boundary,
           // Below the traffic lights and the title, which sit in the band's own
           // vertical middle. The strip still crosses the boundary; it just does not
           // start at the window's very top edge where a rounded corner lives.
           topSkip: 0.02,
           bottomSkip: 0.90
       )
    {
        strips[arm] = strip
    } else if captured != nil {
        print("STRIP FAILED \(name)")
        failures += 1
    }

    // The noise floor is measured off **arm 1's** capture, and the choice matters.
    //
    // It has to be a glass arm, because the number being graded is a step read
    // through glass and the flat control's fill is a different, quieter surface —
    // a floor measured there would be too low and would fail arms for noise the
    // pipeline genuinely produces. Arm 1 is chosen among the glass arms because it
    // is the control the verdict turns on: measuring the floor in the same capture
    // whose boundary step is under test removes any argument that the two numbers
    // came from differently-conditioned frames.
    //
    // The positions are all well below the plane boundary, inside the column's one
    // continuous glass plane, where no arm puts an edge. See `measureNoiseFloor`.
    if arm == .shippedTwoPlanes, let captured {
        noiseFloor = measureNoiseFloor(
            captured,
            x: stripX,
            positions: [0.40, 0.50, 0.60, 0.70, 0.80]
        )
    }

    reports.append("\(arm.rawValue)  bandHeight=\(Int(bandHeight)) boundary=\(String(format: "%.4f", boundary))")
    reports.append("  traffic-lights: \(window.trafficLightReport)")
    if let placement = window.placement {
        reports.append("  container: \(placement.note)")
    }

    window.orderOut(nil)
}

// MARK: - the report

print()
print("=== the backdrop assertion: what was actually behind each arm ===")
print("Sampled from a strip down the screen's left edge, OUTSIDE the probe window,")
print("one point in the backdrop's white half and one in its black half. An arm")
print("whose glass sampled anything else does not get a published number.")
for line in backdropChecks { print(line) }
if backdropChecks.count < Arm.allCases.count {
    print("\(Arm.allCases.count - backdropChecks.count) arm(s) did NOT pass the backdrop assertion.")
}

print()
print("=== arrangement and traffic lights ===")
for line in reports { print(line) }

print()
print("=== the strip: luminance down x=\(stripX) of the window, crossing the boundary ===")
print("boundaryStep is the seam number: the mean luminance just above the")
print("titlebar/column boundary minus the mean just below it.")
print()
/// Pads a column in Swift rather than through `String(format:)`'s `%s`.
///
/// `%s` takes a C string, and `(value as NSString).utf8String` hands it a pointer
/// into a temporary that is dead by the time the formatter reads it. The first run
/// of this probe crashed in `_platform_strlen` on exactly that, after printing the
/// arrangement table and before printing a single number.
func pad(_ value: String, _ width: Int) -> String {
    value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
}

func padLeft(_ value: String, _ width: Int) -> String {
    value.count >= width ? value : String(repeating: " ", count: width - value.count) + value
}

print(pad("arm", 26) + padLeft("boundaryStep", 13) + padLeft("maxStep", 13) + padLeft("maxStepAt", 13))
for arm in Arm.allCases {
    guard let strip = strips[arm] else {
        print(pad(arm.rawValue, 26) + padLeft("NO DATA", 13))
        continue
    }
    print(
        pad(arm.rawValue, 26)
            + padLeft(String(format: "%.2f", strip.boundaryStep), 13)
            + padLeft(String(format: "%.2f", strip.maxStep), 13)
            + padLeft(String(format: "%.4f", strip.maxStepAt), 13)
    )
}

// The grading threshold, derived from the pipeline's own noise floor.
//
// **No arm can move this number, which is the whole point.** The previous rule was
// `max(arm1 * 0.10, 2.0)` and it was circular: arm 1 defined the threshold it was
// then graded against, so its line always read MERGED whatever it measured. The
// baseline run of the broken probe is the demonstration — arm 1 at 1.26 graded
// `MERGED (defines threshold)` while arms 2 and 3 at 6.67 and 6.00 graded SEAM,
// the grading exactly inverted.
//
// The replacement asks what this capture pipeline reports as a `boundaryStep` when
// there is **no boundary**: the same computation applied at rows inside one
// continuous glass plane, at five positions down the column. That is sensor noise,
// dithering, the display's tone curve and the sampling grid, and it is the honest
// definition of "no step here".
//
// **The threshold is the measured floor plus one 8-bit level, doubled.**
//
// The measured floor on this pipeline is 0.00: the glass blur is wide enough to
// dissolve the backdrop's rulers, and `screencapture` reads a composited buffer
// losslessly rather than photographing a screen, so there is no sensor noise to
// find. Multiplying that by two would give 0.00 and grade on exact equality, which
// would fail an arm for a single least-significant-bit difference — a distinction
// no reader can see and no reasonable probe should make.
//
// So the floor is added to the pipeline's *resolution* limit before doubling. One
// 8-bit level is 1.0 luminance unit on the 0-255 scale these numbers live on, and
// it is the smallest difference the capture can represent at all: a step below it
// does not exist as a measurement. `(floor + 1.0) * 2` therefore says a step must
// be at least twice the pipeline's combined noise-and-resolution limit before it
// counts as a boundary. On this machine that is 2.00.
//
// **No arm can move this number.** It comes from a region with no boundary in it
// plus a property of 8-bit colour, and the arms under test contribute nothing to
// either. That is the whole difference from the rule it replaces.
//
// It is still re-measured every run rather than frozen as a constant, which `-R`
// requires: the tone response varies with screen brightness, so a floor measured
// last week does not bound today's capture.
let controlStep = strips[.flatControl]?.boundaryStep ?? 0
let floor = noiseFloor
/// One 8-bit level on the 0-255 scale: the smallest difference a capture can
/// represent, and therefore the smallest that can honestly be called a step.
let quantisationLimit = 1.0
let threshold = ((floor?.maxSpread ?? 0) + quantisationLimit) * 2.0

print()
print("=== the noise floor: what 'no step' measures in this pipeline ===")
if let floor {
    print("The same boundaryStep computation, applied at five rows INSIDE arm 1's")
    print("continuous column glass where no arm puts an edge:")
    print("  " + floor.description)
    print(String(
        format: "  max %.2f, mean %.2f", floor.maxSpread, floor.meanSpread
    ))
    if floor.maxSpread == 0 {
        print("  A measured 0.00 is this pipeline's real answer, not a failed read: the")
        print("  glass blur dissolves the backdrop's rulers and screencapture reads a")
        print("  composited buffer losslessly, so the column is one value at every row.")
    }
    print()
    print(String(
        format: "grading threshold: %.2f  ((noise floor %.2f + one 8-bit level %.2f) x 2)",
        threshold, floor.maxSpread, quantisationLimit
    ))
    print("No arm contributes to this number: it is a boundary-free region plus a")
    print("property of 8-bit colour. Arm 1 is graded against it like any other arm.")
} else {
    print("NOISE FLOOR UNMEASURED — no threshold can be derived, so no arm is graded.")
    failures += 1
}
print(String(
    format: "flat control's boundary step, for scale: %.2f  (a two-tone layout, not an error bar)",
    controlStep
))
print()
if floor != nil {
    // **Every arm is graded, including arm 1.** It no longer defines the threshold,
    // so it is a result like any other and is presented as one. If a correctly
    // backdropped arm 1 reads below the threshold, that is a finding about the
    // merge question rather than a probe failure — see the README.
    for arm in Arm.allCases where arm != .flatControl {
        guard let strip = strips[arm] else { continue }
        let verdict = strip.boundaryStep <= threshold ? "MERGED" : "SEAM"
        print(
            pad(arm.rawValue, 26)
                + padLeft(String(format: "%.2f", strip.boundaryStep), 9)
                + "  " + verdict
        )
    }
}

// The full strip profiles, so a reader can see the shape rather than trusting one
// number. A seam is a step; a merged panel is a ramp or a flat.
print()
print("=== strip profiles (y-fraction, luminance) ===")
for arm in Arm.allCases {
    guard let strip = strips[arm] else { continue }
    print(arm.rawValue + ":")
    var line = "  "
    for (i, sample) in strip.samples.enumerated() {
        line += String(format: "%.3f:%5.1f  ", sample.0, sample.1)
        if (i + 1) % 6 == 0 {
            print(line)
            line = "  "
        }
    }
    if line.trimmingCharacters(in: .whitespaces).count > 0 { print(line) }
}

print()
print("captures: \(outputDirectory)")
if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
exit(0)
