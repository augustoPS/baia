import AppKit
import BaiaSettings
import PaneChrome

// When the owner moves one of the four signal dials, does the settings
// preview's chrome visibly change — and by how much, at the size the preview
// actually renders at?
//
// `SettingsPreviewPane` swapped its chrome from the retired `PaneStatusBarView`
// to `PaneClusterView` on 2026-08-13. The footer was a 22 pt bar across the
// pane's full width; the capsule is a ~20 pt pill in its top-right corner, a
// fraction of the area. The owner's ruling was "decide after I measure" rather
// than assume a pill-sized preview shows what a bar-sized one did, and this
// probe is that measurement.
//
// **The method is a differential, not a legibility grade.** `cluster-legibility`
// already grades the pill's ink and dot against WCAG floors and pins the
// numbers; nothing here re-asks that. The question here is different: a dial the
// owner *turns* has to produce a change the owner can *see*, so every arm
// renders the preview's chrome twice — once at each end of the dial — and
// measures the difference between the two bitmaps. Two numbers per dial:
//
//   - **changed area**, the count of pixels differing by more than one byte on
//     any channel, in view points², and as a share of the pane. This is "how
//     much of the preview moved".
//   - **the strongest delta**, and the contrast ratio between the two colours at
//     the pixel that moved most. This is "how different is what moved".
//
// A dial can fail either way and the two failures look nothing alike: a dial
// that recolours six points² by a mile is a real change nobody will notice, and
// a dial that recolours the whole pane by one byte is a change nobody can see.
// Both numbers are printed for every arm and both carry an assertion.
//
// **The geometry is the preview's own, derived rather than guessed.** See
// `paneSize` for the arithmetic and where each term comes from. Rendering the
// pill at its intrinsic size — which is what `cluster-legibility` does, and
// correctly for its own question — would answer a question about a pill in
// isolation, and "is this legible in the settings window" is a question about a
// pill in a 238 × 291 pt pane.
//
// **The harness is `cluster-legibility`'s**, unchanged: the shipped views
// compiled verbatim, rendered offscreen through `cacheDisplay(in:to:)`, bytes
// read back. No window server, no capture, no compositor, so every number is
// deterministic and a changed byte is a changed feature.
//
// Every arm has a negative control (`break`), and here the controls are the
// load-bearing half rather than a formality. An arm that renders the *same*
// settings twice measures zero and would pass a "nothing changed" assertion
// trivially; an arm whose render ignored the dial entirely would also measure
// zero. So the controls are built the other way round: under `break` each arm
// renders both halves at the *same* dial value, and the arm's own
// "something changed" assertions must fail. A control that still reports change
// means the two renders differ for a reason that is not the dial — a stale
// view, a random fixture, a leaked state — and the arm is measuring noise.

// MARK: - geometry

/// The preview pane's real size in points, as the settings window lays it out.
///
/// Derived from the constants at each site rather than measured from a live
/// window, because every term is a constant in the source and a live window
/// would add the one thing this probe must not have (a compositor):
///
///   - width. `SettingsWindowController` opens at 1180 wide; the form is pinned
///     to 400; the samples stack carries 12 pt of right inset and 12 pt of
///     spacing between the two columns, split `fillEqually`. So each column is
///     (1180 − 400 − 12 − 12) / 2 = 378. Inside `SettingsPreviewColumn` the
///     sidebar takes 132 and the panes start 8 after it: 378 − 132 − 8 = 238.
///   - height. The window opens at 660; the samples stack takes 12 pt of inset
///     at top and bottom, and `labelled(_:_:)` puts an 11 pt caption above each
///     column with 6 pt of spacing. Two panes, `fillEqually`, 8 pt apart:
///     (660 − 24 − 17 − 6 − 8) / 2 ≈ 302.5, floored to 302 here. The exact
///     figure does not matter to any assertion below — every arm's numbers are
///     reported as a share of whatever this is — and it matters to none of them
///     that the window is resizable, which only ever makes the pane bigger.
///
/// **This is the geometry the swap did *not* change, which is the point.** The
/// pane's height came from the column's `fillEqually` stack before the swap and
/// comes from it after; the footer's reserved height only ever decided how much
/// of that height the *surface* got, not how much the pane had. (That accessor
/// was `PaneStatusBarMetrics.reservedHeight(focused:)`, deleted with its type on
/// 2026-08-13; the 22 pt survives as `PaneChromeMetrics.paneBarHeight`.)
let paneSize = NSSize(width: 238, height: 302)

