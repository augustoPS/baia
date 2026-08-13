import AppKit
import BaiaSettings
import PaneChrome
import WorkspaceLayout

/// A connection to the window server, as `CGSDefaultConnectionForThread` returns
/// one. Opaque on purpose: nothing here inspects it, it is obtained and handed
/// straight back to ``CGSSetWindowBackgroundBlurRadius(_:_:_:)``.
private typealias CGSConnectionID = UInt32

/// **Private Apple SPI.** Not in any public SDK header, not covered by any
/// compatibility promise, and reached here by `@_silgen_name` because there is
/// no import that declares it.
///
/// There is no public API for this. `NSVisualEffectView` and `NSGlassEffectView`
/// blur what is behind a *view inside this process*; nothing in AppKit blurs
/// what the compositor has behind the window itself, which is the only thing
/// that can frost the desktop showing through a translucent terminal. Every
/// macOS terminal that offers the feature uses this same pair of symbols:
/// **ghostty** (`ghostty_set_window_background_blur` in
/// `src/apprt/embedded.zig`, which is the call this file mirrors), **iTerm2**,
/// and **Alacritty**.
///
/// **App Store implication: an app calling this cannot ship on the Mac App
/// Store**, which rejects private API use. baia is not an App Store app — it is
/// built by `make install` into `/Applications` and distributed to nobody — so
/// the cost is one baia does not pay. It is worth naming that the vendored
/// `libghostty-spm` checkout under `upstream/` patches this exact call *out* of
/// ghostty for that reason (`Patches/ghostty/0004-ios-fixes.sh`, "Disable
/// private window blur API (App Store compliance)"), which is precisely why
/// baia has to make the call itself: the engine it embeds no longer will.
///
/// **Failure is silent and harmless.** The returned `CGError` is discarded at
/// the one call site. If a future macOS drops the symbol the process fails to
/// launch rather than misbehaving, which is loud and immediate; if it keeps the
/// symbol and refuses the request, the window simply renders unblurred and
/// everything else about it is untouched. The worst case is no blur, never a
/// crash and never a wrong pixel elsewhere.
@_silgen_name("CGSDefaultConnectionForThread")
private func CGSDefaultConnectionForThread() -> CGSConnectionID

/// **Private Apple SPI.** See ``CGSDefaultConnectionForThread()`` directly
/// above for what that means here, who else relies on it, and why it is safe to
/// ignore what it returns.
///
/// The signature mirrors ghostty's own `extern "c" fn
/// CGSSetWindowBackgroundBlurRadius(*anyopaque, usize, c_int) i32`, not matches
/// it literally: the connection is narrowed to the `UInt32` CGS actually uses in
/// place of Zig's generic `*anyopaque`, and the radius is widened to `Int` in
/// place of `c_int`. The window is identified by `NSWindow.windowNumber` and the
/// radius is in points. Radius `0` removes the blur, which is what makes this
/// reversible on a live window.
@_silgen_name("CGSSetWindowBackgroundBlurRadius")
@discardableResult
private func CGSSetWindowBackgroundBlurRadius(
    _ connection: CGSConnectionID,
    _ windowNumber: Int,
    _ radius: Int
) -> CGError

// **`TitlebarGlassBacking` stood here until 2026-08-12, and the band's glass
// moved into ``SidebarHost`` with it.**
//
// It was an `NSGlassEffectView` parented in the window's *frame view*
// (`contentView.superview`), because the band sits above `contentView` and no
// public API hands it over. That parent is what `Diagnostics/titlebar-merge`
// measured the cost of: a plane in the frame view and a plane in `contentView`
// are two hierarchies, `NSGlassEffectContainerView` merges only its own
// subviews, and the probe's arm 2 established that no container can span the
// split. Two planes sampling separately is what the owner saw as a seam, and
// arm 1 measured it at 34.33 luminance units against a 2.00 threshold.
//
// So the band's plane now lives in `contentView` beside the column's, where a
// container can reach both. ``SidebarHost/bandGlass`` is the view that replaced
// this one, and ``WorkspaceWindowController/applyTitlebarGlass()`` carries what
// this controller still owns: the style mask, the flag that stops the system
// slab, and the tint the design panel points at the titlebar surface.

// **The titlebar's glass wash was here, and it retired on 2026-08-08.**
//
// `TitlebarGlassWash` laid `theme.background` at `backgroundOpacity` over
// ``TitlebarGlassBacking``, the sidebar wash's twin one surface over, so the
// band dimmed with the wells. Both retired in the same stroke and for the same
// reason: the owner A/B'd the naked material against the hand-drawn layer on
// his own desktop through the `chrome.bareGlass` override built to ask that
// question, and ruled that naked native glass wins. The band now shows
// ``TitlebarGlassBacking`` with nothing painted over it.
//
// The two washes were one treatment on two surfaces, so they had to leave
// together — retiring one and keeping the other is the half-naked window the
// old suppression code went out of its way to avoid.

/// One window, which is also one tab.
///
/// Tabs are native `NSWindow` tabs rather than a bar baia draws. Drag to reorder,
/// drag out to detach, the overflow menu, Merge All Windows, and the keyboard
/// commands all come free and behave the way every other Mac app does. A custom
/// bar would mean rebuilding each of those and maintaining a second title path
/// beside `window.title`.
///
/// The cost is that tab *order* lives in AppKit rather than here. It is read from
/// `window.tabGroup` when a session is written, never mirrored continuously: a
/// mirror drifts the moment a tab is dragged out or windows are merged, and it
/// drifts silently.
@MainActor
final class WorkspaceWindowController: NSObject {
    let window: NSWindow
    let tree: PaneTreeController

    /// Raised when the window closes, so the owner drops its reference. Nothing
    /// else releases the panes, and a pane that outlives its window is a live
    /// shell with nowhere to type.
    var onClose: (() -> Void)?

    /// Raised for anything worth persisting or retitling.
    var onSessionChange: (() -> Void)?
    var onFocusedPaneChange: (() -> Void)?
    /// Carries the project and message of the pane that just changed, so the
    /// banner names the pane that asked rather than the last one in the list.
    var onAttentionChange: ((String, String?) -> Void)?

