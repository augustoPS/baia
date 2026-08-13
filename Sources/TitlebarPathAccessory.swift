import AppKit
import PaneChrome

/// The folder icon and the working directory, drawn in the titlebar band.
///
/// **The owner's 2026-08-13 ruling: "reduce the titlebar height, remove the
/// folder name, keep a folder icon and the path."** All three shipped, the
/// height last and in a separate change — see
/// ``WorkspaceWindowController/titlebarBandHeight`` and the note below.
///
/// ## Why an accessory rather than the title line
///
/// The band has two text slots it stacks for free, and the obvious spelling of
/// this change is to leave the path in `window.subtitle` and put nothing in
/// `window.title`. That is half of what happens: the path *is* still the
/// subtitle, written by `AppDelegate` from
/// ``TerminalPaneController/windowTitle``. What the subtitle cannot do is carry a
/// glyph. An SF Symbol in a string is a font substitution the theme cannot tint,
/// and `NSWindow.subtitle` is a `String` with no attributed spelling, so the icon
/// has to be a view. A `.leading` titlebar accessory is the one place a view can
/// sit beside the title text without inventing a toolbar item.
///
/// **Measured to cost no height, which is the only reason it is allowed.** With
/// the `.unifiedCompact` toolbar this window carried at the time, the band was
/// 40.0 pt with no accessory, 40.0 pt with a `.leading` accessory, and 40.0 pt
/// with a `.right` one. A `.bottom` accessory is the trap: it measures **76.0 pt
/// regardless of the height its view asks for** — 0, 12, 20 and 28 all produced
/// 76.0 — so it grows the band it was reached for to shrink. Nothing here is
/// `.bottom`. The accessory costing nothing is what survived the toolbar's
/// removal unchanged: at 32 pt it still adds no height.
///
/// ## Why the band is 32 pt, having been 40
///
/// This section said the height could not be had, and it was right about the
/// window it described and wrong within the day. The band's height was the
/// toolbar's: `.unifiedCompact` is 40.0 pt, `.unified` is 52.0 pt, and **no
/// toolbar at all is 32.0 pt**. Hiding the title bought nothing — a compact
/// toolbar with the title hidden still measured 40.0 pt — and the accessory
/// route above cannot shrink it either. The only lever was removing the toolbar,
/// and that read as trading the band's *material* for 8 pt, because
/// `Diagnostics/titlebar-toolbar` had measured the toolbar as the thing that
/// gives a bare titled window its material on macOS 26.
///
/// **What that reasoning missed is that the window had stopped being bare.**
/// The 2026-08-12 band/column merge put the band's glass in
/// ``SidebarHost/bandGlass``, inside `contentView`, so the material no longer
/// comes from the toolbar at all. Removing it on 2026-08-13 took the band to
/// 32.0 pt and left its appearance where it was: measured at x=700 down the
/// band, mean 0.1845 with the toolbar against 0.1839 without over the desktop,
/// and 0.5555 against 0.5511 over a white window placed behind the workspace.
/// The toolbar was contributing nothing the band still needed.
/// ``WorkspaceWindowController``'s `init` carries the full table.
///
/// The trade was real when it was written. It stopped being a trade when the
/// glass moved, and the eight points were then free.
///
/// ## Why an SF Symbol rather than `NSWorkspace.icon(forFile:)`
///
/// Owner's ruling, and the code agrees with it twice over. Every mark this app
/// draws is a glyph in theme ink — the sidebar's disclosure chevrons, the row
/// status letters, the capsule's segments — and a full-colour system folder icon
/// would be the one piece of foreign artwork in a window that otherwise renders
/// entirely in the terminal theme's palette. It is also the only element that
/// would not follow a theme change: `AppDelegate.settingsDidChange()` repaints
/// every surface from ``PaneTheme``, and a system icon has nothing to repaint.
@MainActor
final class TitlebarPathAccessory: NSTitlebarAccessoryViewController {
    /// The theme the icon and the path are inked from.
    ///
    /// Assigned rather than read, for the reason ``WorkspaceWindowController``'s
    /// initialiser states about its own chrome: a view built in one theme and
    /// corrected on the next settings change shows one frame of the wrong
    /// colours. The guard is ``SidebarHost/theme``'s, and for its reason —
    /// `AppDelegate` writes this unconditionally on every settings announcement,
    /// which under the design panel is once per control event.
    var theme: PaneTheme {
        didSet {
            guard theme != oldValue else { return }
            applyTheme()
        }
    }