/// The capsule's frame inside the pane, as `SettingsPreviewPane` pins it: top
/// and trailing at `PaneClusterMetrics.cornerInset`, width and height from the
/// view's own `intrinsicContentSize`. The same two anchors
/// `TerminalPaneController.installClusterView()` uses.
func capsuleFrame(for capsule: PaneClusterView) -> NSRect {
    let size = capsule.intrinsicContentSize
    return NSRect(
        x: paneSize.width - PaneClusterMetrics.cornerInset - size.width,
        y: PaneClusterMetrics.cornerInset,
        width: size.width,
        height: size.height
    )
}

// MARK: - offscreen rendering

/// The pane's content under the chrome: the sample terminal's background.
///
/// `SettingsSampleSurface` is a live ghostty surface and cannot be linked here
/// (it needs Metal and a window), so its *background* stands in for it — which
/// is what the chrome composites against anyway, and is the honest worst case
/// besides: the capsule's own backing (`ChromeMaterials.PaneWash.floor`) exists
/// precisely so brighter content beneath cannot read through, and
/// `cluster-legibility`'s bright arm already measures that the pill's face
/// barely moves under a `#7c7c7c` backdrop. A dial's *delta* is measured
/// between two renders over the same backdrop, so the backdrop cancels out of
/// every number below regardless.
final class PaneBackdropView: NSView {
    var colour: NSColor = .black
    override var isFlipped: Bool { true }
    override func draw(_: NSRect) {
        colour.setFill()
        bounds.fill()
    }
}

/// The preview pane's chrome stack, rendered offscreen at `paneSize`.
///
/// The two real views `SettingsPreviewPane` installs, in the order it installs
/// them and at the frames it pins them to: the edge frame at the pane's full
/// bounds, the capsule pinned by its top-right corner. `cacheDisplay(in:to:)`
/// runs the real `draw(_:)` on both with no window in the path.
@MainActor
func renderPreviewPane(
    theme: PaneTheme,
    status: PaneStatus,
    focused: Bool,
    settings: Settings
) -> NSBitmapImageRep {
    let container = PaneBackdropView(frame: NSRect(origin: .zero, size: paneSize))
    container.colour = NSColor(
        srgbRed: theme.background.red,
        green: theme.background.green,
        blue: theme.background.blue,
        alpha: 1
    )

    // `SettingsPreviewPane.apply(_:theme:chrome:settings:)`, line for line. Not
    // a paraphrase of it: if that method and this diverge, the probe measures a
    // preview that does not exist.
    let frame = PaneEdgeFrameView(frame: container.bounds)
    frame.colour = theme.attentionColour(settings.attentionAccent, behavior: settings.alertBehavior)
    frame.isVisible = status.attention.wearsFrame(under: settings.attentionStyle)
    container.addSubview(frame)

    let capsule = PaneClusterView(frame: .zero)
    capsule.segments = PaneClusterSegments.build(from: status)
    capsule.isPaneFocused = focused
    capsule.isWindowActive = true
    capsule.theme = theme
    capsule.attentionAccent = settings.attentionAccent
    capsule.alertBehavior = settings.alertBehavior
    capsule.frame = capsuleFrame(for: capsule)
    container.addSubview(capsule)

    container.layoutSubtreeIfNeeded()
    guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else {
        fatalError("no bitmap rep for the preview pane")
    }
    container.cacheDisplay(in: container.bounds, to: rep)
    return rep
}

/// What differs between two renders of the same pane at two dial values.
struct Difference {
    /// Pixels differing by more than one byte on any channel, in view points².
    /// One byte of tolerance, because the two renders go through the same
    /// antialiaser and a glyph edge can land a byte apart for no reason a dial
    /// caused.
    var changedArea: Double
    /// The two colours at the pixel that moved most, by summed channel
    /// distance, and where it is.
    var before: RGB
    var after: RGB
    var at: NSPoint

    /// How different the strongest-moving pixel is, as a WCAG contrast ratio.
    /// A ratio is the right unit here for the reason `cluster-legibility` uses
    /// it: the eye's response to a colour change is not linear in bytes, and
    /// 1.00:1 is exactly "no visible difference".
    var strongestContrast: Double { before.contrastRatio(against: after) }

    var changedShare: Double { changedArea / (paneSize.width * paneSize.height) }
}

