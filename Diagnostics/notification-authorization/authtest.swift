import AppKit
import Foundation
import UserNotifications

/// Focused R12 checks for refresh, publication, stale-read ordering, and the
/// notification gates. Compiled with `Sources/AttentionNotifier.swift`; it does
/// not launch baia or touch OS permission.
@MainActor
final class FakeAuthorizationClient: AttentionAuthorizationClient {
    var requestCount = 0
    var readCount = 0
    var pendingRequests: [(Bool) -> Void] = []
    var pendingReads: [(AttentionNotificationPermission) -> Void] = []

    func requestAuthorization(completion: @escaping @MainActor (Bool) -> Void) {
        requestCount += 1
        pendingRequests.append(completion)
    }

    func readAuthorization(completion: @escaping @MainActor (AttentionNotificationPermission) -> Void) {
        readCount += 1
        pendingReads.append(completion)
    }

    func completeRequest(_ granted: Bool) {
        pendingRequests.removeFirst()(granted)
    }

    func completeRead(_ permission: AttentionNotificationPermission) {
        completeRead(permission, index: 0)
    }

    /// Completes a specific in-flight settings read. Index 0 is the oldest.
    /// Completing the newest first, then the oldest, is the stale-callback case:
    /// FIFO `removeFirst` twice would apply denied then authorized and pass even
    /// with the generation guard removed.
    func completeRead(_ permission: AttentionNotificationPermission, index: Int) {
        pendingReads.remove(at: index)(permission)
    }
}

@MainActor
enum AuthTest {
    static var failures = 0