    /// Raised for a capsule click with something to open. Carries this
    /// window's own pane id and request through unchanged; only the app
    /// delegate owns the popover panel that answers it.
    var onApprovalRequested: ((PaneID, TerminalPaneController.ApprovalRequest) -> Void)?

    /// The sidebar. Always present and always the window's content view, even when
    /// it is showing nothing: a host that came and went would have to swap
    /// `contentViewController`, and that reparents every live ghostty surface.
    let sidebar: SidebarHost

    /// The folder icon and the path, which is what the band says since the
    /// owner's 2026-08-13 ruling took the folder name out of it.
    ///
    /// Held because `NSWindow` does not retain an accessory controller for the
    /// caller, and this one is retinted on every settings change. A `toolbar`
    /// property stood above this one and was held for the same reason until the
    /// toolbar went on 2026-08-13; see `init` for what replaced it.
    /// ``TitlebarPathAccessory`` carries the measurements — why it is
    /// `.leading`, why it costs no height, and why the band is 32 pt.
    let titlebarPath: TitlebarPathAccessory

    /// Whether the window itself is transparent, so glass in it can sample the
    /// desktop rather than this app's own darkness.
    ///
    /// **This is what makes every other glass surface in the window mean
    /// anything.** `NSGlassEffectView` samples what is *behind* its window. An
    /// opaque `NSWindow` fills its whole frame rect with `backgroundColor`
    /// under the content view, so until this existed the sidebar's backing
    /// (``SurfaceHosts``) and the footer's (`PaneStatusBarView`) both lensed
    /// an opaque fill of the app's own making and returned flat grey. The
    /// terminal's own `background-opacity` had the same fate one layer down:
    /// ghostty's Metal layer does render the alpha the setting asks for, and a
    /// window-buffer capture measured every pixel at alpha 255 anyway, because
    /// that correctly-translucent surface was compositing against an opaque
    /// window instead of the desktop. The window had never been non-opaque —
    /// no commit in this repository had ever set `isOpaque` on it.
    ///
    /// **Driven by the setting, not by the chrome style** (owner decision,
    /// 2026-08-07). ``PaneChrome/windowIsTransparent(backgroundOpacity:appearance:)``
    /// is the whole rule and carries the rationale: `backgroundOpacity < 1`
    /// with Reduce Transparency off, whatever `chromeStyle` says. Flat chrome
    /// over translucent wells is a supported look, so nothing here reads
    /// ``PaneChrome/ResolvedChrome``. This is settings-driven window behaviour
    /// the owner has specified, and it leaves the "flat renders
    /// byte-identically" invariant intact because that invariant governs the
    /// chrome *drawing* paths — the fills, rims and backing views a surface
    /// creates — and none of them read these two flags.
    ///
    /// Blurring what shows through this transparency is ``blurRadius``, one
    /// property below. The two are one feature in two halves: this decides
    /// whether the desktop is visible at all, that decides whether it is
    /// frosted, and the second is gated on the first.
    ///
    /// **Safe to move on a live window, unlike the pane arrangement.** A pane's
    /// glass arrangement is frozen at spawn (see
    /// ``TerminalPaneController/spawnedUnderGlass``) because changing it moves
    /// `window-padding-y` or the surface's bottom anchor, and either is a live
    /// grid resize that signals `SIGWINCH` to whatever is running in the shell.
    /// Nothing here goes near that: `isOpaque` and `backgroundColor` are
    /// compositing properties that AppKit reads when it draws the window's
    /// backing store. They feed no layout pass, no view frame, and no ghostty
    /// config key, so no surface changes size and no process is signalled. That
    /// is the asymmetry: window transparency follows a settings change live,
    /// pane layout cannot.
    var isTransparent: Bool = false {
        didSet {
            guard isTransparent != oldValue else { return }
            applyTransparency()
        }
    }

    /// How far the compositor blurs what is behind this window, in points, or
    /// `0` for no blur.
    ///
    /// The other half of ``isTransparent``. That one lets the desktop through;
    /// this frosts what comes through, which is the look the owner's ghostty
    /// config produces with `background-blur = true` and the one baia's sidebar
    /// glass already gets for its own column. Both halves are needed: blur
    /// behind an opaque window is invisible, which is why
    /// ``PaneChrome/windowBlurRadius(backgroundBlur:backgroundOpacity:appearance:paneGlassActive:)``
    /// gates this on the transparency rule rather than on the setting alone,
    /// and it carries the whole decision including where the number 20 comes
    /// from.
    ///
    /// **Applied through private SPI, and it needs a window number that is only
    /// valid once the window is on screen.** `NSWindow.windowNumber` is `0` for
    /// a window the window server has not created a backing surface for, and
    /// this window is built in ``init(tree:sidebar:isTransparent:blurRadius:)``
    /// long before `AppDelegate` calls ``show(joining:)``. Passing `0` to
    /// ``CGSSetWindowBackgroundBlurRadius(_:_:_:)`` addresses no window at all,
    /// so it fails silently and the blur simply never appears — the failure
    /// mode of this SPI is exactly the one that leaves no trace. So this is
    /// *stored* at init, deliberately unlike ``isTransparent`` which is written
    /// onto the window immediately, and ``show(joining:)`` applies it right
    /// after `makeKeyAndOrderFront` when the number exists. A later assignment
    /// (the settings-file path) applies at once, because by then the window has
    /// long been shown.
    ///
    /// **A window number can change, and this is why reapplying is cheap.** The
    /// number belongs to the window server's surface, not to this object, so a
    /// window that is ordered out and back in can be given a different one.
    /// Nothing here caches it: every application reads `window.windowNumber`
    /// fresh at the moment it calls, and the settings path reapplies to every
    /// live window on every change. baia never rebuilds an `NSWindow` in place
    /// — a rebuilt window is a new `WorkspaceWindowController` that goes
    /// through `init` and `show(joining:)` again — so there is no path where a
    /// stale number is written.
    ///
    /// **Safe to move on a live window, for ``isTransparent``'s reason.** This
    /// is a compositor property of the window's backdrop. It feeds no layout
    /// pass, no view frame and no ghostty config key, so no surface changes
    /// size and nothing running in a pane is signalled.
    var blurRadius: Int = 0 {
        didSet {
            guard blurRadius != oldValue else { return }
            applyBlur()
        }
    }