func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Difference {
    let scale = Double(a.pixelsWide) / paneSize.width
    let pointArea = 1.0 / (scale * scale)
    var changed = 0
    var worst = -1.0
    var before = RGB(red: 0, green: 0, blue: 0)
    var after = RGB(red: 0, green: 0, blue: 0)
    var at = NSPoint.zero

    for py in 0 ..< a.pixelsHigh {
        for px in 0 ..< a.pixelsWide {
            guard let ca = a.colorAt(x: px, y: py)?.usingColorSpace(.sRGB),
                  let cb = b.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
            let dr = abs(ca.redComponent - cb.redComponent)
            let dg = abs(ca.greenComponent - cb.greenComponent)
            let db = abs(ca.blueComponent - cb.blueComponent)
            guard max(dr, max(dg, db)) * 255 > 1 else { continue }
            changed += 1
            let sum = dr + dg + db
            if sum > worst {
                worst = sum
                before = RGB(
                    red: ca.redComponent, green: ca.greenComponent, blue: ca.blueComponent
                )
                after = RGB(
                    red: cb.redComponent, green: cb.greenComponent, blue: cb.blueComponent
                )
                at = NSPoint(x: Double(px) / scale, y: Double(py) / scale)
            }
        }
    }
    return Difference(
        changedArea: Double(changed) * pointArea, before: before, after: after, at: at
    )
}

// MARK: - fixtures

/// The column's own sample statuses, `SettingsPreviewColumn.status(asking:)`
/// verbatim. Copied rather than linked because that function is private to a
/// file in `Sources/` that imports `GhosttyTerminal`; the copy is checked
/// against the real one by `theFixtureMatchesTheColumn` below, so a drift in
/// either direction fails the run rather than quietly measuring the wrong pane.
func sampleStatus(asking: Bool) -> PaneStatus {
    PaneStatus(
        anchorName: "baia",
        anchorIsRepository: true,
        isPinned: false,
        workingDirectory: nil,
        git: PaneStatus.Git(
            head: "main",
            hasUpstream: true,
            ahead: 2,
            behind: 0,
            dirty: true,
            untracked: 3,
            conflicted: 0,
            operation: nil,
            isLinkedWorktree: false
        ),
        agent: PaneStatus.Agent(
            label: "claude",
            wantsAttention: asking,
            isAcknowledged: false,
            isBusy: !asking
        )
    )
}

/// The theme the preview is themed with, at the shipped default theme name.
///
/// **Not `SettingsDerivations.paneTheme(from:)`, and the substitution is exact
/// rather than approximate.** That function is the app's own derivation and
/// would be the thing to call, but it lives in a file that imports
/// `GhosttyTerminal` for its sibling `terminalTheme(from:)`, which needs Metal
/// and cannot be linked into an offscreen probe. What it does with a settings
/// value is two steps: look the theme name up in the catalog, and hand
/// `focusAccent` to `PaneTheme`'s palette initializer, which resolves it through
/// `accent(for:)` after the palette exists.
///
/// `Settings.defaultSettings.themeName` is Dark Pastel and `PaneTheme.darkPastel`
/// is that catalog entry already built, so the lookup is a constant here; what
/// remains is the accent resolution, and `accent(for:)` is public and is
/// literally the line the initializer runs (`focusedAccent = accent(for:)`).
/// `theTwoDerivationsAgree` in `SettingsDerivationsTests` is not reachable from
/// here, so the substitution is pinned instead by the arms themselves: a
/// `focusAccent` arm measuring zero would mean this resolution stopped moving
/// the theme.
///
/// Every arm holds `themeName` at the default, so no arm depends on the lookup
/// this skips.
func previewTheme(_ settings: Settings) -> PaneTheme {
    var theme = PaneTheme.darkPastel
    theme.focusedAccent = theme.accent(for: settings.focusAccent)
    return theme
}

// MARK: - arms

@MainActor enum State {
    static var failures: [String] = []
    static var broken = false
}

@MainActor func check(_ passed: Bool, _ what: String) {
    print("  \(passed ? "ok  " : "FAIL") \(what)")
    if !passed { State.failures.append(what) }
}

@MainActor var broken: Bool { State.broken }

/// The floor a dial's *change* has to clear to count as visible.
///
/// 1.1:1 rather than a WCAG floor, and the two thresholds answer different
/// questions. WCAG's 4.5:1 and 3:1 are about reading a mark against its
/// background; this is about telling two renders of the same mark apart, which
/// is a far easier task — the owner has both columns side by side and is looking
/// for the difference. 1.1:1 is roughly a 5% luminance step, about where a
/// side-by-side comparison stops being reliable for a small mark. It is this
/// probe's own number, stated rather than borrowed, and it is deliberately
/// generous: an arm that fails it has produced a change nobody could find under
/// any threshold.
let visibleContrast = 1.1

