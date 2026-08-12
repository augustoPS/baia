import AppKit
import PaneChrome

/// Something a host can put on screen.
///
/// The whole point of the split: a surface knows how to draw itself into a rect and
/// nothing about where the rect is, and the host knows how to produce a rect and
/// nothing about what goes in it. That is what lets the sidebar show a surface,
/// swap it, or show none, without the surface knowing which of those is
/// happening. It stacked two until the owner's 2026-08-12 ruling removed the
/// CHANGES section, and the host's arithmetic still stacks any number.
@MainActor
protocol WorkspaceSurface: AnyObject {
    /// What the host installs. Never added to a pane's view hierarchy: a view
    /// inside a pane that takes first responder disables every ghostty binding in
    /// that pane, silently.
    var view: NSView { get }

    /// Drawn by the host's own chrome, so a surface does not each draw its own
    /// heading in its own way.
    var title: String { get }

    var theme: PaneTheme { get set }

    // `headingCount` and `headingTotals` stood here until 2026-08-12. Design v3
    // §4.1 asked for a count on Changes alone and design v5 §5 gave that heading
    // its `+n −n`; `FILES` answered nil to both, because a file tree counts paths
    // rather than lines and how many files a repository contains is not a
    // question anyone has. The owner's ruling that day removed the CHANGES
    // section, which left every surface in the column answering nil forever, so
    // the two requirements went with the section that was the reason for them.
    // `SurfaceTitleView` keeps `count` and `totals`: `SettingsPreviewColumn`
    // still sets them directly to show how a heading is themed.

    /// What the terminal's own background is drawn at, so a surface is filled with
    /// the same material a pane is.
    ///
    /// Design v3 §1: the sidebar is another compartment rather than a panel, so it
    /// takes the work's material rather than ``PaneTheme/panelBackground``, which
    /// keeps the surfaces that float. A number rather than a colour because the
    /// theme cannot know it: it comes from `backgroundOpacity`, which is a setting
    /// and reaches ghostty as a config override.
    var backgroundOpacity: Double { get set }

    /// What the surface's own scroll background draws.
    ///
    /// `theme.background` at ``backgroundOpacity`` on both flat and glass now,
    /// exactly what Plan 1 shipped either way.
    ///
    /// **Task 2 (untint the chrome) superseded Task 5's original clause here.**
    /// Glass used to swap in the material set's own `fillSidebar`, scaled by
    /// ``backgroundOpacity`` — an `rgba` fill on what the task calls the
    /// sidebar's glass path, even though this surface has no
    /// `NSGlassEffectView` of its own the way the footer, palette and popover
    /// do. Task 2 drops that fill along with theirs. ``resolvedChrome`` stays
    /// on the protocol and still triggers a repaint on change, because a
    /// caller assigning it while the app is configured for glass is real
    /// (a theme or opacity edit has to reach the screen), even though flat
    /// and glass now paint identically.
    var resolvedChrome: ResolvedChrome { get set }
}

/// What a section draws when it has no rows.
///
/// Design v3 §6. **"Nothing changed" and "not a repository" are different answers
/// and were drawn identically**, character for character, at the same position in
/// the same ink: capture 12. A clean tree is not an error and should read as the
/// list's own first line, which is what it is. A pane anchored to a plain
/// directory is a different kind of answer, so position and ink both say so, and
/// the path answers the question the message provokes.
@MainActor
enum SurfaceMessage {
    /// A list with nothing in it. First row position, lowercase, faint.
    static func drawEmpty(_ text: String, in view: NSView, theme: PaneTheme) {
        NSAttributedString(
            string: text,
            attributes: [
                .font: SidebarRowMetrics.font,
                .foregroundColor: SidebarRowMetrics.nsColor(theme.inkFaint),
            ]
        ).draw(at: NSPoint(x: SidebarRowMetrics.inset, y: SidebarRowMetrics.textOrigin))
    }

