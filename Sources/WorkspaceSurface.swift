import AppKit
import PaneChrome

/// Something a host can put on screen.
///
/// The whole point of the split: a surface knows how to draw itself into a rect and
/// nothing about where the rect is, and the host knows how to produce a rect and
/// nothing about what goes in it. That is what lets the sidebar stack two of them,
/// swap them, or show neither, without either surface knowing which of those is
/// happening.
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

    /// What the heading prints after the label, or nil for a surface whose size is
    /// not a fact worth stating.
    ///
    /// Design v3 §4.1 asks for it on Changes alone: how many files are waiting to
    /// be dealt with is the question that list answers, and how many files a
    /// repository contains is not a question anyone has. It also earns the heading
    /// its keep at the 48 pt minimum, where two rows under `CHANGES 41` is still a
    /// useful section and two rows under `CHANGES` is a broken one.
    var headingCount: Int? { get }

    /// The heading's right-aligned `+n −n`, or nil for a surface with no line
    /// counts to report. Design v5 §5, `CHANGED`'s own total; `FILES` answers
    /// nil the same way it answers nil to ``headingCount``, since a file tree
    /// counts paths and not lines.
    var headingTotals: (adds: Int, deletes: Int)? { get }

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
                .font: ChangesRowsView.font,
                .foregroundColor: ChangesSurface.nsColor(theme.inkFaint),
            ]
        ).draw(at: NSPoint(x: ChangesRowsView.inset, y: ChangesRowsView.textOrigin))
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
        let available = max(0, visible.width - ChangesRowsView.inset * 2)

        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.lineBreakMode = .byWordWrapping

        let message = NSAttributedString(
            string: "not a repository",
            attributes: [
                .font: ChangesRowsView.font,
                .foregroundColor: ChangesSurface.nsColor(theme.inkContext),
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
                    .font: ChangesRowsView.font,
                    .foregroundColor: ChangesSurface.nsColor(theme.inkFaint),
                    .paragraphStyle: head,
                ]
            )
        }
        // One line, always: the head truncation is what makes a long path fit, so
        // measuring it for wrapping would defeat its own line-break mode.
        let pathHeight = pathString == nil ? 0 : ChangesRowsView.font.ascender
            - ChangesRowsView.font.descender + 2

        // These views are flipped, so y grows downward and the message takes the
        // smaller y. Getting this backwards puts the path above the message,
        // which reads as a heading over an explanation rather than the other way
        // round, and it renders without complaint.
        let total = messageHeight + pathHeight
        let top = visible.midY - total / 2

        message.draw(with: NSRect(
            x: visible.minX + ChangesRowsView.inset,
            y: top,
            width: available,
            height: messageHeight
        ), options: [.usesLineFragmentOrigin])

        guard let pathString else { return }
        pathString.draw(with: NSRect(
            x: visible.minX + ChangesRowsView.inset,
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

    /// How many rows the surface below is showing, drawn after the label. Nil on a
    /// surface whose size is not worth stating. See ``WorkspaceSurface/headingCount``.
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
    /// nothing rather than `+0 −0`: see ``WorkspaceSurface/headingTotals``.
    ///
    /// Drawn in the same trailing slot ``anchorName`` used before design v5 moved
    /// the repository name to ``SidebarSessionHeaderView``; the two are never both
    /// non-nil on a shipping heading; where they would be, `totals` wins, since a
    /// `CHANGED` heading with something to total is the case this exists for.
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
        nsColor(theme.barBackground).setFill()
        bounds.fill()

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
                .foregroundColor: nsColor(theme.inkFaint),
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
                    .foregroundColor: nsColor(theme.inkFaint),
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
    private static let inset = ChangesRowsView.inset
    /// 6 pt between the label and its count, per design v3 §4.1.
    private static let countGap: Double = 6
    private static let labelFont = NSFont.systemFont(ofSize: 10, weight: .bold)
    private static let anchorFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let totalsFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    /// .06em at 10 pt, design v5 §5, which is what makes caps read as a label
    /// rather than shouting.
    private static let tracking: Double = 10 * 0.06
}