    static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            print("ok    \(name)")
        } else {
            failures += 1
            print("FAIL  \(name)\(detail.isEmpty ? "" : ": \(detail)")")
        }
    }

    static func makeNotifier(_ client: FakeAuthorizationClient) -> AttentionNotifier {
        AttentionNotifier(
            client: client,
            observesActivation: false,
            allowsAuthorizationRequest: true
        )
    }

    static func run() {
        staleRefreshMustNotBeOverwrittenByAnOlderRequest()
        undeterminedRefreshDoesNotSettleAnInFlightPrompt()
        requestAuthorizationIsAskedOnce()
        refreshReadsSettingsAndDoesNotPrompt()
        enablingTheSettingRefreshesAuthorization()
        activationNotificationRefreshesAuthorization()
        permissionChangesArePublishedToObservers()
        disabledSettingSuppressesBounceAndBanner()
        unauthorizedEnabledSettingBouncesWithoutABanner()
        authorizedEnabledNotifyPostsExactlyOnce()

        if failures == 0 {
            print("PASS all notification-authorization checks")
        } else {
            print("FAILED \(failures) notification-authorization checks")
        }
        exit(failures == 0 ? 0 : 1)
    }

    /// The R12 defect: an older denied settings read completing after a newer
    /// authorized one would pin the notifier to denied until relaunch.
    static func staleRefreshMustNotBeOverwrittenByAnOlderRequest() {
        let client = FakeAuthorizationClient()
        let notifier = makeNotifier(client)
        notifier.requestAuthorizationIfNeeded()
        client.completeRequest(false)
        notifier.refreshAuthorization()
        notifier.refreshAuthorization()
        check("two settings reads are pending", client.pendingReads.count == 2)
        // Newest first (index 1), then the leftover oldest (index 0). A FIFO
        // complete-denied-then-authorized sequence would still end authorized
        // with the generation guard deleted; this order is the one that fails
        // the mutant in r12-review-control.json.
        client.completeRead(.authorized, index: 1)
        client.completeRead(.denied, index: 0)
        check(
            "a later refresh survives a stale denied settings callback",
            notifier.isAuthorized,
            "expected authorized, got \(notifier.isAuthorized)"
        )
        check(
            "effective permission is authorized after the newer refresh",
            notifier.permission == .authorized
        )
    }

    /// Activation during the first prompt sees `.notDetermined`. That must not
    /// start a read that could settle as a denial and then ignore the grant.
    static func undeterminedRefreshDoesNotSettleAnInFlightPrompt() {
        let client = FakeAuthorizationClient()
        let notifier = makeNotifier(client)
        notifier.requestAuthorizationIfNeeded()
        notifier.refreshAuthorization()
        check("refresh is deferred while the first prompt is in flight", client.readCount == 0)
        client.completeRequest(true)
        check(
            "the in-flight grant still lands",
            notifier.isAuthorized
        )
    }

    static func requestAuthorizationIsAskedOnce() {
        let client = FakeAuthorizationClient()
        let notifier = makeNotifier(client)
        notifier.requestAuthorizationIfNeeded()
        notifier.requestAuthorizationIfNeeded()
        check("authorization is requested once", client.requestCount == 1, "count \(client.requestCount)")
        client.completeRequest(false)
        notifier.refreshAuthorization()
        check("a refresh after the prompt does not request again", client.requestCount == 1)
    }

    static func refreshReadsSettingsAndDoesNotPrompt() {
        let client = FakeAuthorizationClient()
        let notifier = makeNotifier(client)
        notifier.requestAuthorizationIfNeeded()
        client.completeRequest(false)
        notifier.refreshAuthorization()
        check("refresh reads current UN settings", client.readCount == 1, "reads \(client.readCount)")
        client.completeRead(.authorized)
        check("refresh adopts the current authorization", notifier.isAuthorized)
    }

    static func enablingTheSettingRefreshesAuthorization() {
        let client = FakeAuthorizationClient()
        let notifier = makeNotifier(client)
        notifier.isEnabled = false
        let readsBefore = client.readCount
        notifier.isEnabled = true
        check(
            "turning the setting on reads authorization",
            client.readCount == readsBefore + 1,
            "reads \(client.readCount)"
        )
        notifier.isEnabled = true
        check("a redundant enable does not issue another read", client.readCount == readsBefore + 1)
    }

    static func disabledSettingSuppressesBounceAndBanner() {
        let client = FakeAuthorizationClient()
        let notifier = makeNotifier(client)
        var bounces = 0
        var posts = 0
        notifier.onUserAttention = { bounces += 1 }
        notifier.onPost = { _ in posts += 1 }
        notifier.isEnabled = false
        notifier.requestAuthorizationIfNeeded()
        client.completeRequest(true)
        notifier.notify(project: "vault", message: "blocked")
        check("disabled setting suppresses the dock bounce", bounces == 0, "bounces \(bounces)")
        check("disabled setting suppresses the banner", posts == 0, "posts \(posts)")
    }

    static func activationNotificationRefreshesAuthorization() {
        let client = FakeAuthorizationClient()
        let notifier = AttentionNotifier(
            client: client,
            observesActivation: true,
            allowsAuthorizationRequest: true
        )
        notifier.requestAuthorizationIfNeeded()
        client.completeRequest(false)
        let readsBefore = client.readCount
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        check(
            "didBecomeActive starts a settings read",
            client.readCount == readsBefore + 1,
            "reads \(client.readCount)"
        )
        client.completeRead(.authorized)
        check("activation refresh adopts current authorization", notifier.isAuthorized)
    }

    static func permissionChangesArePublishedToObservers() {
        let client = FakeAuthorizationClient()
        let notifier = makeNotifier(client)
        var observed: [AttentionNotificationPermission] = []
        let token = NotificationCenter.default.addObserver(
            forName: .attentionNotificationPermissionDidChange,
            object: notifier,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                observed.append(notifier.permission)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        notifier.requestAuthorizationIfNeeded()
        client.completeRequest(false)
        notifier.refreshAuthorization()
        client.completeRead(.authorized)
        notifier.refreshAuthorization()
        client.completeRead(.authorized)

        check(
            "observers receive each effective permission change once",
            observed == [.denied, .authorized],
            "observed \(observed)"
        )
    }

    static func unauthorizedEnabledSettingBouncesWithoutABanner() {
        let client = FakeAuthorizationClient()
        let notifier = makeNotifier(client)
        var bounces = 0
        var posts = 0
        notifier.onUserAttention = { bounces += 1 }
        notifier.onPost = { _ in posts += 1 }
        notifier.requestAuthorizationIfNeeded()
        client.completeRequest(false)
        notifier.notify(project: "vault", message: "blocked")
        check("bounce still runs without authorization", bounces == 1, "bounces \(bounces)")
        check("banner waits for authorization", posts == 0, "posts \(posts)")
    }

    static func authorizedEnabledNotifyPostsExactlyOnce() {
        let client = FakeAuthorizationClient()
        let notifier = makeNotifier(client)
        var bounces = 0
        var posts = 0
        notifier.onUserAttention = { bounces += 1 }
        notifier.onPost = { _ in posts += 1 }
        notifier.requestAuthorizationIfNeeded()
        client.completeRequest(true)
        notifier.notify(project: "vault", message: "blocked")
        check("authorized enabled notify bounces once", bounces == 1, "bounces \(bounces)")
        check("authorized enabled notify posts exactly once", posts == 1, "posts \(posts)")
    }
}

@main
enum AuthTestMain {
    static func main() {
        AuthTest.run()
    }
}
