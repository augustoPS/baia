import AppKit
import UserNotifications

/// Reads and requests user-notification authorization without the notifier
/// talking to `UNUserNotificationCenter` in tests.
@MainActor
protocol AttentionAuthorizationClient: AnyObject {
    func requestAuthorization(completion: @escaping @MainActor (Bool) -> Void)
    func readAuthorization(completion: @escaping @MainActor (AttentionNotificationPermission) -> Void)
}

/// What Settings can show, and what `notify` uses for the banner.
enum AttentionNotificationPermission: Equatable, Sendable {
    /// No determined answer yet: first prompt still up, or never asked.
    case unknown
    case denied
    case authorized
}

extension Notification.Name {
    /// Posted on the main actor after the notifier's effective permission
    /// changes. The notifier is the notification object.
    static let attentionNotificationPermissionDidChange = Notification.Name(
        "AttentionNotificationPermissionDidChange"
    )
}

/// The live `UNUserNotificationCenter`. Kept here so tests inject a fake
/// without adding a notifications package.
@MainActor
final class SystemAttentionAuthorizationClient: AttentionAuthorizationClient {
    func requestAuthorization(completion: @escaping @MainActor (Bool) -> Void) {
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
                    MainActor.assumeIsolated { completion(granted) }
                }
            }
    }

    func readAuthorization(completion: @escaping @MainActor (AttentionNotificationPermission) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let permission: AttentionNotificationPermission
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                permission = .authorized
            case .denied:
                permission = .denied
            default:
                permission = .unknown
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(permission) }
            }
        }
    }
}

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
///
/// Authorization is requested once at launch. After that, ``refreshAuthorization()``
/// rereads the current UN settings on activation and when the baia setting turns
/// on. A stale callback from an older read cannot overwrite a newer one.
@MainActor
final class AttentionNotifier {
    /// From `notificationsEnabled`. Gates bounce and banner together: turning
    /// the setting off and still having the Dock jump would read as the setting
    /// not working. The per-pane capsule marker and the window title are not
    /// covered by it.
    var isEnabled = true {
        didSet {
            guard isEnabled, !oldValue else { return }
            refreshAuthorization()
        }
    }

    /// Effective UN authorization. Settings can show this; `notify` uses it for
    /// the banner only.
    private(set) var permission: AttentionNotificationPermission = .unknown

    var isAuthorized: Bool { permission == .authorized }

    /// Test seams. Production leaves them nil and uses AppKit / UN directly.
    var onUserAttention: (() -> Void)?
    var onPost: ((UNNotificationRequest) -> Void)?

    private var hasRequested = false
    private var requestSettled = false
    private var authorizationGeneration: UInt64 = 0
    private let client: AttentionAuthorizationClient
    private let allowsAuthorizationRequest: Bool
    /// Stored so deinit can unregister. `nonisolated(unsafe)` because deinit is
    /// not on the main actor; the token is only mutated at init and deinit.
    nonisolated(unsafe) private var activationObserver: (any NSObjectProtocol)?

    convenience init() {
        self.init(
            client: SystemAttentionAuthorizationClient(),
            observesActivation: true,
            allowsAuthorizationRequest: Bundle.main.bundleIdentifier != nil
        )
    }

    init(
        client: AttentionAuthorizationClient,
        observesActivation: Bool,
        allowsAuthorizationRequest: Bool
    ) {
        self.client = client
        self.allowsAuthorizationRequest = allowsAuthorizationRequest
        if observesActivation {
            // `queue: nil` delivers on the posting thread. AppKit posts
            // `didBecomeActive` on the main thread, so this matches production
            // and a test that posts the same name from the main actor sees the
            // read start before the post returns.
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self?.refreshAuthorization()
                    }
                } else {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.refreshAuthorization()
                        }
                    }
                }
            }
        }
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    /// Asked once, at launch rather than at the first bell, so the permission
    /// prompt does not appear in the middle of the work the user was watching.
    /// Later System Settings changes are picked up by ``refreshAuthorization()``,
    /// not by asking again.
    func requestAuthorizationIfNeeded() {
        guard !hasRequested, allowsAuthorizationRequest else { return }
        hasRequested = true
        let generation = beginAuthorizationRead()
        client.requestAuthorization { [weak self] granted in
            self?.requestSettled = true
            self?.apply(
                granted ? .authorized : .denied,
                generation: generation
            )
        }
    }

    /// Rereads current UN authorization. Used on app activation and when the
    /// baia notifications setting turns on. Does not prompt. Skipped while the
    /// first request is still in flight so an activation `.notDetermined` cannot
    /// settle as a denial that then ignores the grant.
    func refreshAuthorization() {
        guard !(hasRequested && !requestSettled) else { return }
        let generation = beginAuthorizationRead()
        client.readAuthorization { [weak self] permission in
            self?.apply(permission, generation: generation)
        }
    }

    private func beginAuthorizationRead() -> UInt64 {
        authorizationGeneration += 1
        return authorizationGeneration
    }

    private func apply(_ permission: AttentionNotificationPermission, generation: UInt64) {
        guard generation == authorizationGeneration else { return }
        if permission == .unknown, hasRequested, !requestSettled { return }
        guard permission != self.permission else { return }
        self.permission = permission
        NotificationCenter.default.post(
            name: .attentionNotificationPermissionDidChange,
            object: self
        )
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
        if let onUserAttention {
            onUserAttention()
        } else {
            NSApp.requestUserAttention(.informationalRequest)
        }

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
        if let onPost {
            onPost(request)
        } else {
            UNUserNotificationCenter.current().add(request)
        }
    }
}
