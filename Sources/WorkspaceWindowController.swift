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

/// The untinted glass spanning the titlebar band, so the window's top edge
/// wears the same treatment as every other chrome surface in this app.
///
/// The sidebar's ``SidebarGlassBacking`` with one difference, and the
/// difference is where it lives rather than what it is: this one is parented
/// in the window's *frame view* (`contentView.superview`) because the titlebar
/// band is above `contentView` and no public API hands it over. See
/// ``WorkspaceWindowController/applyTitlebarGlass()`` for why that parent was
/// chosen over the two alternatives, both measured.
private final class TitlebarGlassBacking: NSGlassEffectView {
    override var acceptsFirstResponder: Bool { false }

    override var canBecomeKeyView: Bool { false }

    /// Refuses every click, which matters more here than it does in the
    /// sidebar. This view lies over the traffic lights, the title, the
    /// toolbar and the tab bar — every one of them a control AppKit owns and
    /// this app must not intercept. A glass view that answered a hit test here
    /// would swallow window close and tab switching.
    override func hitTest(_: NSPoint) -> NSView? { nil }
}

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

    /// Held because `NSWindow.toolbar` is `weak`-adjacent in practice: the window
    /// does not keep a toolbar alive on its own once nothing else references it,
    /// and a deallocated toolbar takes the titlebar material with it.
    private let toolbar: NSToolbar

    /// Whether the window itself is transparent, so glass in it can sample the
    /// desktop rather than this app's own darkness.
    ///
    /// **This is what makes every other glass surface in the window mean
    /// anything.** `NSGlassEffectView` samples what is *behind* its window. An
    /// opaque `NSWindow` fills its whole frame rect with `backgroundColor`
    /// under the content view, so until this existed the sidebar's backing
    /// (``SurfaceHosts``) and the footer's (``PaneStatusBarView``) both lensed
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

    /// Whether this window's own chrome — the titlebar material the toolbar
    /// asks AppKit for, the tab bar, and anything else `NSWindow.appearance`
    /// governs — should render dark.
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
    /// titlebar the toolbar asks for (`5f3b88c`, `ea7a223`) rendered in
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
    var fillMaterial: DesignOverrides.Chrome.Material? {
        didSet {
            guard fillMaterial != oldValue else { return }
            updateTitlebarGlassTint()
        }
    }

    /// The glass under the titlebar band, `nil` under flat. Built and torn down
    /// by ``applyTitlebarGlass()``.
    ///
    /// **It had a wash above it until 2026-08-08**, and with that gone this
    /// controller no longer holds `theme` or `backgroundOpacity` at all: the two
    /// were carried here for the wash's colour and nothing else read them, so
    /// they left with it rather than lingering as state nothing consults. The
    /// theme still reaches the column through ``SidebarHost/theme``, which is
    /// where it was always doing visible work.
    private var titlebarGlass: TitlebarGlassBacking?

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
        resolvedChrome: ResolvedChrome
    ) {
        self.tree = tree
        self.sidebar = sidebar
        self.isTransparent = isTransparent
        self.blurRadius = blurRadius
        self.isDark = isDark
        self.resolvedChrome = resolvedChrome
        toolbar = NSToolbar(identifier: "baia.workspace.toolbar")
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        // The sidebar is the content and adopts the tree as a child, so the tree
        // still owns every pane and the window still has one content controller.
        // Showing nothing is a column of zero width, not a different content view.
        window.contentViewController = sidebar
        window.title = "baia"

        // **An empty toolbar, which is what gives the window a titlebar at all
        // on macOS 26.**
        //
        // Since the window became genuinely non-opaque (`331b7ec`, `isOpaque =
        // false` and a clear `backgroundColor` whenever `backgroundOpacity <
        // 1`), the titlebar region had no material in it: the traffic lights and
        // the title floated on whatever the desktop happened to show behind the
        // window. A titled `NSWindow` does not draw its own titlebar material on
        // 26 — the material arrives with an `NSToolbar`, per the research record
        // (`vault/projects/baia/liquid-glass-research.md` §4: "the glass comes
        // from `NSToolbar` and window style, not new window flags").
        //
        // Measured in `Diagnostics/titlebar-toolbar`, sampling a column clear of
        // the traffic lights: with no toolbar the strip reads the content behind
        // it and varies down its height, and with a toolbar it reads one flat
        // neutral all the way down, which is the system material compositing
        // over whatever is behind the window.
        //
        // **The toolbar is necessary and was not sufficient.** This shipped in
        // `5f3b88c` and the owner still saw no titlebar, because the material
        // also needs a non-clear window background to composite against — see
        // ``applyTransparency()``, which carries that measurement. The toolbar
        // is still what asks for the material; that is what makes it possible
        // to draw at all.
        //
        // **Empty on purpose, and empty is honest.** baia's controls live in the
        // footer and the command palette by design; the toolbar exists here for
        // the material and the standard titlebar metrics, not to hold anything.
        // The owner's principle is to go full macOS and not mimic anything that
        // has a standard function, so inventing toolbar buttons to justify the
        // toolbar would be the same mistake as hand-drawing a scrim. No delegate
        // is set, which is what keeps it item-less: a toolbar with no delegate
        // and no items renders as bare titlebar, and the title still shows.
        //
        // **Unconditional, unlike everything else on this window.** The
        // transparency and blur above are settings-driven; this is not part of
        // the glass/flat split. At `backgroundOpacity == 1` the window is opaque
        // and the toolbar's material over it is simply the standard macOS
        // titlebar, which is the correct look there too, so there is nothing to
        // gate on.
        window.toolbar = toolbar

        // `.unifiedCompact` rather than `.unified`. Both produce the material —
        // the two arms measured identically flat in the probe — and they differ
        // only in the chrome height they cost the content: 40 pt against 52 pt,
        // where no toolbar at all is 32 pt. baia's own chrome is built at the
        // 22 pt footer scale, and this is a terminal workspace where every point
        // taken off the titlebar is a row of cells given back to the grid, so
        // the compact metric is the one that matches.
        //
        // Both styles stack `window.title` over `window.subtitle`, which is what
        // `AppDelegate` writes the project path into, so neither loses the
        // project name; compact simply spends less height doing it.
        window.toolbarStyle = .unifiedCompact

        // Assigning a contentViewController makes the window adopt the content's
        // fitting size and discard the contentRect above, so the size is set
        // after the assignment, not before. contentMinSize stops a future layout
        // change from collapsing the window to an invisible sliver.
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.setContentSize(NSSize(width: 1024, height: 680))
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
        // And the same again for the titlebar's glass. Called after
        // `contentViewController` is assigned above, which is what gives the
        // window a `contentView` and therefore a frame view to parent into;
        // called before the window is ever shown, so no frame of the system
        // slab is visible under a glass build.
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
    /// measurably not the fix.** The platform recipe for chrome over content is
    /// content extending under the titlebar, so the probe carries an arm that
    /// does exactly that — `.fullSizeContentView` with the well anchored to the
    /// safe area, so the backing extends while the visible layout does not
    /// move. Its band spreads 63.6, which is the bare-titlebar number. Content
    /// beneath the band is not what the material samples; the window background
    /// is. That arm is kept in the probe rather than deleted, because "we tried
    /// the obvious platform arrangement and measured it not working" is the
    /// part a later reader will otherwise re-derive.
    ///
    /// **Nothing changes at `backgroundOpacity == 1`.** That path is the `else`
    /// here and still writes `.windowBackgroundColor` on an opaque window,
    /// which is byte-for-byte what it has always written. The toolbar already
    /// worked there.
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
    /// hierarchy and its system-drawn chrome — the titlebar material the
    /// empty toolbar asks for and the tab bar — while every other window
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
    /// band is no longer empty afterwards — the flag removes the slab and this
    /// view replaces it, which is the arrangement the earlier commit had no
    /// reason to try. The toolbar stays regardless, and measurably must: it is
    /// what buys the 40 pt `.unifiedCompact` metric, and the probe asserts the
    /// band is still 40 pt with the flag set, the title and subtitle still
    /// present, and the toolbar still reporting visible.
    ///
    /// **Why the frame view, which is an AppKit internal.** The band sits
    /// *above* `contentView`, and there are three ways to reach it. Parenting
    /// in the contentViewController's own view needs `.fullSizeContentView` to
    /// extend that view under the titlebar, and the probe's `glass-in-content`
    /// arm measures what that costs: `contentLayoutRect` drops from 292 to 220
    /// pt. That rect is what the pane tree lays out against, so adopting it
    /// would resize every ghostty grid and `SIGWINCH` every running shell —
    /// disqualifying on its own, and the arm is kept in the probe with an
    /// assertion so the trade is not re-derived. A toolbar item filling the
    /// band would be the third way and is refused on the owner's "go full
    /// macOS" rule: it means inventing a fake item to carry a background,
    /// which is mimicry of chrome the platform already draws.
    ///
    /// So `contentView.superview`. It is undocumented in the sense that no
    /// header names it, and it is not fragile in the way that usually implies:
    /// it is reached through a public property (`NSView.superview`), the code
    /// degrades to the current system titlebar if it is ever `nil` rather than
    /// crashing or drawing wrong, and nothing here depends on its class, its
    /// subview order, or any selector it responds to. The `guard` below is the
    /// whole *caught* failure path, and it covers the frame view being absent;
    /// a frame view whose layout semantics change under a future macOS is an
    /// uncaught, visual-only failure (glass clipped or mis-stacked, never a
    /// crash or a resize), which is what to re-check on each macOS major.
    ///
    /// **No geometry moves**, which the probe asserts rather than this comment
    /// claiming: adding and removing the backing on a live window, four times,
    /// leaves `contentView`, `contentLayoutRect` and the window frame identical
    /// across all five states. The band this covers is chrome AppKit already
    /// owned; the pane tree's rect is untouched, so no grid resizes and nothing
    /// running in a pane is signalled. That is what makes this safe to toggle
    /// live from a settings edit rather than only at window creation.
    private func applyTitlebarGlass() {
        switch resolvedChrome {
        case .flat:
            // Back to the system's own titlebar, byte for byte what `78aadfe`
            // shipped: the flag off means AppKit paints the slab again.
            window.titlebarAppearsTransparent = false
            titlebarGlass?.removeFromSuperview()
            titlebarGlass = nil

        case .glass:
            window.titlebarAppearsTransparent = true
            guard titlebarGlass == nil, let frameView = window.contentView?.superview else { break }

            let backing = TitlebarGlassBacking(frame: .zero)
            backing.style = .regular
            backing.cornerRadius = 0
            backing.wantsLayer = true
            // Below every sibling, so the traffic lights, the title, the
            // toolbar and the tab bar all render over it rather than under it.
            // The sidebar's backing takes the same position in its own host and
            // for the same reason: glass that is not at the back samples this
            // app's views instead of what is behind the window.
            frameView.addSubview(backing, positioned: .below, relativeTo: nil)
            titlebarGlass = backing

            updateTitlebarGlassTint()
            layoutTitlebarGlass()
        }
    }

    /// Frames the glass to the titlebar band.
    ///
    /// The band's height is derived rather than written as 40: it is whatever
    /// the window is currently spending on chrome, so a toolbar style change or
    /// a system metric this app does not control cannot leave the glass short
    /// of the band it is backing. Called from ``applyTitlebarGlass()`` and from
    /// the resize delegate, since the width tracks the window and an
    /// autoresizing mask alone would not survive the band's height changing
    /// when a tab bar appears.
    private func layoutTitlebarGlass() {
        guard let titlebarGlass, let frameView = titlebarGlass.superview else { return }
        let bandHeight = window.frame.height - window.contentLayoutRect.height
        let band = NSRect(
            x: 0,
            y: frameView.bounds.height - bandHeight,
            width: frameView.bounds.width,
            height: bandHeight
        )
        titlebarGlass.frame = band
    }

    /// Writes ``fillMaterial``'s colour onto ``titlebarGlass``, or nil — which
    /// is what ships and what every Release build resolves.
    ///
    /// **This was a write-once `titlebarGlassTint` static until the design panel
    /// needed one**, spelled out rather than left at the type's default so the
    /// "never set a tint" rule was defended by a line saying why it must stay nil
    /// rather than by a silent default nobody has to contradict. The panel is the
    /// deliberate, reversible contradiction; with it silent this resolves nil and
    /// the band is exactly as untinted as it was. See ``SurfaceFill``.
    ///
    /// A method rather than the creation-time assignment it replaces, because
    /// ``applyTitlebarGlass()`` returns early when the band already exists.
    private func updateTitlebarGlassTint() {
        guard let titlebarGlass, case let .glass(set) = resolvedChrome else { return }
        titlebarGlass.tintColor = SurfaceFill.colour(fillMaterial, in: set)
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
        // The band spans the window's width and its height changes when a tab
        // bar joins or leaves, so the glass is reframed here rather than left
        // to an autoresizing mask, which could follow the width and not the
        // height. No-op under flat, where there is no glass to frame.
        layoutTitlebarGlass()
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