/// The area a dial's change has to cover to count as findable, in points².
///
/// The attention dot is 6 pt across, so its disc is about 28 points²; a dial
/// that recolours only the dot moves roughly that. This floor is set at 20 —
/// under the dot, so a dot-only dial passes on area and is judged on contrast —
/// because a mark smaller than the dot is smaller than the smallest thing the
/// capsule deliberately draws, and would be a change the design itself does not
/// consider legible.
let visibleArea = 20.0

/// One dial arm: two renders that differ only in the named setting, and the
/// difference between them.
/// Where a dial's strongest-moving pixel is required to land.
///
/// **Added because "something changed" is exactly the assertion a sibling code
/// path can satisfy.** Without this, a `focusAccent` arm would pass on any
/// difference anywhere in the 238 × 302 pane — including one the dial caused
/// somewhere it has no business being, or one a shared theme derivation caused
/// in a view the arm is not about. `focusAccent` in particular reaches
/// `theme.focusedAccent`, which `attentionColour(.accent, …)` also reads, so the
/// two attention arms and this one all move the same underlying colour and only
/// the *location* of the change tells them apart.
enum Where {
    /// Inside the capsule's own frame: the arm is about the pill.
    case capsule
    /// Along the pane's edge, outside the capsule: the arm is about the frame.
    case paneEdge

    @MainActor func contains(_ point: NSPoint, capsule frame: NSRect) -> Bool {
        switch self {
        case .capsule: frame.contains(point)
        case .paneEdge: !frame.contains(point)
        }
    }

    var describing: String {
        switch self {
        case .capsule: "inside the capsule"
        case .paneEdge: "on the pane's edge"
        }
    }
}

@MainActor func gradeDial(
    _ name: String,
    asking: Bool,
    focused: Bool,
    lands: Where,
    from: (inout Settings) -> Void,
    to: (inout Settings) -> Void
) {
    var lhs = Settings.defaultSettings
    from(&lhs)
    var rhs = Settings.defaultSettings
    // The control renders both halves at the *same* dial value, so the arm's
    // "something changed" assertions must fail. See the file header: an arm
    // whose render ignored the dial would measure zero and pass a naive check,
    // and this is what proves the zero would have been noticed.
    if broken { from(&rhs) } else { to(&rhs) }

    let status = sampleStatus(asking: asking)
    let a = renderPreviewPane(
        theme: previewTheme(lhs), status: status, focused: focused, settings: lhs
    )
    let b = renderPreviewPane(
        theme: previewTheme(rhs), status: status, focused: focused, settings: rhs
    )
    let diff = difference(a, b)

    print(String(
        format: "  %@ on the %@ pane: %.0f pt² changed (%.2f%% of the pane), "
            + "strongest pixel %@ -> %@ at (%.0f, %.0f) = %.2f:1",
        name, asking ? "asking" : "focused", diff.changedArea, diff.changedShare * 100,
        diff.before.hexString, diff.after.hexString, diff.at.x, diff.at.y,
        diff.strongestContrast
    ))
    check(
        diff.changedArea >= visibleArea,
        String(format: "%@ moves %.0f pt² >= %.0f pt²", name, diff.changedArea, visibleArea)
    )
    check(
        diff.strongestContrast >= visibleContrast,
        String(
            format: "%@'s strongest pixel reads %.2f:1 >= %.2f:1",
            name, diff.strongestContrast, visibleContrast
        )
    )
    // The change has to land where the arm says it does. See ``Where``: all
    // three colour dials move derivations of the same two theme colours, so
    // without this an arm passes on a change caused somewhere it is not about.
    let probe = PaneClusterView(frame: .zero)
    probe.segments = PaneClusterSegments.build(from: status)
    check(
        lands.contains(diff.at, capsule: capsuleFrame(for: probe)),
        String(
            format: "%@'s strongest pixel (%.0f, %.0f) is %@",
            name, diff.at.x, diff.at.y, lands.describing
        )
    )
}

/// `focusAccent`: the capsule's inset focus stroke, on the focused pane.
/// Shown as `.accent` (the default, Dark Pastel's selection blue) against
/// `.bone`, the design pass's recommendation and the furthest from it in hue.
@MainActor func armFocusAccent() {
    print("== focusAccent: the capsule's inset stroke, accent -> bone")
    gradeDial(
        "focusAccent", asking: false, focused: true, lands: .capsule,
        from: { $0.focusAccent = .accent },
        to: { $0.focusAccent = .bone }
    )
}