    /// Whether this window's own chrome — the titlebar band, the tab bar, and
    /// anything else `NSWindow.appearance` governs — should render dark.
    ///
    /// **Window-level, deliberately not `NSApp.appearance`.** Setting the app
    /// appearance would force every window in the process, including the
    /// settings window and the palette/find panels, onto this workspace
    /// window's theme, and those follow their own rules — the settings window
    /// previews a *draft* theme that need not be the live one, and the
    /// floating panels are content this type does not own. `NSWindow.appearance`
    /// on this one window is the platform's own mechanism for scoping the
    /// override to a single window; nothing wider is touched.
    ///
    /// **Owner's ruling: "titlebar should follow the pane's appearance," which
    /// is the standing chrome-matches-the-theme rule (see ``PaneTheme``'s own
    /// header) reaching this window's system-drawn chrome.** Before this, the
    /// titlebar the toolbar then asked for (`5f3b88c`, `ea7a223`) rendered in
    /// whatever `NSApp.effectiveAppearance` was — the system's light/dark, not
    /// the terminal theme's — so a dark pane theme under a light system
    /// appearance produced a light titlebar band over dark panes.
    /// ``PaneChrome/windowIsDark(paneTheme:)`` is where that derivation lives
    /// and carries the reasoning for reading the theme rather than
    /// `ChromeAppearance.isDark`; this is the one line that writes its answer
    /// onto the window.
    ///
    /// **Feeds no layout and no ghostty config key**, for the same reason
    /// ``isTransparent`` does not: `NSWindow.appearance` is a rendering
    /// property AppKit reads when it draws the window's chrome, not a value
    /// any pane, grid, or `TerminalConfiguration` ever sees. No surface
    /// resizes and nothing running in a pane is signalled.
    var isDark: Bool = false {
        didSet {
            guard isDark != oldValue else { return }
            applyAppearance()
        }
    }

    /// Whether this window's titlebar wears glass or the system's own material.
    ///
    /// **The owner's verdict on `78aadfe` was "titlebar is not
    /// glass/transparent," and this is the property that answers it.** Three
    /// commits got the *system* titlebar working — a toolbar to ask for it
    /// (`5f3b88c`), a non-clear background to composite it against
    /// (`ea7a223`), the theme's own appearance to render it in (`78aadfe`) —
    /// and what they produced is a solid slab. Measured in
    /// `Diagnostics/titlebar-toolbar`: the shipped band holds one luminance
    /// down its whole height (spread 0.0) while the desktop behind the window
    /// spreads 60+, so nothing of what is behind the window reaches the band.
    /// Confirmed on the live dev build at the owner's own settings, which is
    /// the sharper version of the same fact: the shipped band did not move
    /// when `backgroundOpacity` went from 0.09 to 0.85, while every other
    /// chrome surface did. The footer, the sidebar column, the palette and the
    /// approval popover all wear untinted `NSGlassEffectView` and show the
    /// desktop through. The titlebar was the one that did not.
    ///
    /// Gated on ``PaneChrome/ResolvedChrome`` and nothing else, unlike
    /// ``isTransparent`` one property up. That asymmetry is deliberate and is
    /// the same split the sidebar already draws: window *transparency* follows
    /// `backgroundOpacity` because translucent wells under flat chrome is a
    /// look the owner asked for, but a glass *view* is chrome, and chrome
    /// follows `chromeStyle`. Under flat this window keeps the system slab
    /// exactly as `78aadfe` left it, which is the correct treatment there.
    ///
    /// Reduce Transparency needs no separate handling here and that is worth
    /// stating rather than leaving to be rediscovered:
    /// `PaneChrome.resolvedStyle(setting:materialIsDark:appearance:)` already forces `.flat`
    /// when the accessibility setting is on, so this gate covers it through
    /// the same path every other glass surface is covered by.
    var resolvedChrome: ResolvedChrome = .flat {
        didSet {
            guard resolvedChrome != oldValue else { return }
            applyTitlebarGlass()
        }
    }

    /// Which of the four fill roles the titlebar's glass is tinted with, or nil
    /// for the untinted band that ships.
    ///
    /// Nil unless the debug design panel has pointed this surface somewhere, and
    /// in Release it can hold nothing else. See ``SurfaceFill``.
    ///
    /// Written through to ``SidebarHost/titlebarFillMaterial``, which owns the
    /// plane since the merge. The titlebar and the sidebar stay two addressable
    /// surfaces even though one host holds both planes, so pointing this at a
    /// role tints the band and leaves the column alone.
    var fillMaterial: DesignOverrides.Chrome.Material? {
        didSet {
            guard fillMaterial != oldValue else { return }
            updateTitlebarGlassTint()
        }
    }

    /// How much height the window is currently spending on chrome above its
    /// content, which under `.fullSizeContentView` is the band the sidebar's
    /// glass has to reach up into and the pane tree has to be held back from.
    ///
    /// Derived rather than written as a constant, for the reason the old
    /// `layoutTitlebarGlass()` derived it: it is whatever the window is spending
    /// right now, so a tab bar joining, a chrome change, or a system metric this
    /// app does not control cannot leave the glass short of the band or the tree
    /// overlapping it.
    ///
    /// **Removing the toolbar on 2026-08-13 is the case that paid for it.** The
    /// band went from 40 pt to 32 with no arithmetic changed anywhere: measured
    /// on a fresh window, `relTop` of the sidebar's scroll area moved 40 to 32
    /// and the pane region stayed 680 pt in both. A hardcoded 40 would have held
    /// the tree 8 pt below a band that no longer reached it.
    ///
    /// **`contentLayoutRect` is still the source, and under
    /// `.fullSizeContentView` it still answers correctly.** The flag extends the
    /// content *view* under the band; `contentLayoutRect` continues to report the
    /// region AppKit considers unobstructed, so `frame.height - contentLayoutRect
    /// .height` is the band either way. `Diagnostics/titlebar-toolbar` measures
    /// that drop (292 to 220 pt under the flag) and this is the arithmetic that
    /// consumes it deliberately rather than being surprised by it.
    var titlebarBandHeight: Double {
        window.frame.height - window.contentLayoutRect.height
    }

