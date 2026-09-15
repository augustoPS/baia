import AppKit
import BaiaSettings
import PaneChrome
import WorkspaceLayout

/// Everything a pane draws around its terminal surface, as one object with
/// one set of inputs.
///
/// The glass plane and its wash below the surface; the capsule, the
/// inactive-window scrim, the attention frame and the focus lift above it.
/// `TerminalPaneController` owned all six views and the rules that drive them
/// until 2026-09-04, when the Settings preview needed the same chrome for the
/// same settings. The audit's S11 had found the old preview never assigned
/// `resolvedChrome`, had no glass plane and no wash, and painted its sidebar as
/// a colour: a second rendering of the pane, written beside the first, had
/// drifted from it. Moving the rendering here is what makes "the preview shows
/// what a pane shows" a property of the code rather than a claim about it.
///
/// Two kinds of input. ``apply(_:)`` takes the ``PaneAppearance`` the
/// configuration centre resolves for a pane, so the settings reach the preview
/// through the derivation the panes use. ``isPaneFocused``, ``isWindowActive``,
/// ``attention`` and ``bottomCorners`` are the pane's own state, which a real
/// pane reads off its window and its trackers and the preview sets from a
/// picker.
///
/// Every view here refuses first responder and hit testing, per
/// ``PaneOverlayView``'s header: anything in a pane that takes focus disables
/// every ghostty binding in it.
@MainActor
final class PaneChromeStack {
    /// The capsule in the pane's top-right (design v6). Exposed because the pane
    /// wires its segment clicks and card presentation to it; the preview only
    /// hands it segments.
    let clusterView = PaneClusterView(frame: .zero)

    /// Covers the pane whole, which is the point: a background window recedes as
    /// one object, and a scrim that stopped short of any part of a pane would
    /// leave every pane in it wearing a bright band.
    private let scrim = PaneScrimView(frame: .zero)

    private let edgeFrame = PaneEdgeFrameView(frame: .zero)

    /// The focused pane's ring, inner highlight and shadow under glass. Covers
    /// the pane whole, the same span as ``scrim`` and ``edgeFrame``: the lift
    /// marks the whole pane as the one holding focus, not just the chrome that
    /// names it.
    private let liftView = PaneLiftView(frame: .zero)

    /// The pane's glass plane and its wash, glass path only. Created and torn
    /// down with ``resolvedChrome``: absence is part of what flat's
    /// byte-identical claim means, and a hidden NSGlassEffectView still costs a
    /// compositing pass.
    private var glassPlane: PaneGlassPlaneView?
    private var glassWash: PaneGlassWashView?

    /// The view the stack was installed into, and the surface it wraps. Weak,
    /// because the host owns this object.
    private weak var host: NSView?
    private weak var surface: NSView?

    /// The capsule's top and trailing pins while it is installed, held so the
    /// `cornerInset` dial can move them without a reinstall.
    private var clusterEdgeConstraints: [NSLayoutConstraint] = []

    // MARK: - Appearance

    /// The palette everything in this pane derives from. One property rather than
    /// one per view, so a theme change cannot land on the capsule and miss the
    /// scrim.
    private(set) var theme: PaneTheme = .darkPastel {
        didSet {
            guard theme != oldValue else { return }
            applyPresentation()
        }
    }

    private(set) var attentionStyle: AttentionStyle = .loud {
        didSet {
            guard attentionStyle != oldValue else { return }
            // The frame is gated on `loud` too, so a live config edit that
            // quietens attention has to take the frame down with the fill.
            applyPresentation()
        }
    }

    /// Which derivation the attention signal is drawn from, and what to do when it
    /// lands on the focus colour.
    ///
    /// Both reach the capsule and the pane frame, which is why they are stored
    /// here: the frame around the whole pane is drawn in the same colour, and a
    /// setting that moved one of the two would leave half of the loud treatment
    /// behind.
    private(set) var attentionAccent: AttentionAccent = .alert {
        didSet {
            guard attentionAccent != oldValue else { return }
            clusterView.attentionAccent = attentionAccent
            applyPresentation()
        }
    }

