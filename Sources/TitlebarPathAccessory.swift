import AppKit
import PaneChrome

/// The folder icon and the working directory, drawn in the titlebar band.
///
/// **The owner's 2026-08-13 ruling: "reduce the titlebar height, remove the
/// folder name, keep a folder icon and the path."** Two of those three shipped
/// here. The height did not, and the reason is measured rather than assumed —
/// see ``WorkspaceWindowController/titlebarBandHeight`` and the note below.
///
/// ## Why an accessory rather than the title line
///
/// The band already has two text slots the toolbar stacks for free, and the
/// obvious spelling of this change is to leave the path in `window.subtitle` and
/// put nothing in `window.title`. That is half of what happens: the path *is*
/// still the subtitle, written by `AppDelegate` from
/// ``TerminalPaneController/windowTitle``. What the subtitle cannot do is carry a
/// glyph. An SF Symbol in a string is a font substitution the theme cannot tint,
/// and `NSWindow.subtitle` is a `String` with no attributed spelling, so the icon
/// has to be a view. A `.leading` titlebar accessory is the one place a view can
/// sit beside the title text without inventing a toolbar item.
///
/// **Measured to cost no height, which is the only reason it is allowed.** With
/// the `.unifiedCompact` toolbar this window carries, the band is 40.0 pt with no
/// accessory, 40.0 pt with a `.leading` accessory, and 40.0 pt with a `.right`
/// one. A `.bottom` accessory is the trap: it measures **76.0 pt regardless of
/// the height its view asks for** — 0, 12, 20 and 28 all produced 76.0 — so it
/// grows the band it was reached for to shrink. Nothing here is `.bottom`.
///
/// ## Why the band is still 40 pt
///
/// The owner asked for less, and it is not buildable without giving up something
/// they did not authorise. The band's height is the toolbar's: `.unifiedCompact`
/// is 40.0 pt, `.unified` is 52.0 pt, and **no toolbar at all is 32.0 pt**.
/// Hiding the title buys nothing — a compact toolbar with the title hidden still
/// measures 40.0 pt — and the accessory route measured above cannot shrink it
/// either. The only lever is removing the toolbar, and
/// `Diagnostics/titlebar-toolbar` measured the toolbar as the thing that gives
/// this window its titlebar *material* on macOS 26: without it the strip reads
/// through to whatever is behind the window and varies down its height, and with
/// it the band is one flat neutral. Trading the material for 8 pt is a different
/// change than the one that was asked for, so the toolbar stays and the band
/// stays 40 pt.
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

    /// The accessory's own height, and it is not the band's 40 pt: a `.leading`
    /// accessory is laid out inside the band's title row, so asking for the whole
    /// band makes it taller than the row it sits in. 18 pt is the 13 pt label's
    /// line height with the two points the symbol needs around it.
    private static let height: Double = 18

    /// A starting width, not a limit. The label truncates its head inside
    /// whatever the band gives it, and the leading accessory is free to be
    /// narrower than this when the window is; it exists because the container
    /// needs a non-zero frame at construction for the same reason ``height``
    /// does.
    private static let width: Double = 360
}