    /// `isTransparent`, `blurRadius`, and `isDark` are parameters rather than
    /// later assignments for the reason ``ConfigurationCenter`` states about
    /// its own appearance observer: a caller cannot forget what it must name.
    /// It is also the reason ``SidebarHost`` takes its chrome. A window built
    /// opaque and made transparent a moment later would show one solid frame
    /// first, and the same is true of one built in the wrong titlebar
    /// appearance and corrected only on the next settings change.
    init(
        tree: PaneTreeController,
        sidebar: SidebarHost,
        isTransparent: Bool,
        blurRadius: Int,
        isDark: Bool,
        resolvedChrome: ResolvedChrome,
        theme: PaneTheme
    ) {
        self.tree = tree
        self.sidebar = sidebar
        self.isTransparent = isTransparent
        self.blurRadius = blurRadius
        self.isDark = isDark
        self.resolvedChrome = resolvedChrome
        // Built with the theme rather than corrected into it afterwards, which
        // is the same rule the four parameters above follow: a band that opened
        // in AppKit's default ink and was retinted on the first settings change
        // would show one frame of the wrong colour on every new window.
        titlebarPath = TitlebarPathAccessory(theme: theme)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 680),
            // **`.fullSizeContentView` is what lets the band and the column be
            // one panel**, and it is here rather than toggled with the chrome
            // style on purpose: it is a window-construction property, and
            // `Diagnostics/titlebar-merge`'s own probe bug records what
            // inserting it on a *live* window costs — the frame shrinks by the
            // band rather than the content view growing into it, and the band's
            // height is then spent twice. Set once, at construction, and never
            // moved.
            //
            // The flag extends `contentView` under the titlebar, which is the
            // only way the band region is reachable from a view the sidebar's
            // `NSGlassEffectContainerView` can hold. See ``applyTitlebarGlass()``
            // for why the frame view no longer works and what the probe measured.
            //
            // **Unconditional, unlike the glass it enables.** Under flat there is
            // no container and no band plane, and the extended content view costs
            // that path nothing: `SidebarHost` holds the pane tree's rect back by
            // ``titlebarBandHeight`` whatever the chrome style is, so flat renders
            // at exactly the geometry it always did. Gating the style mask on
            // `resolvedChrome` would mean a live style-mask flip on every settings
            // change, which is the arrangement the probe bug above measured going
            // wrong.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        // The sidebar is the content and adopts the tree as a child, so the tree
        // still owns every pane and the window still has one content controller.
        // Showing nothing is a column of zero width, not a different content view.
        window.contentViewController = sidebar
        window.title = "baia"

        // **`window.title` still carries the folder name, and the band no longer
        // draws it. Both halves are load-bearing and this flag is the seam.**
        //
        // The obvious spelling of the 2026-08-13 ruling is to stop writing the
        // name into `window.title`, and it is wrong: **the native tab bar labels
        // each tab from `window.title`**, so emptying it removes the name from
        // the band and from every tab at once. Probed on the frame-view tree
        // rather than reasoned about — with titles set, each `NSTabButton` holds
        // an `NSTextField` reading `vault` / `baia`; with the titles emptied,
        // those children do not exist and the buttons render blank. The ruling
        // is about the titlebar band, and a bar of unlabelled tabs is not what it
        // asked for: the tab is the one place the name is still the only thing
        // telling two windows apart, which is the entire reason
        // `TabTitle.disambiguated` exists.
        //
        // `.hidden` hides the band's title text while leaving the string on the
        // window for the tab bar to read. Measured: the band is 40.0 pt with the
        // flag and 40.0 pt without it, so this buys the removal at no height,
        // and the tab buttons keep their labels across the flip.
        //
        // **It hides the subtitle with it**, which is why the path moved into
        // ``titlebarPath`` rather than staying in `window.subtitle`. Probed on
        // the frame view: shown, the band holds a `_NSToolbarTitleField` reading
        // `baia` and a sibling `NSTextField` reading the path, both inside
        // `NSToolbarTitleStackView` and both `visible=true`; hidden, that stack
        // is gone and what remains is a single `NSTextField` on `NSTitlebarView`
        // reading `baia – ~/Projects/baia` at `frame=(0, -220, 0, 0)` with
        // `visible=false`. Zero-sized and off-screen: it is the string the tab
        // bar and accessibility read, not drawn chrome. So `.hidden` empties the
        // band of text and keeps the name available to everything that reads the
        // window rather than looks at it.
        //
        // The path would have had to move regardless — `NSWindow.subtitle` is a
        // `String` with no attributed spelling, so it cannot carry a glyph the
        // theme tints — but it is worth recording that title and subtitle are one
        // slot to AppKit and not two independently hideable ones.
        window.titleVisibility = .hidden