    private(set) var alertBehavior: AlertBehavior = .stock {
        didSet {
            guard alertBehavior != oldValue else { return }
            clusterView.alertBehavior = alertBehavior
            applyPresentation()
        }
    }

    /// What the capsule and the lift should draw: flat, or glass with a material
    /// set, per `PaneChrome.resolvedStyle(setting:materialIsDark:appearance:)`.
    ///
    /// Stored rather than passed straight through, because ``applyPresentation()``
    /// reads it back to decide the lift's visibility.
    private(set) var resolvedChrome: ResolvedChrome = .flat {
        didSet {
            guard resolvedChrome != oldValue else { return }
            clusterView.resolvedChrome = resolvedChrome
            applyResolvedGlassPlane()
            applyPresentation()
        }
    }

    /// The lift's own numbers and the rim's, pushed straight to ``liftView``,
    /// which keeps its own equality guard.
    private var liftParameters: PaneLiftParameters {
        get { liftView.parameters }
        set { liftView.parameters = newValue }
    }

    private var rimParameters: PaneRimParameters {
        get { liftView.rim }
        set { liftView.rim = newValue }
    }

    /// The owner's one opacity knob. Under glass it drives the wash (floored);
    /// the surface's own `background-opacity` is zeroed for glass-spawned panes
    /// so the well is not painted twice. Appearance only: nothing here touches
    /// geometry.
    private var backgroundOpacity: Double = 1 {
        didSet {
            guard backgroundOpacity != oldValue else { return }
            updateGlassWashColour()
        }
    }

    /// `chrome.paneWashFloor`, nil for the `ChromeMaterials.PaneWash.floor`
    /// constant.
    private var paneWashFloor: Double? {
        didSet {
            guard paneWashFloor != oldValue else { return }
            updateGlassWashColour()
        }
    }

    /// `chrome.cluster.cornerInset`, nil for the `PaneClusterMetrics.cornerInset`
    /// constant. Re-pins the installed capsule's two constraints in place; when
    /// the capsule is not installed the value waits here and
    /// ``installClusterView()`` reads it at pin time.
    private var clusterCornerInset: Double? {
        didSet {
            guard clusterCornerInset != oldValue else { return }
            for constraint in clusterEdgeConstraints {
                constraint.constant = resolvedClusterInset
            }
            // And onto the pill, because the notice budget reserves this inset
            // at both ends of the pane. The constraints and the budget must
            // read one value or the pill is pinned at one number and bounded
            // by another.
            clusterView.cornerInset = resolvedClusterInset
        }
    }

    /// `chrome.cluster.opacity`, straight through to the capsule, which keeps
    /// its own equality guard.
    private var clusterOpacity: Double? {
        get { clusterView.fillOpacity }
        set { clusterView.fillOpacity = newValue }
    }

    private var resolvedClusterInset: Double {
        clusterCornerInset ?? PaneClusterMetrics.cornerInset
    }

    /// Pushes the thirteen chrome fields of `appearance`, in the order
    /// `ConfigurationCenter.apply(to:)` used to assign them one property at a
    /// time, and repaints once.
    ///
    /// The three terminal fields ride on the same value and are the pane's
    /// business: it picks the spawn-frozen configuration and hands it to its
    /// controller. This object never touches the surface.
    func apply(_ appearance: PaneAppearance) {
        theme = appearance.theme
        attentionStyle = appearance.attentionStyle
        // Straight through. The resolution is `PaneTheme.attentionColour(_:behavior:)`,
        // which has tests; a line here that decided anything about these two
        // would not, and that is exactly how `focusAccent` came to be decoded,
        // stored, and never read.
        attentionAccent = appearance.attentionAccent
        alertBehavior = appearance.alertBehavior
        // Arrives already resolved from the two live inputs `PaneAppearance.make`
        // closed over, so it stays correct whether this runs from registration,
        // a settings reload, an appearance change, or a preview.
        resolvedChrome = appearance.resolvedChrome
        liftParameters = appearance.liftParameters
        rimParameters = appearance.rimParameters
        backgroundOpacity = appearance.backgroundOpacity
        paneWashFloor = appearance.paneWashFloor
        clusterCornerInset = appearance.clusterCornerInset
        clusterOpacity = appearance.clusterOpacity
        applyPresentation()
    }