/// `attentionAccent`: the capsule's dot, and the pane frame under `loud`.
/// `.alert` (the default, `ansi[1]`) against `.accent`, which resolves the dot
/// to the focus colour.
@MainActor func armAttentionAccent() {
    print("== attentionAccent: the dot and the pane frame, alert -> accent")
    gradeDial(
        "attentionAccent", asking: true, focused: false, lands: .paneEdge,
        from: { $0.attentionAccent = .alert },
        to: { $0.attentionAccent = .accent }
    )
}

/// `alertBehavior`: what happens when the attention colour collides.
///
/// Held at `attentionAccent = .accent` for both halves, because that is the
/// only configuration where this key does anything at all —
/// `PaneTheme.alertBehaviorMatters(for:)` is the app's own predicate for that,
/// and the settings window hides the picker when it answers false. Under
/// `.accent` the attention colour *is* the focus colour, so it always collides
/// and `.noCollision` always falls back to alert. Grading it at the default
/// `.alert` accent on Dark Pastel would measure a key the app itself declares
/// inert, and report zero for a reason that is not the preview's fault.
@MainActor func armAlertBehavior() {
    print("== alertBehavior: the colliding dot, stock -> noCollision (at accent)")
    let theme = previewTheme(Settings.defaultSettings)
    check(
        theme.alertBehaviorMatters(for: .accent),
        "alertBehavior is live on this theme under the accent attention colour"
    )
    gradeDial(
        "alertBehavior", asking: true, focused: false, lands: .paneEdge,
        from: { $0.attentionAccent = .accent; $0.alertBehavior = .stock },
        to: { $0.attentionAccent = .accent; $0.alertBehavior = .noCollision }
    )
}

/// `attentionStyle`: the pane's 2 pt edge frame, `loud` against `quiet`.
///
/// The one of the four that never reached the capsule. `PaneClusterView` has no
/// `attentionStyle` property; in a real pane the key gates
/// `TerminalPaneController.drawsAttentionFrame`, which is `PaneEdgeFrameView`.
/// So this arm measures the frame `SettingsPreviewPane` installs for exactly
/// this reason, and its number is the answer to whether that view had to be
/// there.
@MainActor func armAttentionStyle() {
    print("== attentionStyle: the pane's edge frame, loud -> quiet")
    gradeDial(
        "attentionStyle", asking: true, focused: false, lands: .paneEdge,
        from: { $0.attentionStyle = .loud },
        to: { $0.attentionStyle = .quiet }
    )
}

/// The capsule-alone counterfactual: what each attention dial would have
/// measured with no pane frame in the preview.
///
/// Not an arm of the swap — it renders a preview that does not exist — but the
/// number behind the shape recommendation, so it is measured rather than
/// argued. Same two renders as the arms above with `PaneEdgeFrameView` left
/// out, printed and asserted against the same floors, and the assertions are
/// *inverted* where the pill alone cannot carry the dial.
@MainActor func armCapsuleAlone() {
    print("== capsule alone (counterfactual): the same dials with no pane frame")

    func capsuleOnly(_ settings: Settings, status: PaneStatus) -> NSBitmapImageRep {
        let theme = previewTheme(settings)
        let container = PaneBackdropView(frame: NSRect(origin: .zero, size: paneSize))
        container.colour = NSColor(
            srgbRed: theme.background.red,
            green: theme.background.green,
            blue: theme.background.blue,
            alpha: 1
        )
        let capsule = PaneClusterView(frame: .zero)
        capsule.segments = PaneClusterSegments.build(from: status)
        capsule.isPaneFocused = false
        capsule.isWindowActive = true
        capsule.theme = theme
        capsule.attentionAccent = settings.attentionAccent
        capsule.alertBehavior = settings.alertBehavior
        capsule.frame = capsuleFrame(for: capsule)
        container.addSubview(capsule)
        container.layoutSubtreeIfNeeded()
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else {
            fatalError("no bitmap rep")
        }
        container.cacheDisplay(in: container.bounds, to: rep)
        return rep
    }

    let status = sampleStatus(asking: true)

    for (name, lhsEdit, rhsEdit) in [
        (
            "attentionAccent",
            { (s: inout Settings) in s.attentionAccent = .alert },
            { (s: inout Settings) in s.attentionAccent = .accent }
        ),
        (
            "alertBehavior",
            { (s: inout Settings) in s.attentionAccent = .accent; s.alertBehavior = .stock },
            { (s: inout Settings) in s.attentionAccent = .accent; s.alertBehavior = .noCollision }
        ),
        (
            "attentionStyle",
            { (s: inout Settings) in s.attentionStyle = .loud },
            { (s: inout Settings) in s.attentionStyle = .quiet }
        ),
    ] {
        var lhs = Settings.defaultSettings
        lhsEdit(&lhs)
        var rhs = Settings.defaultSettings
        if broken { lhsEdit(&rhs) } else { rhsEdit(&rhs) }
        let diff = difference(capsuleOnly(lhs, status: status), capsuleOnly(rhs, status: status))
        print(String(
            format: "  %@ with no frame: %.0f pt² changed, strongest %.2f:1",
            name, diff.changedArea, diff.strongestContrast
        ))
        if name == "attentionStyle" {
            // Inverted: the pill has no `attentionStyle` property, so a
            // capsule-alone preview must measure *exactly zero* for this dial.
            // A non-zero here would mean the pill does respond to it somehow,
            // and the recommendation below would be wrong.
            check(
                diff.changedArea == 0,
                String(
                    format: "attentionStyle moves nothing on the pill alone (%.0f pt²)",
                    diff.changedArea
                )
            )
        } else {
            // Under `break` both halves are the same settings, so these must
            // measure zero too and the check must fail — the same control
            // shape `gradeDial` runs.
            check(
                diff.changedArea >= visibleArea,
                String(
                    format: "%@ still moves %.0f pt² on the pill alone", name, diff.changedArea
                )
            )
        }
    }
}