    /// A pane that is not in a repository at all, with where it is instead.
    ///
    /// Centred in what the clip view can show rather than in the document view,
    /// which is as tall as its rows and would put the message off screen in a
    /// section that has been scrolled.
    /// Both lines are drawn into a bounded rect rather than at a point, and that
    /// is the whole of the fix.
    ///
    /// Drawn at a point, neither line could be told it had run out of column: at
    /// the 120 pt width floor the message rendered as "not a r" and the path as
    /// "~/Pr", each running under the divider with no ellipsis and nothing to say
    /// it had been cut. A centred message that clips is a message nobody can
    /// read, and it is the floor rather than an edge case, because
    /// `SidebarHost.minimumWidth` is 120.
    ///
    /// The message wraps, because it is two words and both matter. The path
    /// truncates at its head, keeping the tail, which is the treatment the status
    /// bar already gives a path for the same reason: a path is informative at its
    /// end. Rotating the text was considered and dropped. It preserves every
    /// character and trades a horizontal clip for a vertical one, and the string
    /// it would break is the path: a deep one needs 360 pt of vertical run against
    /// a section whose own floor is 48 pt.
    static func drawAbsent(path: String?, in view: NSView, theme: PaneTheme) {
        let visible = view.visibleRect
        let available = max(0, visible.width - SidebarRowMetrics.inset * 2)

        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.lineBreakMode = .byWordWrapping

        let message = NSAttributedString(
            string: "not a repository",
            attributes: [
                .font: SidebarRowMetrics.font,
                .foregroundColor: SidebarRowMetrics.nsColor(theme.inkContext),
                .paragraphStyle: centred,
            ]
        )
        let messageHeight = message.boundingRect(
            with: NSSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        ).height

        let pathString = path.map { (path: String) -> NSAttributedString in
            let head = NSMutableParagraphStyle()
            head.alignment = .center
            head.lineBreakMode = .byTruncatingHead
            return NSAttributedString(
                string: (path as NSString).abbreviatingWithTildeInPath,
                attributes: [
                    .font: SidebarRowMetrics.font,
                    .foregroundColor: SidebarRowMetrics.nsColor(theme.inkFaint),
                    .paragraphStyle: head,
                ]
            )
        }
        // One line, always: the head truncation is what makes a long path fit, so
        // measuring it for wrapping would defeat its own line-break mode.
        let pathHeight = pathString == nil ? 0 : SidebarRowMetrics.font.ascender
            - SidebarRowMetrics.font.descender + 2

        // These views are flipped, so y grows downward and the message takes the
        // smaller y. Getting this backwards puts the path above the message,
        // which reads as a heading over an explanation rather than the other way
        // round, and it renders without complaint.
        let total = messageHeight + pathHeight
        let top = visible.midY - total / 2

        message.draw(with: NSRect(
            x: visible.minX + SidebarRowMetrics.inset,
            y: top,
            width: available,
            height: messageHeight
        ), options: [.usesLineFragmentOrigin])

        guard let pathString else { return }
        pathString.draw(with: NSRect(
            x: visible.minX + SidebarRowMetrics.inset,
            y: top + messageHeight,
            width: available,
            height: pathHeight
        ), options: [.usesLineFragmentOrigin])
    }
}

/// The heading a host draws above whatever surface it is holding.
///
/// Drawn by the host and not by the surface, so two surfaces cannot each invent a
/// heading in their own weight and inset. ``WorkspaceSurface/title`` promises this
/// exists; a promise with nothing drawing it is the design prose running ahead of
/// the code, which this project has already been bitten by once.
@MainActor
final class SurfaceTitleView: NSView {
    var title: String = "" { didSet { needsDisplay = true } }
    var theme: PaneTheme = .darkPastel { didSet { needsDisplay = true } }

    /// Gates the glass branch of ``labelInk``. Pushed by `SidebarHost` the same
    /// way ``isWindowActive`` is: this view has no other way to hear that its
    /// column is now sitting over real glass.
    var resolvedChrome: ResolvedChrome = .flat { didSet { needsDisplay = true } }