    // MARK: - State

    /// Which of the window's bottom corners this pane sits in.
    ///
    /// The attention frame, the lift and the glass masks all reach the corner,
    /// and they overlap there, so a value that moved one of them would put a
    /// square frame over a curved fill. ``edgeFrame`` is the store, being the
    /// one view that cannot go away.
    var bottomCorners: BottomCorners {
        get { edgeFrame.bottomCorners }
        set {
            edgeFrame.bottomCorners = newValue
            liftView.bottomCorners = newValue
            updateGlassPlaneMasks()
        }
    }

    var isPaneFocused = false {
        didSet {
            guard isPaneFocused != oldValue else { return }
            applyPresentation()
        }
    }

    /// Whether this pane's window is the key window.
    ///
    /// Every pane recedes when the window is not key, including the focused one,
    /// so an inactive window reads as one recessed object rather than as a window
    /// that still has a live pane in it.
    var isWindowActive = true {
        didSet {
            guard isWindowActive != oldValue else { return }
            applyPresentation()
        }
    }

    /// The chrome's three-level attention value, which decides the frame.
    ///
    /// The frame follows the level, so a change repaints here rather than from
    /// the pane's status refresh, which fires on every poll of a pane that is
    /// merely compiling.
    var attention: PaneStatus.Attention = .none {
        didSet {
            guard attention != oldValue else { return }
            applyPresentation()
        }
    }

    // MARK: - Installing

    /// Puts every view into `host` around `surface`, in the pane's stacking.
    ///
    /// The glass plane and wash go below the surface (created only if the chrome
    /// resolved to glass before the view loaded, which is the common case: the
    /// configuration centre applies at registration); the capsule goes above the
    /// surface and below the scrim, so a background window's scrim lies over the
    /// pill and a click still falls through to it; the scrim, the frame and the
    /// lift go last. liftView is added after edgeFrame, so an attention frame and
    /// the focused-pane lift never fight over which draws on top.
    func install(in host: NSView, around surface: NSView) {
        self.host = host
        self.surface = surface
        for overlay in [scrim, edgeFrame, liftView] {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: host.topAnchor),
                overlay.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
        installClusterView()
        applyResolvedGlassPlane()
        applyPresentation()
    }

    /// Rebuilds the corner masks after the host laid out. A mask layer's frame
    /// does not track its host's bounds, so a resize that does not rebuild it
    /// leaves the squircle at the old size.
    func layoutDidChange() {
        updateGlassPlaneMasks()
    }

    // MARK: - Drawing

    /// Pushes focus, window activation, theme and attention into the views that
    /// draw them, in one pass.
    ///
    /// One method rather than one per input, because every input moves more than
    /// one view: a theme change has to reach the scrim as well as the capsule, and
    /// an attention change has to reach the pane frame as well as the pill.
    private func applyPresentation() {
        clusterView.isPaneFocused = isPaneFocused
        clusterView.isWindowActive = isWindowActive
        clusterView.theme = theme
        scrim.colour = theme.background
        // An inactive window is the only thing that scrims a pane. An unfocused
        // pane in the key window is left alone and the focused one is marked by
        // its lift instead.
        scrim.amount = isWindowActive ? 0 : PaneTheme.inactiveScrim
        // The pane frame has one reason to appear and therefore one colour, but
        // the colour still has to be pushed on every pass: a live theme edit moves
        // what the attention colour resolves to under a frame that is already on
        // screen. Resolved from the same call the capsule's own attention colour
        // comes from, so the frame around the pane and the pill inside it cannot
        // end up two colours.
        edgeFrame.colour = theme.attentionColour(attentionAccent, behavior: alertBehavior)
        // Not gated on `isWindowActive`, unlike focus: focus is a statement about
        // a window that has the keyboard, while an unanswered agent in a
        // background window is exactly the thing worth finding. The conjunction
        // is `PaneStatus.Attention.wearsFrame(under:)`, the one copy of the rule.
        edgeFrame.isVisible = attention.wearsFrame(under: attentionStyle)
        // `isFocused && isWindowActive`, glass-only: under flat (or Reduce
        // Transparency, which `resolvedChrome` already folds into `.flat`
        // upstream) the lift stays invisible and focus goes unmarked.
        let isGlass = if case .glass = resolvedChrome { true } else { false }
        liftView.isVisible = isPaneFocused && isWindowActive && isGlass
        updateGlassWashColour()
    }

