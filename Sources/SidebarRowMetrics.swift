import AppKit
import PaneChrome

/// The sidebar's row vocabulary: one set of metrics every row in the column is
/// placed by, and the bridge from a theme's ``PaneChrome/RGB`` to an `NSColor`.
///
/// **Both used to live on `ChangesSurface`/`ChangesRowsView`, and outlived
/// them.** The sidebar's CHANGES section was removed on the owner's 2026-08-12
/// ruling (the capsule's changes card already lists the changed files and hands
/// each one to a diff split, so the column was a second copy of the same list in
/// the same window). The section's rendering went with it; these did not,
/// because they were never the changes list's own: the file tree, the session
/// header and the action row each read them, and the point of a shared row
/// metric is that a row is a row wherever it is drawn. Leaving them behind a
/// type named for a retired section would have made every call site read as a
/// dependency on something that no longer exists.
///
/// Nothing here is new. Every constant is the value that shipped, moved
/// verbatim, so the column draws exactly what it drew before the section left.
@MainActor
enum SidebarRowMetrics {
    /// The row font, and the reason a character advance is a number at all.
    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    /// The advance of one character, which is a number only because the font is
    /// monospaced. Every width budget in the sidebar is derived from it.
    ///
    /// Measured rather than written down as 6.62: the constant is what the font
    /// happens to report at size 11, and a font or size change has to move the
    /// budget with it.
    static let advance = ("0" as NSString).size(withAttributes: [.font: font]).width

    /// Design v5 §5: `--h-list-row`. Was 18 under design v3's two-column marker.
    static let rowHeight: Double = 24

    /// Cap-centred in the row: (24 + 7.8) / 2, where 7.8 is the cap height.
    static let rowBaseline: Double = 16

    /// Where a row's text starts, so that its baseline lands on ``rowBaseline``.
    ///
    /// The same rule the footer follows with `PaneStatusBarMetrics.baselineFromTop`:
    /// one baseline for everything on the line, rather than each string placed by
    /// its own idea of centre. Two strings centred independently sit a fraction of
    /// a point apart, which does not read as a difference, it reads as a mistake.
    static let textOrigin = rowBaseline - Double(font.ascender)

    /// One inset for the tree, the heading above it, the session header and the
    /// action row. The tree used to use 10, so it sat 2 pt out from everything
    /// else. Design v3 §8/03.
    static let inset: Double = 12

    /// Design v5 §5's row radius, shared with both palette rows.
    static let rowRadius: Double = 6

    /// A theme colour as AppKit wants it.
    ///
    /// sRGB explicitly, never `NSColor(red:green:blue:)`, which is calibrated
    /// and would shift every value the theme carries.
    static func nsColor(_ rgb: RGB, alpha: Double = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat(rgb.red),
            green: CGFloat(rgb.green),
            blue: CGFloat(rgb.blue),
            alpha: CGFloat(alpha)
        )
    }
}