    /// The brightest glass the spike actually measured, and the backdrop the
    /// caps label is graded against under glass.
    ///
    /// `Diagnostics/glass-backdrop/README.md` finding 6: a sidebar of untinted
    /// `regular` glass straddling a split bright/dark wallpaper sampled
    /// `#4b4b4b`, `#474747`, `#494949` and `#464646` over the bright half across
    /// two runs. This is the worst (brightest) of the four, so an ink that
    /// clears it clears every sample the finding took.
    ///
    /// **A constant because the view cannot ask.** What glass composites is the
    /// desktop, sampled by the window server, and neither this view nor any
    /// `NSGlassEffectView` API reports the result back — the spike needed a
    /// screen grab to read it at all. So the grading backdrop is the measured
    /// worst case rather than a live value, and it is spelled here, once, next
    /// to the finding that produced it.
    ///
    /// **The wash this paragraph used to qualify retired on 2026-08-08, and the
    /// sweep below is kept anyway.** `SidebarGlassWash` laid `theme.background`
    /// at `backgroundOpacity` over this glass, so the backdrop the label was
    /// judged against was not the bare glass finding 6 measured; the wash only
    /// ever *darkened* it, so contrast for light ink moved monotonically up.
    /// The owner's A/B against naked native glass retired that wash, which
    /// means **the top row of the table — `0 (bare)` — is now the shipped
    /// backdrop** rather than the conservative end of a knob. Every row below it
    /// is a measurement of a rendering this app no longer produces, and it stays
    /// because it is the evidence for the monotonicity claim: it is what says
    /// the retirement moved the label onto its *worst* backdrop and by how much.
    /// Nothing here is re-graded, because nothing measured was re-measured.
    ///
    /// Computed against finding 6's own measured samples, worst (brightest)
    /// half, both recorded runs, by the same `contrastRatio` arithmetic the
    /// table's other cells use — not read off a capture. The `#9e9e9e` column
    /// is **the probe's stand-in, not any ink this app draws** (see the README's
    /// finding 6a): it is kept because the original table was built on it and
    /// the correction is only legible beside it. `#898989` is the ink that
    /// actually ships without this repair, and it is worse throughout.
    ///
    /// | opacity | bare glass | stand-in `#9e9e9e` | `inkFaint` `#898989` | old literal `#bbbbbb` | `sectionHeaderInk` `#dcdcdc` |
    /// |---|---|---|---|---|---|
    /// | 0 (bare, shipped since 2026-08-08) | `#4b4b4b`–`#464646` | 3.26–3.52 | 2.49–2.69 | 4.54–4.92 | 6.34–6.85 |
    /// | 0.10 | `#464646`–`#414141` | 3.55–3.81 | 2.72–2.91 | 4.96–5.32 | 6.91–7.41 |
    /// | 0.42 (shipped until 2026-08-08) | `#343434`–`#313131` | 4.65–4.86 | 3.56–3.71 | 6.49–6.78 | 9.05–9.45 |
    /// | 0.85 | `#1c1c1c` | 6.34–6.40 | 4.85–4.89 | 8.85–8.92 | 12.34–12.44 |
    ///
    /// Two things the sweep says that the prose alone could not. **The repair is
    /// load-bearing at every row, and the retirement moved the shipped rendering
    /// to the worst of them**: the ink that ships without it (`#898989`) fails
    /// the 4.5:1 floor at every opacity up to and including the old 0.42, and
    /// only clears at 0.85 — a row nothing ever shipped at. The earlier reading
    /// — that at 0.42 the flat ink already passes — was an artifact of grading
    /// the stand-in rather than the real tier. Grading against the **bare**
    /// glass, as ``labelInk`` does, was the conservative end of a live knob when
    /// this was written; it is now simply the backdrop, which is why the repair
    /// survived the layer it was part of.
    ///
    /// Wallpaper caveat, unchanged: these rest on finding 6's samples, and a
    /// desktop brighter than anything that finding saw composites brighter than
    /// the top row. The probe's finding 6b measured exactly that and it is why
    /// this constant is recorded as owed rather than sufficient.
    /// **Still one reader, and the sidebar's other two inks deliberately do not
    /// join it.** The session header's and the action row's faint-tier strings
    /// sit in this same column over this same glass, so grading them here looks
    /// obvious; it was tried and reverted. On `.darkPastel` the repair fires on
    /// this backdrop — `inkFaint` scores 2.49:1 against `#4b4b4b` — and walks
    /// those inks from `#898989` to `#dcdcdc`, which would have moved a pixel on
    /// every glass launch with every design override nil. The caps label is
    /// different because it was *always* graded here, so nothing about it moved.
    /// See ``SidebarSessionHeaderView/labelInk`` for the open question that
    /// leaves behind.
    private static let measuredBrightGlass = RGB.eightBit(0x4B, 0x4B, 0x4B)

