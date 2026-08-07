import AppKit
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
    /// ``PaneChrome/windowBlurRadius(backgroundBlur:backgroundOpacity:appearance:)``
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

    /// `isTransparent` and `blurRadius` are parameters rather than later
    /// assignments for the reason ``ConfigurationCenter`` states about its own
    /// appearance observer: a caller cannot forget what it must name. It is also
    /// the reason ``SidebarHost`` takes its chrome. A window built opaque and
    /// made transparent a moment later would show one solid frame first.
    init(tree: PaneTreeController, sidebar: SidebarHost, isTransparent: Bool, blurRadius: Int) {
        self.tree = tree
        self.sidebar = sidebar
        self.isTransparent = isTransparent
        self.blurRadius = blurRadius
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
        // it and varies down its height (21,22,25 → 28,32,42), and with a
        // toolbar it reads one flat neutral (23,23,23) all the way down, which
        // is the system material compositing over whatever is behind the window.
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
    private func applyTransparency() {
        window.isOpaque = !isTransparent
        window.backgroundColor = isTransparent ? .clear : .windowBackgroundColor
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