    /// The working directory, already tilde-abbreviated and shortened by
    /// ``DisplayPath`` at the pane that resolved it. Shortened there rather than
    /// here because the same string is the window's subtitle, and two spellings
    /// of one directory in one band is the duplication this whole line of
    /// rulings has been removing.
    var path: String = "" {
        didSet {
            guard path != oldValue else { return }
            label.stringValue = path
        }
    }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(theme: PaneTheme) {
        self.theme = theme
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func loadView() {
        // `folder` rather than `folder.fill`. The outline weight is what the rest
        // of this band is: the title text beside it, the traffic lights' own
        // strokes, and every glyph the sidebar draws are all line weight, and a
        // filled slab at 13 pt reads heavier than the path it is labelling — it
        // becomes the thing the eye lands on first, which inverts what this
        // accessory is for. The fill variant is also the one that needs a second
        // colour to stay legible; the outline carries at one ink, which is the
        // ink this theme has.
        //
        // A symbol configuration rather than a resize: an SF Symbol scaled as a
        // bitmap loses the optical alignment it was drawn with, and `pointSize`
        // is what makes it sit on the text baseline beside a 13 pt label.
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Working directory")?
            .withSymbolConfiguration(.init(pointSize: Self.pointSize, weight: .regular))
        icon.setContentHuggingPriority(.required, for: .horizontal)

        label.font = .systemFont(ofSize: Self.pointSize)
        // The band is a fixed width the window controls and the path is not, so
        // the head is what goes: a path is informative at its end, which is the
        // same rule `SurfaceMessage.drawAbsent` and the shell prompt already
        // follow for the same string.
        label.lineBreakMode = .byTruncatingHead
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = Self.spacing
        // `.centerY` rather than `.firstBaseline`: the icon is an image and has
        // no baseline to share with the label, so baseline alignment resolves to
        // the view's bottom and hangs the folder below the text.
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Self.leadingInset, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // **The accessory's `view` needs a real height or AppKit gives it none,
        // and a zero-height accessory renders as nothing at all.** That is what
        // shipped in the first draft of this file: the band came up empty, with
        // the traffic lights and no icon and no path, because a bare
        // `NSStackView` handed over as `view` sized itself to zero. The
        // container carries the height explicitly and the stack is pinned inside
        // it, which is the arrangement that renders.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        view = container
        applyTheme()
    }

    /// Inks both halves from the theme.
    ///
    /// ``PaneTheme/inkFaint`` is the tier, and it is the tier by name rather than
    /// by taste: its own documentation calls it "Tier 4 text, quieter: the
    /// working directory", and the sidebar draws this same class of string in it
    /// (`WorkspaceSurface`, `SurfaceMessage.drawAbsent`'s path line). The icon
    /// takes the identical ink rather than a stronger one, because it is a label
    /// for the path and not a control: two weights here would say one of them is
    /// clickable.
    ///
    /// `contentTintColor` rather than a template image and a fill, which is what
    /// makes the symbol follow this assignment at all — an `NSImageView` renders
    /// a symbol as a template and takes its tint from this property.
    private func applyTheme() {
        let ink = SidebarRowMetrics.nsColor(theme.inkFaint)
        icon.contentTintColor = ink
        label.textColor = ink
    }

    /// 13 pt, which is `NSFont.systemFontSize` and what the titlebar's own title
    /// renders at. The band is the platform's surface and this is the one place
    /// in the app that does *not* use the 11 pt sidebar scale: a path drawn at
    /// the column's size inside the system band reads as something pasted into
    /// it.
    private static let pointSize: Double = 13

    /// 5 pt between the icon and the path: the gap that reads as one label
    /// rather than two elements. The sidebar's own icon-to-text gap is the
    /// nearest precedent and this is it at the larger size.
    private static let spacing: Double = 5

    /// 8 pt in from where AppKit places a leading accessory, which is what puts
    /// the icon on the same left margin the traffic lights leave behind rather
    /// than hard against them.
    private static let leadingInset: Double = 8

    /// The accessory's own height, and it is not the band's: a `.leading`
    /// accessory is laid out inside the band's title row, so asking for the whole
    /// band makes it taller than the row it sits in. 18 pt is the 13 pt label's
    /// line height with the two points the symbol needs around it.
    ///
    /// **Independent of the band, which the toolbar's removal proved rather than
    /// assumed.** The band went 40 to 32 on 2026-08-13 and this stayed 18; the
    /// row it sits in re-centred with it, measured on the live window at a
    /// mid-Y of 16.0 pt from the frame top against the traffic lights' own 16.0.
    private static let height: Double = 18

    /// A starting width, not a limit. The label truncates its head inside
    /// whatever the band gives it, and the leading accessory is free to be
    /// narrower than this when the window is; it exists because the container
    /// needs a non-zero frame at construction for the same reason ``height``
    /// does.
    private static let width: Double = 360
}