    /// Creates or tears down the plane and wash to match ``resolvedChrome``.
    ///
    /// Appearance only: both views sit behind the surface at the pane's full
    /// bounds, so neither creation nor teardown moves the surface's frame or any
    /// padding. A glass-to-glass change (`liquidGlass` to `sheer`, or back)
    /// keeps the existing plane and rewrites its native style, since the plane
    /// did not need to move either.
    private func applyResolvedGlassPlane() {
        switch resolvedChrome {
        case .flat:
            glassWash?.removeFromSuperview()
            glassWash = nil
            glassPlane?.removeFromSuperview()
            glassPlane = nil
        case let .glass(set):
            if let glassPlane {
                glassPlane.style = NSGlassEffectView.Style(set.nativeStyle)
                return
            }
            guard let host, let surface else { return }
            installGlassPlane(in: host, below: surface, style: set.nativeStyle)
        }
    }

    private func installGlassPlane(in host: NSView, below surface: NSView, style: NativeGlassStyle) {
        let plane = PaneGlassPlaneView(frame: host.bounds)
        plane.style = NSGlassEffectView.Style(style)
        plane.wantsLayer = true
        // The mask carries the window's squircle; a uniform cornerRadius would
        // round corners the window does not cut.
        plane.cornerRadius = 0
        plane.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(plane, positioned: .below, relativeTo: surface)

        let wash = PaneGlassWashView(frame: host.bounds)
        wash.wantsLayer = true
        wash.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(wash, positioned: .above, relativeTo: plane)

        for planeLayer in [plane, wash] as [NSView] {
            NSLayoutConstraint.activate([
                planeLayer.topAnchor.constraint(equalTo: host.topAnchor),
                planeLayer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                planeLayer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                planeLayer.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }

        glassPlane = plane
        glassWash = wash
        updateGlassPlaneMasks()
        updateGlassWashColour()
    }

    /// Adds the capsule below the scrim, pinned by its top-right corner alone at
    /// the dialled inset; width and height come from the view's own
    /// `intrinsicContentSize`, which tracks the measured segments.
    private func installClusterView() {
        guard let host, clusterView.superview == nil else { return }
        clusterView.cornerInset = resolvedClusterInset
        clusterView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(clusterView, positioned: .below, relativeTo: scrim)
        let edges = [
            clusterView.topAnchor.constraint(
                equalTo: host.topAnchor,
                constant: resolvedClusterInset
            ),
            host.trailingAnchor.constraint(
                equalTo: clusterView.trailingAnchor,
                constant: resolvedClusterInset
            ),
        ]
        NSLayoutConstraint.activate(edges)
        clusterEdgeConstraints = edges
    }

    /// Clips the plane and the wash to the pane's window corners.
    ///
    /// Orientation is load-bearing: `WindowCorner.cgPath` requires a flipped
    /// view or the shape is upside down, and both glass views declare
    /// `isFlipped: true` for exactly this reason.
    private func updateGlassPlaneMasks() {
        for masked in [glassPlane, glassWash] as [NSView?] {
            guard let masked, let layer = masked.layer else { continue }
            guard masked.bounds.width > 0, masked.bounds.height > 0 else { continue }
            let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
            mask.frame = masked.bounds
            mask.path = WindowCorner.cgPath(in: masked.bounds, corners: bottomCorners)
            layer.mask = mask
        }
    }

    /// The wash's one derivation: `theme.background` at
    /// `max(backgroundOpacity, floor)`.
    private func updateGlassWashColour() {
        glassWash?.colour = SidebarRowMetrics.nsColor(
            theme.background,
            alpha: ChromeMaterials.PaneWash.opacity(
                backgroundOpacity: backgroundOpacity,
                floorOverride: paneWashFloor
            )
        )
    }
}