    /// The caps label's ink: ``PaneChrome/PaneTheme/inkFaint`` graded against
    /// whatever it is actually drawn on.
    ///
    /// Both branches call the same derivation and differ only in the backdrop
    /// they name, which is the point. Under flat the header sits on
    /// `theme.barBackground`, a colour the theme derives and already clears, so
    /// the repair is a no-op and flat renders byte-identically to what Plan 1
    /// shipped. Under glass it sits on sampled desktop, which the theme has
    /// never seen, and finding 6 measured the faint tier failing the 4.5:1 floor
    /// that 10 pt bold text is owed over the bright half.
    ///
    /// **Why a derivation and not the constant the finding names.** The spike's
    /// remedy reads "`#bbbbbb` or lighter", and that value shipped here as a
    /// literal. It passes on `.darkPastel` for a reason that does not generalise:
    /// `#bbbbbb` *is* that theme's own `foreground`. Against the other 484 themes
    /// in the catalog it is arbitrary, and on a light one it inverts — `#bbbbbb`
    /// on a white-backed palette is the near-invisible ink rather than the
    /// legible one, so the constant would have made the header *less* readable on
    /// exactly the themes it was supposed to protect.
    /// ``PaneChrome/PaneTheme/sectionHeaderInk(on:)`` asks the question the
    /// constant answered by accident: brighten the theme's own faint tier until
    /// it clears, on this backdrop, whatever the theme is.
    ///
    /// This reaches only the two caps-row draws below. Every other `inkFaint`
    /// reader in the sidebar (the session header, the action row's keycap, the
    /// file tree's disclosure chevron, both empty-state messages) is untouched,
    /// and the file rows beside this header measured 6.99:1 and never needed
    /// repairing — which is why the fix is one header's ink rather than the
    /// column's.
    /// **The repair is unconditional on glass, and it outlived the knob that
    /// could switch it off.** `chrome.bareGlass` suppressed it for the duration
    /// of the owner's 2026-08-08 A/B, so the naked material could be judged with
    /// none of this app's paint in front of it. That A/B retired the two washes
    /// and the knob with them; this repair is the one part of the hand-drawn
    /// layer it kept, and with the sidebar's wash gone it is *more* load-bearing
    /// than before. The wash only ever darkened the backdrop, and darkening
    /// moves contrast for light ink monotonically up — so the naked glass this
    /// now grades against is the brightest backdrop the label ever sits on, and
    /// the raw `inkFaint` measured 1.19:1 there.
    ///
    /// **The site and not the ratio, and the reason is
    /// that a ratio cannot say "glass only".**
    ///
    /// ``PaneChrome/PaneThemeAdjustments/sectionHeaderMinimumRatio`` was the
    /// obvious channel — pin it to 1:1, which every colour clears, and the chain
    /// returns its first link untouched. It was tried and it is wrong: the
    /// adjustments value is one object both branches below read, and on a light
    /// theme the repair fires against ``PaneChrome/PaneTheme/barBackground`` too,
    /// so a pinned ratio moves the **flat** label. `PaneThemeAdjustmentsTests`
    /// keeps that as a standing arm
    /// (`aPinnedRatioCannotExpressGlassOnlyBecauseFlatSharesTheDerivation`).
    ///
    /// Here the branch already exists and `resolvedChrome` is known, so the flat
    /// case is untouched by construction rather than by an argument about which
    /// backdrops happen to clear.
    private var labelInk: RGB {
        switch resolvedChrome {
        case .flat: theme.sectionHeaderInk(on: theme.barBackground)
        case .glass: theme.sectionHeaderInk(on: Self.measuredBrightGlass)
        }
    }