        // **No toolbar, since 2026-08-13, and this block is the record of why
        // one stood here for three months.**
        //
        // An empty `NSToolbar` was what gave this window a titlebar at all.
        // Once the window became genuinely non-opaque (`331b7ec`, `isOpaque =
        // false` and a clear `backgroundColor` whenever `backgroundOpacity <
        // 1`), the titlebar region had no material in it: the traffic lights and
        // the title floated on whatever the desktop happened to show behind the
        // window. A titled `NSWindow` does not draw its own titlebar material on
        // macOS 26 — the material arrives with an `NSToolbar`, per the research
        // record (`vault/projects/baia/liquid-glass-research.md` §4: "the glass
        // comes from `NSToolbar` and window style, not new window flags").
        // `Diagnostics/titlebar-toolbar` measured exactly that, and shipped it
        // in `5f3b88c`: with no toolbar the strip read the content behind it and
        // varied down its height, and with one it read a flat neutral all the
        // way down.
        //
        // **What retired it is the band/column merge, not a change of mind.**
        // Since 2026-08-12 the band's material comes from
        // ``SidebarHost/bandGlass``, an `NSGlassEffectView` inside `contentView`
        // that `.fullSizeContentView` lets reach up into the band. The toolbar
        // was asking AppKit for a material the app now draws for itself one
        // layer down, so what it still bought was its 40 pt metric — and in a
        // terminal workspace that is eight rows of nothing.
        //
        // **Measured on the live dev build under the owner's `chromeStyle:
        // glass`, both arms, sampling a column at x=700 down the band.** The
        // band's appearance does not change when the toolbar goes; only its
        // height does.
        //
        //     |                | with toolbar | without |
        //     |----------------|--------------|---------|
        //     | band height    | 40 pt        | 32 pt   |
        //     | window frame   | 720 pt       | 712 pt  |
        //     | panes          | 680 pt       | 680 pt  |
        //     | mean, desktop  | 0.1845       | 0.1839  |
        //     | spread, desktop| 0.0580       | 0.0549  |
        //     | mean, white    | 0.5555       | 0.5511  |
        //     | spread, white  | 0.0902       | 0.0902  |
        //
        // **"White" is a white window ordered directly behind the workspace
        // window**, which is the control that says what the band is sampling.
        // Both arms brighten to ~0.55 over it, and the sidebar's own glass
        // column measured 0.5780 in the same frame: the band lenses what is
        // behind the window exactly as every other glass surface in this app
        // does, with and without a toolbar alike. That is the band reading as
        // glass, which is what `78aadfe`'s verdict asked for — not the flat
        // slab the toolbar used to produce.
        //
        // **So the toolbar was contributing nothing to the band's material by
        // the time it was removed**, and the two rows above are the evidence:
        // if it had been, dropping it would have moved the desktop mean or the
        // white mean, and neither moved by more than 0.005.
        //
        // **That is what makes `Diagnostics/titlebar-toolbar`'s conclusion
        // historical.** The probe was right when it was written and its arms
        // still measure what they always did — it builds its own windows and
        // links no app source — but it answers "does a bare titled window get
        // material", and this window is no longer bare underneath. Its README
        // carries the 2026-08-13 section saying so.
        //
        // **Under flat the band is still the system slab and still needs no
        // toolbar**, which is the case worth checking because the merge did not
        // touch it: measured at `chromeStyle: flat`, the band is 32 pt and
        // spreads 0.0031 down its height, which is the slab holding one value.
        // ``applyTitlebarGlass()`` sets `titlebarAppearsTransparent = false`
        // there and AppKit paints it, toolbar or no toolbar.
        //
        // **The `no-toolbar` arm's 32 pt was never a surprise**, only a price
        // this window used to have to pay. `.unifiedCompact` spent 40 against
        // `.unified`'s 52 and was chosen as the cheapest metric that still
        // produced the material; with the material coming from elsewhere, the
        // cheapest metric is no toolbar at all.
        //
        // Nothing here sets `titlebarAppearsTransparent`. That flag is
        // ``applyTitlebarGlass()``'s, which runs at the end of this `init` and
        // owns it in both directions — true under glass, false under flat so the
        // system slab paints the band again. Setting it here would be a second
        // writer for one flag, and under flat the wrong one.

        // **The folder icon and the path, on the owner's 2026-08-13 ruling.**
        //
        // `.leading` puts it after the traffic lights and before the title's
        // centred slot, which is where a document window's proxy icon sits: the
        // eye already looks there for "what is this window about". Measured to
        // cost nothing — the band is 40.0 pt with this accessory attached and
        // 40.0 pt without it — which is the only reason a view is allowed in
        // this band at all. `.bottom` is the arrangement that would have paid
        // for it, at 76.0 pt whatever height its view asks for.
        //
        // **`NSWindow.representedURL` was the alternative and was refused on a
        // measurement.** It draws a real document proxy icon for free, with
        // dragging and the ⌘-click path menu, and it was worth wanting for
        // exactly those. Two things rule it out. It draws the *system* folder
        // icon, full colour, which is the one thing in this window that no theme
        // change can repaint — and the owner's ruling names a themed symbol
        // specifically. And it accepts a path that does not exist without
        // complaint (probed: `/does/not/exist/anywhere` is stored and returned
        // unchanged), which in this app is not hypothetical: a pane outlives its
        // working directory often enough that `SurfaceMessage.drawAbsent` exists
        // to draw that state. A proxy icon is a *control* — draggable, and its
        // menu claims to reveal a real place — so the failure mode is not a
        // stale label but a control that lies about a directory that is gone.
        // A themed symbol is a label, and a label naming a directory that has
        // been deleted is merely out of date until the next poll.
        titlebarPath.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(titlebarPath)

        // Assigning a contentViewController makes the window adopt the content's
        // fitting size and discard the contentRect above, so the size is set
        // after the assignment, not before. contentMinSize stops a future layout
        // change from collapsing the window to an invisible sliver.
        //
        // **Both numbers are the band taller than they read, and without that
        // the merge would silently cost every window a band of panes.** Under
        // `.fullSizeContentView` the content view spans the band, so a content
        // height of 680 leaves the pane tree 680 minus the band: this host holds
        // the tree below it, and what `setContentSize` sizes is the rect the
        // band comes out of. Measured rather than reasoned — the same asymmetry
        // `Diagnostics/titlebar-merge` records as `normalisedFrame`, where one
        // `contentRect` produced a 720 pt frame without the flag and a 680 pt
        // frame with it. Adding the band back makes 680 mean 680 of panes, which
        // is what it meant before the flag.
        //
        // **Still true at 32 pt, and re-measured on the day the toolbar went.**
        // Fresh windows, accessibility-read: with the toolbar, frame 720 and the
        // sidebar's scroll area 680 pt tall starting at `relTop=40`; without it,
        // frame 712 and the same 680 pt starting at `relTop=32`. The window is 8
        // pt shorter and the panes are untouched, which is the arithmetic
        // working rather than something to compensate for — the point of the
        // band shrinking is that the window stops spending the height, not that
        // it spends it somewhere else.
        //
        // Read from the window rather than written as a constant, for
        // ``titlebarBandHeight``'s reason: the metric is AppKit's and this app
        // does not own it.
        let band = titlebarBandHeight
        window.contentMinSize = NSSize(width: 480, height: 320 + band)
        window.setContentSize(NSSize(width: 1024, height: 680 + band))
        window.center()

