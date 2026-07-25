import AppKit
import UserNotifications

/// Tells the user which pane wants them.
///
/// This exists because the signal it replaces carries no identity. The Stop hook
/// plays one `afplay Blow.aiff` for every session, so four concurrent agents
/// produce four identical sounds and the only way to find the one that finished
/// is to look at each pane in turn. A notification that names the project answers
/// it directly.
///
/// The dock badge and the bounce are the load-bearing part, not the banner.
/// `UNUserNotificationCenter` needs authorization the user can refuse, and a
/// refused or undetermined state means the banner never appears with no error at
/// the call site. So the indicator that cannot fail is applied first and the
/// banner is posted on top of it.
@MainActor
final class AttentionNotifier {
    private var isAuthorized = false
    private var hasRequested = false

    /// Asked once, at launch rather than at the first bell, so the permission
    /// prompt does not appear in the middle of the work the user was watching.
    func requestAuthorizationIfNeeded() {
        guard !hasRequested, Bundle.main.bundleIdentifier != nil else { return }
        hasRequested = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.isAuthorized = granted
                    }
                }
            }
    }

    /// The dock badge is deliberately not used, and this records why so it is not
    /// tried again.
    ///
    /// `NSApp.dockTile.badgeLabel` does nothing in this app. It was instrumented
    /// end to end: the attention closure fires with the right count, the label is
    /// assigned, `display()` is called, and the Dock still reports no badge for
    /// baia through accessibility and shows none on screen. Setting the label
    /// unconditionally at launch to a fixed string does not appear either, which
    /// rules out the wiring and leaves the API itself. baia is ad-hoc signed with
    /// a placeholder icon, and that is the likeliest cause, but it was not worth
    /// chasing for an indicator that has a working substitute.
    ///
    /// The waiting count goes in the window title instead, which macOS does show
    /// for a background app in the Window menu, Mission Control, and the window
    /// switcher. `AppDelegate.updateWindowTitle` owns it.

    /// Posted when a pane starts asking while its window is not the key window.
    ///
    /// Nothing is posted for a focused window: the user is already looking at the
    /// pane, and a banner for something on screen is noise.
    func notify(project: String, message: String?) {
        // Bouncing works with no authorization at all, so it happens whether or
        // not the banner will. `.informationalRequest` bounces once rather than
        // until the app is activated, which is right for a pane that will still
        // be waiting when the user gets to it.
        NSApp.requestUserAttention(.informationalRequest)

        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = project
        content.body = message ?? "Waiting for input"
        content.sound = nil
        // No trigger means deliver now. A nil identifier is not allowed, and
        // reusing one per project coalesces repeat requests from the same pane
        // instead of stacking a banner per bell.
        let request = UNNotificationRequest(
            identifier: "baia.attention.\(project)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
