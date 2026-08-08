import AppKit
import PaneChrome

/// The sidebar's own row naming the session it is a working set for. Design v5
/// §5, above `CHANGED`.
///
/// A restyle target the sidebar never drew before Plan 3: `SurfaceTitleView`'s
/// `anchorName` used to carry the repository name on the `CHANGED` heading
/// (design v3 §4.2, "the connector between the footer and the sidebar"), and
/// this row replaces that connector with a purpose-built one that also carries
/// the branch and the pane's status word, which the heading had no room for.
/// `SurfaceTitleView.anchorName` is left in place rather than removed: it is
/// still what `SettingsPreviewColumn` themes, and a property with one fewer
/// caller is not a property that stopped meaning anything.
///
/// **Reads ``PaneChrome/PaneStatus`` directly rather than deriving its own
/// facts.** `PaneStatusSegments.build(from:)` already turns this same struct
/// into the footer's segments, and duplicating that derivation here for three
/// fields would be the second copy of a rule the footer's own doc comment
/// warns against. This view draws fewer facts than the footer (no pin, no
/// operation, no markers), so it reads the struct's fields directly rather
/// than routing through a segment table built for a different bar's width
/// pressure.
///
/// **Never first responder**, for the reason every other sidebar view gives:
/// `AppTerminalView.performKeyEquivalent` guards on the *window's* first
/// responder, and a row here that took it would disable every ghostty binding
/// in every pane of the window.
@MainActor
final class SidebarSessionHeaderView: NSView {
    var theme: PaneTheme = .darkPastel { didSet { needsDisplay = true } }

    /// What the row names. Nil while no pane is focused, which draws nothing
    /// rather than a session with blank fields.
    var status: PaneStatus? { didSet { needsDisplay = true } }

    /// Gates the opaque fill in ``draw(_:)``. Pushed by `SidebarHost` the same
    /// way it pushes ``SurfaceTitleView/resolvedChrome`` (Task 3, following
    /// Task 2's pattern): this row sits directly over `SidebarHost`'s own
    /// glass backing, and its `barBackground` fill was still unconditional,
    /// which painted an opaque strip across that glass. Every ink below is
    /// unaffected — the spike's contrast measurement (finding 6) covered only
    /// ``SurfaceTitleView``'s caps label, not this row's repo/branch/status
    /// inks, so they are left as `theme`-derived colours for the live pass.
    ///
    /// **Read a second time by ``labelInk`` since the design panel's wiring.**
    /// The two faint-tier strings below go through that derivation now, which
    /// grades against the backdrop this row is actually drawn on, so the
    /// backdrop this property picks and the ink graded against it come from one
    /// value rather than two that could disagree.
    var resolvedChrome: ResolvedChrome = .flat { didSet { needsDisplay = true } }

    /// The faint-tier strings on this row — the branch and the status word — in
    /// the ink ``PaneChrome/PaneTheme/sessionHeaderInk(on:)`` resolves for the
    /// backdrop they land on.
    ///
    /// **This moves no pixel until something is dialled**, which is the whole
    /// point of routing through a derivation rather than leaving `theme.inkFaint`
    /// at the two call sites. Unadjusted, the derivation is `inkFaint` graded
    /// against its backdrop, the repair is a no-op wherever the faint tier
    /// already clears, and under flat that is exactly the `theme.inkFaint` these
    /// two strings always drew. What it buys is `sessionHeaderMinimumRatio` and
    /// `sessionHeaderHex` reaching a site that would otherwise be a constant no
    /// dial can touch.
    ///
    /// The backdrop is named the same way ``SurfaceTitleView/labelInk`` names
    /// its own, and for the same reason: under flat this row fills
    /// `theme.barBackground` and the ink sits on it, while under glass it fills
    /// nothing at all and the ink sits on whatever the column's glass sampled.
    /// ``WorkspaceSurface/measuredBrightGlass`` is the conservative stand-in for
    /// that, measured by the glass-backdrop spike; it is the same constant, and
    /// carries the same wallpaper caveat, that the caps label is graded against.
    ///
    /// The repo name is deliberately not routed here. It is `inkFocus`, a
    /// different tier, and the panel offers one dial for this row rather than a
    /// dial per string.
    private var labelInk: RGB {
        switch resolvedChrome {
        case .flat: theme.sessionHeaderInk(on: theme.barBackground)
        case .glass: theme.sessionHeaderInk(on: SurfaceTitleView.measuredBrightGlass)
        }
    }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { false }