    /// How many rows the surface below is showing, drawn after the label. Nil on a
    /// surface whose size is not worth stating, which every surviving surface is:
    /// the one caller that answered a number was the changes list, retired with
    /// the section (owner ruling, 2026-08-12).
    var count: Int? { didSet { needsDisplay = true } }

    /// The repository the column is describing, drawn trailing.
    ///
    /// Design v3 §4.2. The same string in the same treatment appears in the
    /// focused pane's footer, and **that repetition is the connection** between
    /// the two: a connector drawn between two things that could simply agree is
    /// one more thing to keep in step. The host gives it to the first heading
    /// only, because in `both` the two sections are one repository and printing it
    /// twice would say there were two.
    var anchorName: String? { didSet { needsDisplay = true } }

    /// The right-aligned `+n −n`, mono 10pt, adds in ``PaneChrome/PaneTheme/staged``
    /// and deletes in ``PaneChrome/PaneTheme/alert`` (design v5 §5). Nil renders
    /// nothing rather than `+0 −0`.
    ///
    /// **Fed by nothing on a shipping heading since 2026-08-12.** The `CHANGED`
    /// heading was the case it existed for, and the owner's ruling that day
    /// removed that section along with the `headingTotals` requirement that
    /// pushed this value in. Kept, with ``count``, because `SettingsPreviewColumn`
    /// sets both directly and they are what carries theme colour into a heading's
    /// trailing half.
    ///
    /// Drawn in the same trailing slot ``anchorName`` used before design v5 moved
    /// the repository name to ``SidebarSessionHeaderView``; where both are set,
    /// `totals` wins.
    var totals: (adds: Int, deletes: Int)? { didSet { needsDisplay = true } }

    /// Gated the way the footer's focus frame is: an accent left bright on a
    /// window that is not key would compete with the window that is.
    var isWindowActive = true { didSet { needsDisplay = true } }

    /// How the split above this heading is being touched, drawn as 2 pt along the
    /// heading's own top edge.
    ///
    /// **Drawn here rather than by the grab strip**, so the mark lives inside the
    /// heading's fixed 28 pt and never in the layout: a strip that drew its own
    /// 2 pt would be a control that changes height, which in this column resizes
    /// the panes beside it. Design v3 §4.3.
    var split: DividerGrabView.Touch = .rest { didSet { needsDisplay = true } }

