import AppKit
import PaneChrome

/// Watches the two system inputs `resolvedStyle(setting:appearance:)` needs
/// and republishes a `ChromeAppearance` whenever either moves.
///
/// **The only place in the app that reads `NSApp.effectiveAppearance` or
/// `NSWorkspace`'s accessibility flags for the chrome-material question.**
/// `PaneChrome`'s own header on `ChromeAppearance` says why the split has to
/// be this clean: the package that decides which material set draws must stay
/// free of AppKit so it stays inside `make test`, and the live reads that
/// package cannot make for itself belong in exactly one app-target object
/// rather than scattered across every view that ends up drawing glass. A
/// second observer reading the same two flags on its own schedule is how two
/// views come to disagree about whether Reduce Transparency is on this frame.
///
/// Two independent sources feed one value: `NSWorkspace.shared`'s
/// accessibility flags change on `accessibilityDisplayOptionsDidChangeNotification`,
/// posted on `NSWorkspace.shared.notificationCenter`, not the default center;
/// the effective appearance changes
/// on nothing NSWorkspace ever posts, because it is a property of whichever
/// `NSApplication` (or, in principle, a specific view) is asked, so it is
/// picked up by KVO on `NSApp.effectiveAppearance` instead. Missing either
/// source would leave the chrome one flag stale: dark/light flipping with
/// Reduce Transparency left alone, or the reverse.
@MainActor
final class AppearanceObserver: NSObject {
    /// Raised on the main thread whenever the published `ChromeAppearance`
    /// would compare unequal to the last one sent, mirroring
    /// `ConfigurationCenter.onSettingsChange`'s shape so a caller wires both
    /// the same way.
    var onAppearanceChange: ((ChromeAppearance) -> Void)?

    private(set) var appearance: ChromeAppearance

    private var effectiveAppearanceObservation: NSKeyValueObservation?

    override init() {
        appearance = Self.readCurrentAppearance()
        super.init()
        startObserving()
    }

    deinit {
        // KVO observations and NSNotificationCenter tokens both invalidate
        // themselves on deallocation in modern AppKit, but this object is a
        // long-lived singleton owned by `AppDelegate` for the life of the
        // process, so the deinit is dead code in practice. Cancelling
        // explicitly here costs nothing and removes any doubt for whichever
        // future refactor makes this object short-lived.
        effectiveAppearanceObservation?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func startObserving() {
        // `effectiveAppearance` is KVO-compliant on `NSApplication`; nothing
        // else in AppKit posts a notification when it changes, because it can
        // change per-view as well as per-app and there is no single event that
        // covers every way it moves. KVO is the one channel that does.
        effectiveAppearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            // The closure can fire on a thread KVO chose; hop back to main
            // before touching `appearance` or calling `onAppearanceChange`,
            // the same guarantee `ConfigurationCenter`'s file-watch reload
            // gives its own callers.
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }

        // `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`
        // fires for both Reduce Transparency and Reduce Motion, System
        // Settings > Accessibility > Display having no finer-grained
        // notification for the two independently. AppKit posts it on
        // `NSWorkspace.shared.notificationCenter`, never on the default
        // center, so the subscription has to register there too.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared
        )
    }

    @objc private func accessibilityOptionsDidChange() {
        refresh()
    }

    private func refresh() {
        let updated = Self.readCurrentAppearance()
        guard updated != appearance else { return }
        appearance = updated
        onAppearanceChange?(updated)
    }

    /// One read of all three fields, so `init` and every subsequent refresh
    /// build a `ChromeAppearance` the same way rather than assembling it field
    /// by field at two call sites that could drift.
    private static func readCurrentAppearance() -> ChromeAppearance {
        ChromeAppearance(
            isDark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }
}