    override func draw(_: NSRect) {
        // Flat draws its own opaque fill, unchanged from what Plan 1/Plan 3
        // shipped. Glass draws no fill at all (Task 3, same pattern as
        // ``SurfaceTitleView`` and `PaneStatusBarView.draw(_:)`): the ink
        // below renders directly over `SidebarHost.glassBacking`.
        switch resolvedChrome {
        case .flat:
            nsColor(theme.barBackground).setFill()
            bounds.fill()
        case .glass:
            break
        }

        nsColor(theme.hairline).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        guard let status else { return }

        var x = Self.inset

        // The quieted `!`: 60% of the alert ink over the row's own background,
        // `color-mix(in srgb, att 60%, transparent)` composited the way every
        // other alpha-simulating blend in this app is (``PaneTheme/warn``,
        // ``PaneTheme/staged``). Drawn only while a pane is still asking or has
        // been acknowledged; a done or idle pane earns no mark here, the same
        // gate the footer's own capsule uses.
        if status.attention == .asking || status.attention == .acknowledged {
            let quieted = theme.background.blended(with: theme.alert, fraction: 0.60)
            let mark = NSAttributedString(
                string: "!",
                attributes: [.font: Self.boldFont, .foregroundColor: nsColor(quieted)]
            )
            mark.draw(at: NSPoint(x: x, y: baseline(for: Self.boldFont)))
            x += mark.size().width + Self.markGap
        }

        // Repo, weight 700. `inkFocus` rather than a flat foreground: the same
        // ink `SurfaceTitleView.anchorName` used to draw, so the one fact that
        // moved rows did not also change how it reads.
        if !status.anchorName.isEmpty {
            let repo = NSAttributedString(
                string: status.anchorName,
                attributes: [.font: Self.repoFont, .foregroundColor: nsColor(theme.inkFocus)]
            )
            repo.draw(at: NSPoint(x: x, y: baseline(for: Self.repoFont)))
            x += repo.size().width
        }

        // `wt:branch`, tertiary, only inside a repository: a plain directory has
        // no branch to qualify, and ``PaneStatus/git`` can hold a stale answer
        // from before a `cd` out of one, the same guard
        // ``PaneStatusSegments/build(from:)`` applies before it draws anything
        // from `git`.
        if status.anchorIsRepository, let git = status.git, !git.head.isEmpty {
            let prefix = git.isLinkedWorktree ? "wt:" : ""
            let branch = NSAttributedString(
                string: " \(prefix)\(git.head)",
                attributes: [.font: Self.monoFont, .foregroundColor: nsColor(labelInk)]
            )
            branch.draw(at: NSPoint(x: x, y: baseline(for: Self.monoFont)))
        }

        // The status word, right-aligned, sans 9.5pt tertiary: what
        // `PaneActivityTracker.attentionLabel`/`paneAgent()` already computed
        // for the footer's own agent segment, read off the same struct rather
        // than recomputed.
        guard let word = status.agent?.label, !word.isEmpty else { return }
        let trailing = NSAttributedString(
            string: word,
            attributes: [.font: Self.statusFont, .foregroundColor: nsColor(labelInk)]
        )
        let width = trailing.size().width
        let start = bounds.width - Self.inset - width
        guard start > x + Self.markGap else { return }
        trailing.draw(at: NSPoint(x: start, y: baseline(for: Self.statusFont)))
    }

    /// One baseline for every string on the row, the same rule
    /// ``SurfaceTitleView`` and the footer both follow: independently centred
    /// strings in mixed sizes sit a fraction of a point apart, which reads as a
    /// mistake rather than a difference.
    private func baseline(for font: NSFont) -> Double {
        Self.baselineFromTop - Double(font.ascender)
    }

    private func nsColor(_ rgb: RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
    }

    static let height: Double = 28

    private static let inset = ChangesRowsView.inset
    private static let baselineFromTop: Double = 18
    private static let markGap: Double = 4
    private static let monoFont = ChangesRowsView.font
    private static let repoFont = NSFont.systemFont(ofSize: 11, weight: .bold)
    private static let boldFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    private static let statusFont = NSFont.systemFont(ofSize: 9.5, weight: .regular)
}