    override func draw(_: NSRect) {
        // Flat draws its own opaque fill, unchanged from what Plan 1 shipped.
        // Glass draws no fill at all (Task 3, following Task 2's own pattern —
        // see `PaneStatusBarView.draw(_:)`): this heading sits directly over
        // `SidebarHost.glassBacking`, and a fill here would paint an opaque
        // band across it, the HIG violation this task exists to close. The
        // label's own ink already branches on ``resolvedChrome`` below
        // (``labelInk``); only the fill was still unconditional.
        switch resolvedChrome {
        case .flat:
            nsColor(theme.barBackground).setFill()
            bounds.fill()
        case .glass:
            break
        }

        // A hairline along the bottom, the same one the tree draws between panes,
        // so the heading is separated by the divider vocabulary already in use
        // rather than by a rule of its own.
        //
        // **This view is not flipped**, so `y: 0` is its own bottom edge and the
        // line faces the rows it labels. The same unflipped geometry is why every
        // baseline below is measured up from the bottom.
        nsColor(theme.hairline).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        // The split's reply, on the top edge, which in an unflipped view is
        // `maxY`. Nothing at rest: the body meeting this heading is already the
        // boundary, and what an undiscoverable control needs is an answer on
        // approach rather than a permanent line.
        switch split {
        case .rest:
            break
        case .hover:
            nsColor(theme.background.blended(with: theme.foreground, fraction: 0.30)).setFill()
            NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2).fill()
        case .drag:
            nsColor(theme.inkFocus).setFill()
            NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2).fill()
        }

        // Caps and tracking make the label a label rather than a title, so it stops
        // competing with the row text below it at the same size. Weight 700 at
        // 10 pt, tertiary ink: design v5 §5 (previously mono 11 pt regular,
        // secondary ink, per design v3 §4.1).
        let label = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: Self.labelFont,
                .foregroundColor: nsColor(labelInk),
                .kern: Self.tracking,
            ]
        )
        var x = Self.inset
        label.draw(at: NSPoint(x: x, y: baseline(for: Self.labelFont)))
        x += label.size().width + Self.countGap

        if let count {
            NSAttributedString(
                string: String(count),
                attributes: [
                    .font: Self.labelFont,
                    .foregroundColor: nsColor(labelInk),
                ]
            ).draw(at: NSPoint(x: x, y: baseline(for: Self.labelFont)))
            x += Double(String(count).count) * Self.labelFont.maximumAdvancement.width
        }

        if let totals {
            let run = NSMutableAttributedString()
            if totals.adds > 0 {
                run.append(NSAttributedString(
                    string: "+\(totals.adds)",
                    attributes: [.font: Self.totalsFont, .foregroundColor: nsColor(theme.staged)]
                ))
            }
            if totals.deletes > 0 {
                if run.length > 0 {
                    run.append(NSAttributedString(string: " ", attributes: [.font: Self.totalsFont]))
                }
                run.append(NSAttributedString(
                    string: "−\(totals.deletes)",
                    attributes: [.font: Self.totalsFont, .foregroundColor: nsColor(theme.alert)]
                ))
            }
            guard run.length > 0 else { return }
            let width = run.size().width
            let start = bounds.width - Self.inset - width
            guard start > x + Self.countGap else { return }
            run.draw(at: NSPoint(x: start, y: baseline(for: Self.totalsFont)))
            return
        }

        guard let anchorName else { return }
        let anchor = NSAttributedString(
            string: anchorName,
            attributes: [
                .font: Self.anchorFont,
                .foregroundColor: nsColor(isWindowActive ? theme.inkFocus : theme.foreground),
            ]
        )
        // Dropped rather than truncated when the label leaves it no room. The
        // footer names the same repository one line below, so a column too narrow
        // to hold both loses the copy rather than the fact.
        let width = anchor.size().width
        let start = bounds.width - Self.inset - width
        guard start > x + Self.countGap else { return }
        anchor.draw(at: NSPoint(x: start, y: baseline(for: Self.anchorFont)))
    }

    /// Where to draw so that `font` lands its baseline on the heading's, measured
    /// from the top in an unflipped view.
    ///
    /// One baseline for both fonts. The mono label and the semibold anchor have
    /// different descenders, so two strings each centred in the height sit a
    /// fraction of a point apart, which does not read as a difference. It reads as
    /// a mistake. Replaces a centring whose `+ 1` was there for the unflipped
    /// geometry rather than for any typographic reason.
    private func baseline(for font: NSFont) -> Double {
        bounds.height - Self.baselineFromTop + Double(font.descender)
    }

    private func nsColor(_ rgb: RGB) -> NSColor {
        NSColor(
            srgbRed: CGFloat(rgb.red),
            green: CGFloat(rgb.green),
            blue: CGFloat(rgb.blue),
            alpha: 1
        )
    }

    /// Fixed, and deliberately not a function of anything. A heading whose height
    /// depended on state would resize the surface under it, and in the sidebar that
    /// would resize the panes beside it.
    static let height: Double = 28

    /// Cap-centred in the height: the label, the count and the anchor all sit on
    /// this line whatever font they are in.
    private static let baselineFromTop: Double = 18
    private static let inset = SidebarRowMetrics.inset
    /// 6 pt between the label and its count, per design v3 §4.1.
    private static let countGap: Double = 6
    private static let labelFont = NSFont.systemFont(ofSize: 10, weight: .bold)
    private static let anchorFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let totalsFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    /// .06em at 10 pt, design v5 §5, which is what makes caps read as a label
    /// rather than shouting.
    private static let tracking: Double = 10 * 0.06
}