        // Every baia window shares one identifier, which is what lets AppKit
        // group them as tabs at all. `.preferred` means a new window joins the
        // existing group rather than opening detached, matching what cmd+t means
        // in a terminal.
        window.tabbingIdentifier = "baia.workspace"
        window.tabbingMode = .preferred

        // Closing a window must not deallocate it while AppKit is still using it
        // during the close. The owner drops its reference from `onClose` instead,
        // which is what actually releases the panes.
        window.isReleasedWhenClosed = false
        window.delegate = self

        // Called rather than left to the property's `didSet`, which does not run
        // for an assignment made inside `init`. At `backgroundOpacity == 1` (or
        // under Reduce Transparency) this writes the values the window was born
        // with, so that case stays exactly what it has always been.
        applyTransparency()
        // Same reason, one property over: `isDark`'s `didSet` does not fire for
        // the assignment three lines up, so the window would otherwise open in
        // AppKit's own default appearance until the first settings change wrote
        // one.
        applyAppearance()
        // And the same again for the titlebar. Called after
        // `contentViewController` is assigned above, because it hands the band's
        // tint down to ``sidebar`` and that is the object the assignment
        // installs; called before the window is ever shown, so no frame of the
        // system slab is visible under a glass build.
        applyTitlebarGlass()

        tree.onFocusedPaneChange = { [weak self] in self?.onFocusedPaneChange?() }
        tree.onSessionChange = { [weak self] in self?.onSessionChange?() }
        tree.onAttentionChange = { [weak self] _, project, message in
            self?.onAttentionChange?(project, message)
        }
        tree.onApprovalRequested = { [weak self] id, request in
            self?.onApprovalRequested?(id, request)
        }
        tree.onEmpty = { [weak self] in
            // The last pane of this tab exited. Close the tab rather than leaving
            // an empty one, which also releases the tree and any remaining panes.
            self?.window.close()
        }
    }

    /// Writes ``isTransparent`` onto the window.
    ///
    /// Both properties move together and neither alone is enough. `isOpaque =
    /// false` only *permits* transparency; the window still fills its frame
    /// rect with `backgroundColor` underneath the content view, so a window
    /// left at the default `windowBackgroundColor` renders exactly as solid as
    /// before. That is the same pairing the palette panel documents on its own
    /// copy (``CommandPaletteController``), found there when an opaque window
    /// colour refilled corners the content had just clipped away.
    ///
    /// Restores `.windowBackgroundColor` rather than remembering what was
    /// there: that is the value an `NSWindow` of this style mask is born with,
    /// and nothing in this file has ever assigned another.
    ///
    /// **Transparent is a background one step off clear, not `.clear`, and that
    /// one step is what the titlebar is made of.** `5f3b88c` gave the window an
    /// empty `NSToolbar` so macOS would supply the titlebar material, and
    /// structurally it worked — the band takes its 40 pt, `contentLayoutRect`
    /// insets, the title and subtitle land in toolbar positions. Visually
    /// nothing arrived: the traffic lights and the title floated on the
    /// wallpaper at every opacity the owner tried. The material was not being
    /// drawn at all.
    ///
    /// The cause is this line, and it is binary rather than proportional.
    /// AppKit composites the titlebar material against the window's own
    /// background, so `backgroundColor = .clear` leaves it nothing to draw onto
    /// and it renders as nothing. That is why the opacity knob never moved it:
    /// at `0.99` the wells are near-solid and the band is still bare wallpaper,
    /// and at exactly `1.0` the window is opaque and the titlebar has always
    /// been fine. The variable was never the opacity, it was the `.clear`.
    ///
    /// `Diagnostics/titlebar-toolbar` measures it as luminance spread down the
    /// band, since the material and a dark wallpaper have the same *mean* and
    /// only the material holds one value all the way down. Every `.clear` arm
    /// spreads 64; every arm with a non-zero background alpha spreads 0.0,
    /// including `0.005`. There is no ramp between them.
    ///
    /// So the alpha here is deliberately the smallest one that is not zero
    /// rather than a tint. It exists to be non-clear and nothing else: at
    /// `0.005` over a 0.09 white it contributes about one part in 200 of a very
    /// dark grey, which is under a single 8-bit level and cannot be seen. The
    /// probe measures the wells keeping a spread of 50.0 against the shipped
    /// `.clear` arm's 50.1 — the desktop shows through exactly as much as it
    /// did, which is the property the whole non-opaque window exists for. A
    /// larger alpha would work equally well for the titlebar and would start
    /// paying for it in the wells: the same probe's `0.42` arm restores the
    /// material and drops the wells to 29.1.
    ///
    /// **Not `fullSizeContentView`, which was the first hypothesis and is
    /// measurably not the fix *for this*.** The platform recipe for chrome over
    /// content is content extending under the titlebar, so the probe carries an
    /// arm that does exactly that — `.fullSizeContentView` with the well
    /// anchored to the safe area, so the backing extends while the visible
    /// layout does not move. Its band spreads 63.6, which is the bare-titlebar
    /// number. Content beneath the band is not what the material samples; the
    /// window background is. That arm is kept in the probe rather than deleted,
    /// because "we tried the obvious platform arrangement and measured it not
    /// working" is the part a later reader will otherwise re-derive.
    ///
    /// **The window carries `.fullSizeContentView` anyway since 2026-08-12, and
    /// that does not contradict the paragraph above.** The flag was rejected as
    /// a fix for the *material* and it is still no such fix — this line's
    /// non-zero alpha is what makes the material draw, and removing it would
    /// bring the bare band straight back with the flag set or not. The flag is
    /// carried for a different question the band/column merge asked: it is the
    /// only way `contentView` reaches the band region, which is where the
    /// sidebar's `NSGlassEffectContainerView` has to hold both planes. Two
    /// answers about one flag, to two different questions, and the probe
    /// measured both.
    ///
    /// **Nothing changes at `backgroundOpacity == 1`.** That path is the `else`
    /// here and still writes `.windowBackgroundColor` on an opaque window,
    /// which is byte-for-byte what it has always written. The band already
    /// worked there, back when a toolbar was what drew it and since.
    private func applyTransparency() {
        window.isOpaque = !isTransparent
        window.backgroundColor = isTransparent ? Self.nonClearTransparentBackground : .windowBackgroundColor
    }

    /// The window background that is transparent to the eye and non-clear to
    /// AppKit's titlebar compositing.
    ///
    /// A named constant rather than a literal at the use site because the
    /// number is load-bearing in a way its value does not show: this is not a
    /// colour choice that can be nudged, it is the smallest non-zero alpha, and
    /// the one property it must keep is being non-zero. Setting it to `0` is
    /// the defect, and a diff against a line that says so is the point.
    ///
    /// White `0.09` matches the neutral the probe's wells and the rest of this
    /// design line use, so the constant reads as "the app's dark, at a hair of
    /// alpha" rather than as an arbitrary colour. At this alpha the hue is
    /// unobservable; only the non-zero-ness is doing work.
    private static let nonClearTransparentBackground = NSColor(calibratedWhite: 0.09, alpha: 0.005)

    /// Writes ``isDark`` onto the window as `NSWindow.appearance`.
    ///
    /// This is the platform's own mechanism for a window that disagrees with
    /// the rest of the app about light and dark: `NSWindow.appearance` is
    /// documented to override `NSApp.appearance` for one window's view
    /// hierarchy and its system-drawn chrome — the titlebar band and the tab
    /// bar — while every other window
    /// (settings, the command palette, the find panel) keeps resolving
    /// `nil` back to the app's own appearance and is untouched by this call.
    /// `NSApp.appearance` was not an option for the same reason: it has no
    /// per-window scope, so setting it here would also repaint the settings
    /// window's live preview and the floating panels' glass, which are
    /// explicitly out of scope for this request.
    ///
    /// `.darkAqua` / `.aqua` rather than any of the vibrant or high-contrast
    /// variants: those are user accessibility choices this window has no
    /// opinion on and no way to read safely, and the two base appearances are
    /// what `AppearanceObserver.readCurrentAppearance()` already resolves the
    /// system read down to with the identical `bestMatch(from:)` call.
    private func applyAppearance() {
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    /// Builds or tears down the titlebar's glass to match ``resolvedChrome``.
    ///
    /// The same shape `SidebarHost.applyResolvedChrome()` and
    /// `TerminalPaneController.applyResolvedGlassPlane()` take: flat *removes*
    /// the views rather than hiding them, and glass creates them only if none
    /// exist, so a chrome change that toggles glass-flat-glass does not rebuild
    /// views that did not need to move. Removal rather than hiding is load-bearing here
    /// for the same reason it is in the sidebar — under flat the system slab
    /// paints the band again, and a hidden-but-present glass view would be a
    /// second treatment stacked under it the moment anything unhid it.
    ///
    /// **`titlebarAppearsTransparent` is what stops the slab, and this is the
    /// one place its meaning is settled.** `5f3b88c` ruled the flag out by
    /// measurement and was right to, in the window it measured: over a `.clear`
    /// background it undid the material the toolbar existed to produce and left
    /// bare wallpaper. The probe's `transparent-no-glass` arm reproduces
    /// exactly that and still grades show-through. What changed is that the
    /// band is no longer empty afterwards — the flag removes the slab and
    /// ``SidebarHost/bandGlass`` replaces it, which is the arrangement the
    /// earlier commit had no reason to try.
    ///
    /// **This is also the one writer of the flag, which is why `init` sets it
    /// nowhere.** Under flat it must go back to `false` or the slab never
    /// returns, so a second unconditional `true` in `init` would be a bug that
    /// only shows under the style the merge did not touch.
    ///
    /// **The toolbar used to be the other half of this and went on 2026-08-13.**
    /// It was what bought the 40 pt `.unifiedCompact` metric while also being
    /// what asked for the material; once this view supplied the material, the
    /// metric was all that was left and the band shrank to 32 pt without it. See
    /// `init` for the measurements. The probe still asserts the 40 pt band and a
    /// visible toolbar on *its own* windows, which still have one.
    ///
    /// **Why the band's plane left the frame view, on 2026-08-12.** It was
    /// parented in `contentView.superview` because the band sits above
    /// `contentView` and no public API hands it over, and that parent was chosen
    /// over `.fullSizeContentView` on a cost this comment used to state as
    /// disqualifying: the flag drops `contentLayoutRect` from 292 to 220 pt,
    /// which the pane tree lays out against, so adopting it would resize every
    /// ghostty grid and `SIGWINCH` every running shell.
    ///
    /// **That cost is real, still measured, and no longer disqualifying — the
    /// rejection was stale rather than wrong.** It assumed the tree's rect
    /// follows `contentLayoutRect`, and `Diagnostics/titlebar-merge`'s arm 5
    /// (route A) measured the alternative: extend the content view, let the
    /// *column's* rect grow up under the band, and hold the *tree's* rect at the
    /// row it had. The tree region came back identical to the shipped
    /// arrangement in all four components (`dx=dy=dw=dh=dtop=0`), and its
    /// `gridtest` companion put a real libghostty surface in that rect and read
    /// **73 x 19 in both arrangements with zero resize callbacks across the
    /// flip**. `Diagnostics/titlebar-toolbar` still asserts the
    /// `contentLayoutRect` drop; what changed is that the drop no longer
    /// propagates, because ``SidebarHost`` splits the rect it used to share.
    ///
    /// The frame view had to go because the merge is impossible from there.
    /// `NSGlassEffectContainerView` merges the glass views that are its own
    /// **subviews**, and a view has one superview: a plane in the frame view and
    /// a plane in `contentView` cannot both be in one container, which arm 2
    /// establishes as structural rather than as an API gap. Two planes sampling
    /// separately is the seam the owner sees, measured at 34.33 against a 2.00
    /// threshold; both planes in `contentView` under one container measure 0.00.
    ///
    /// A toolbar item filling the band is still refused, on the owner's "go full
    /// macOS" rule: it means inventing a fake item to carry a background, which
    /// is mimicry of chrome the platform already draws.
    ///
    /// **What this method still owns.** The band's plane belongs to
    /// ``SidebarHost`` now, because that is where the container is. This keeps
    /// the flag that stops the system slab and the tint the design panel points
    /// at the titlebar surface, and hands both down. No geometry moves here:
    /// `titlebarAppearsTransparent` is a chrome-drawing flag, and the style mask
    /// is fixed at construction rather than toggled with the chrome style.
    private func applyTitlebarGlass() {
        switch resolvedChrome {
        case .flat:
            // Back to the system's own titlebar, byte for byte what `78aadfe`
            // shipped: the flag off means AppKit paints the slab again. The
            // sidebar tears its own planes down off the same `resolvedChrome`,
            // so flat is a window with the slab and no glass anywhere in it.
            window.titlebarAppearsTransparent = false

        case .glass:
            window.titlebarAppearsTransparent = true
        }
        sidebar.titlebarFillMaterial = fillMaterial
    }

    /// Writes ``fillMaterial`` through to the band's plane, which
    /// ``SidebarHost`` now owns.
    ///
    /// **The two surfaces stay separately addressable even though one host holds
    /// both planes**, which is the whole reason this is a distinct property
    /// rather than folded into the sidebar's own `fillMaterial`. The design
    /// panel points `chrome.surfaces.titlebar` and `chrome.surfaces.sidebar` at
    /// different roles, and merging the planes must not merge the overrides: an
    /// owner tinting the titlebar to check a role would otherwise repaint the
    /// column too and read the wrong answer.
    ///
    /// Nil unless the debug design panel has pointed this surface somewhere, and
    /// in Release it can hold nothing else. See ``SurfaceFill``.
    private func updateTitlebarGlassTint() {
        sidebar.titlebarFillMaterial = fillMaterial
    }

    /// Writes ``blurRadius`` onto the window through the private CGS backdrop
    /// SPI.
    ///
    /// Reads `window.windowNumber` fresh rather than holding one, for the
    /// reason ``blurRadius`` states: the number belongs to the window server's
    /// surface and is `0` until there is one. The guard is not defensive
    /// tidiness — it is what stops a call before ``show(joining:)`` from being
    /// silently addressed at nothing, and it is why the *result* of that call
    /// can be discarded without hiding anything. `0` for a radius is a real
    /// request meaning "no blur", so this still calls in that case, on a real
    /// window number: it is how the blur is *removed* when the setting is
    /// turned off on a running window.
    ///
    /// The returned `CGError` is deliberately ignored, which
    /// ``CGSSetWindowBackgroundBlurRadius(_:_:_:)``'s own doc comment explains:
    /// there is no recovery, and the worst outcome is a window that renders
    /// unblurred.
    private func applyBlur() {
        let number = window.windowNumber
        guard number != 0 else { return }
        CGSSetWindowBackgroundBlurRadius(CGSDefaultConnectionForThread(), number, blurRadius)
    }

    /// Joins `other`'s tab group, or opens standalone when there is none.
    func show(joining other: NSWindow?) {
        if let other, other !== window {
            other.addTabbedWindow(window, ordered: .above)
        }
        window.makeKeyAndOrderFront(nil)

        // The first moment `window.windowNumber` is real, and so the first
        // moment the blur can be applied at all: the window server creates the
        // backing surface as the window is ordered in, and every call before
        // this one addressed window `0`. Applied here rather than from the
        // property's `didSet`, which cannot help — the value is assigned in
        // `init`, where `didSet` does not run and the number would be `0`
        // anyway. Unconditional, matching `applyTransparency()`'s call in
        // `init`: at radius 0 this writes what the window already has.
        applyBlur()

        tree.focusedPane?.takeFocus()
    }

    /// This window's tab, with its panes, for the session file.
    var snapshot: (tab: Tab, panes: [PaneState])? {
        let snapshot = tree.snapshot(windowFrame: nil)
        guard let tab = snapshot.workspace.tabs.first else { return nil }
        return (tab, snapshot.panes)
    }

    var frame: WindowFrame {
        WindowFrame(
            x: Double(window.frame.origin.x),
            y: Double(window.frame.origin.y),
            width: Double(window.frame.width),
            height: Double(window.frame.height)
        )
    }
}

extension WorkspaceWindowController: NSWindowDelegate {
    func windowWillClose(_: Notification) {
        onClose?()
    }

    func windowDidResize(_: Notification) {
        // **The band's height is not a constant and a resize is when it moves**:
        // it changes when a tab bar joins or leaves the window. `SidebarHost`
        // reads it back through ``titlebarBandHeight`` for both the band plane's
        // frame and the row it holds the pane tree at, and a layout pass AppKit
        // schedules for the size change alone would run against the old number.
        // So the host is asked for a fresh pass here rather than left to an
        // autoresizing mask, which was the same reason the retired
        // `layoutTitlebarGlass()` was called from this delegate.
        sidebar.view.needsLayout = true
        onSessionChange?()
    }

    func windowDidMove(_: Notification) {
        onSessionChange?()
    }

    /// AppKit asks for this when the tab bar's plus button is clicked, and hides
    /// the button entirely when nothing in the responder chain implements it.
    @objc func newWindowForTab(_ sender: Any?) {
        NSApp.sendAction(#selector(AppDelegate.newTab(_:)), to: nil, from: sender)
    }
}
