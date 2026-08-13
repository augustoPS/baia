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
/// **The bounce is the load-bearing part, and the window title carries the
/// count.** Not the badge, which does not work in this app and is not attempted;
/// the block on ``requestAuthorizationIfNeeded()`` records that investigation and
/// this line used to contradict it, which cost a live pass on 2026-07-30 looking
/// for a badge that was never going to appear.
///
/// Not the banner either. `UNUserNotificationCenter` needs authorization the user
/// can refuse, and a refused or undetermined state means the banner never appears.
/// So the indicator that cannot fail is applied first and the banner is posted on
/// top of it.
@MainActor
final class AttentionNotifier {
    /// From `notificationsEnabled`. Gates the banner only: the per-pane capsule
    /// marker and the window title are not covered by it, because a notification
    /// the user denied at the system level never appears and reports no error, so
    /// it can only ever be an addition to an indicator that already works.
    var isEnabled = true

    private var isAuthorized = false
    private var hasRequested = false

    /// Asked once, at launch rather than at the first bell, so the permission
    /// prompt does not appear in the middle of the work the user was watching.
    func requestAuthorizationIfNeeded() {
        guard !hasRequested, Bundle.main.bundleIdentifier != nil else { return }
        hasRequested = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                // Reported rather than dropped, because the error is the only
                // thing that separates a denial from silence. It says
                // "Notifications are not allowed for this application", and that
                // means the switch under System Settings > Notifications is off,
                // not that the app never registered. Read the other way on
                // 2026-07-30 and corrected on 2026-07-31: the app was listed
                // there the whole time, turned off, and enabling it made this
                // path succeed on an unchanged ad-hoc build out of `.build`.
                // `com.apple.ncprefs` is not where to check. It gained no entry
                // for `gutons.baia` even with the switch on and the banner
                // arriving.
                if let error {
                    FileHandle.standardError.write(Data(
                        "baia: notification authorization failed: \(error.localizedDescription)\n"
                            .utf8
                    ))
                }
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
    /// rules out the wiring and leaves the API itself.
    ///
    /// The placeholder icon was the leading suspect and has been ruled out
    /// (2026-07-25). baia now ships a real `.icns`, the Dock renders it, and a
    /// fixed `badgeLabel = "9"` set in `applicationDidFinishLaunching` still
    /// produces no badge on a tile that is otherwise drawing correctly. Whatever
    /// the cause is, it is not the icon. Ad-hoc signing and the hardened runtime
    /// are what remain untested; neither was worth chasing for an indicator that
    /// has a working substitute.
    ///
    /// The waiting count goes in the window title instead, which macOS does show
    /// for a background app in the Window menu, Mission Control, and the window
    /// switcher. That is the primary carrier rather than a fallback, precisely
    /// because this one is not coming back. `AppDelegate.updateWindowTitles`
    /// owns it.

    /// Posted when a pane starts asking while its window is not the key window.
    ///
    /// Nothing is posted for a focused window: the user is already looking at the
    /// pane, and a banner for something on screen is noise.
    func notify(project: String, message: String?) {
        // Both halves are gated, the bounce included. Turning notifications off
        // and still having the Dock jump would read as the setting not working.
        guard isEnabled else { return }
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
