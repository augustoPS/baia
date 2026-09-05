import AppKit
import BaiaSettings
import PaneChrome

// The `WorkspaceSurface` protocol stood here until Task 6, and it names why the
// file keeps this name rather than one describing only what is left in it.
//
// It let the sidebar host swap what it showed, or show nothing, without either
// side knowing which of those was happening: a surface drew itself into a rect
// with no idea where the rect came from, and the host produced a rect with no
// idea what would fill it. That seam earned its keep while the column could
// hold more than one surface — CHANGES above FILES, stacked — because the host's
// fan-outs (`theme`, `backgroundOpacity`, `resolvedChrome`, `fillMaterial`) ran
// over a list of them without caring which conformer sat at which index.
//
// The owner's 2026-08-12 ruling removed CHANGES, and `FilesSurface` has been
// the column's only surface since. A protocol satisfied by exactly one
// conformer is not a seam any more, it is a detour: `SidebarHost` held
// `sections: [Section]` and cast back to `FilesSurface` everywhere it needed
// the type it actually had, `AppDelegate.surfaces(for:tree:)` boxed a concrete
// `FilesSurface` into `[any WorkspaceSurface]` on the way out, and
// `refreshSidebar` looped a one-element array to reach the single conformer
// inside it. Task 6 removed the protocol, its list, and every cast built to see
// through it: `SidebarHost.files` is `FilesSurface?`, `AppDelegate.surfaces`
// returns `FilesSurface?`, and `FilesSurface` itself declares no protocol
// conformance any more, keeping every property this file's remaining type,
// ``SurfaceMessage``, still reads it for. `SurfaceTitleView` stood below it
// until 2026-09-04 as a sample the settings preview themed; that preview now
// builds the real `SidebarHost`, which draws no heading, so the type went as
// its own doc comment said it would.

/// What a surface draws when it has no rows.
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

    /// A pane with no anchor at all: nothing to list, nothing to walk, and the one
    /// state in this column that draws a message instead of rows.
    ///
    /// **The `git init` button stood here for one commit and moved out on the
    /// owner's 2026-08-12 ruling, which is a removal rather than a demotion.**
    /// The ruling puts the offer on the walked tree, and the reason it was here
    /// first is that `hasRoot` was assigned `anchor != nil`: a plain directory
    /// resolves an anchor, so it reached this state only when nothing resolved.
    /// It is not moved here as well, and keeping it would have been the easy
    /// answer, because this state cannot be resolved by that command. What lands
    /// here is a pane whose anchor is gone — a working directory deleted
    /// underneath the shell — and `git init` in a directory that no longer exists
    /// fails at the shell. An offer that cannot succeed is worse than no offer:
    /// it reads as the app not knowing what it is looking at, and it costs the
    /// owner a command and an error to find that out.
    ///
    /// So this state goes back to what it was before that commit, which is what
    /// it should say: this pane is pointed at nothing, and here is where.
    /// ``FilesSurface/Listing/absent`` is the case, and
    /// ``FilesSurface/Listing/directory`` is the one that gets `InitOfferView`.
    ///
    /// **The distinction design v3 drew is untouched.** "not a repository" and
    /// "no changes" remain different answers in different positions and different
    /// inks.
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

    /// What the offer says, and it says exactly what it will do.
    ///
    /// **The command itself is the caption, which is the safety argument made
    /// visible.** kero offers "Initialize Repository", a sentence about an effect;
    /// this offers the literal `git init` that will be put on the prompt, so what
    /// the owner reads before clicking and what they read after clicking are the
    /// same eight characters. A caption that named the effect instead would be a
    /// promise the owner has to trust; this one is a quotation they can check.
    ///
    /// Read by `InitOfferView`, which draws it, and by `AppDelegate.offerInit(of:)`,
    /// which sends it. One constant for both is what keeps the two the same
    /// string: a caption and a command that were spelled separately could drift,
    /// and the whole argument is that they cannot.
    static let initCaption = "git init"
}