/// The fixture is the column's, not a lookalike.
///
/// `SettingsPreviewColumn.status(asking:)` is private to a file this probe
/// cannot link, so ``sampleStatus(asking:)`` is a copy — and a copy is exactly
/// what goes stale. This pins the two facts the arms depend on: the asking pane
/// wears an attention dot and the calm one does not, which is what makes the
/// attention dials measurable at all, and both wear the same resting segments,
/// which is what makes the two panes comparable.
@MainActor func armFixture() {
    print("== fixture: the sample statuses carry what the arms measure")
    let asking = PaneClusterSegments.build(from: sampleStatus(asking: true))
    let calm = PaneClusterSegments.build(from: sampleStatus(asking: false))
    check(
        asking.contains { $0.role == .attention },
        "the asking pane's capsule carries the attention dot"
    )
    check(
        !calm.contains { $0.role == .attention },
        "the calm pane's capsule carries no attention dot"
    )
    check(
        asking.filter { $0.role != .attention } == calm.filter { $0.role != .attention },
        "both panes carry the same resting segments"
    )
    check(
        sampleStatus(asking: true).attention.wearsFrame(under: .loud),
        "the asking pane wears the edge frame under loud, which is what the style arm moves"
    )
    check(
        !sampleStatus(asking: false).attention.wearsFrame(under: .loud),
        "the calm pane wears no edge frame at either style"
    )
}

// MARK: - main

/// `@main` on an enum rather than top-level code, `cluster-legibility`'s own
/// shape: the whole file compiles under the app target's `-default-isolation
/// MainActor`, and top-level expressions are not allowed in a file compiled
/// beside others.
@main
enum Probe {
    @MainActor static func main() {
        // Accessory, and nothing is ever ordered front: this probe opens no
        // window at all. The policy is set anyway so the process does not
        // appear in the Dock for the second it runs.
        NSApplication.shared.setActivationPolicy(.accessory)

        let arms: [String: @MainActor () -> Void] = [
            "fixture": armFixture,
            "focus-accent": armFocusAccent,
            "attention-accent": armAttentionAccent,
            "alert-behavior": armAlertBehavior,
            "attention-style": armAttentionStyle,
            "capsule-alone": armCapsuleAlone,
        ]

        State.broken = CommandLine.arguments.contains("break")

        guard let name = CommandLine.arguments.dropFirst().first, let arm = arms[name] else {
            print("usage: dials <\(arms.keys.sorted().joined(separator: "|"))> [break]")
            exit(2)
        }

        print("pane \(Int(paneSize.width)) x \(Int(paneSize.height)) pt"
            + (State.broken ? "  [CONTROL: both halves at the same dial value]" : ""))
        arm()

        if State.failures.isEmpty {
            print("PASS")
            exit(0)
        }
        print("FAIL: \(State.failures.count) check(s)")
        exit(1)
    }
}
