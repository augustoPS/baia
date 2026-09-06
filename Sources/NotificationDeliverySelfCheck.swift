#if DEBUG
import Foundation
import UserNotifications

/// Same-process delivered-notification snapshot for the disposable
/// notification-permission fixture. Release and ungated Debug copies compile
/// this file out or return before installing anything.
enum NotificationDeliverySelfCheck {
    private static var observer: DeliveryObserver?

    static func installIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let commandPath = environment["BAIA_NOTIFICATION_DELIVERY_COMMAND"],
              !commandPath.isEmpty,
              let resultPath = environment["BAIA_NOTIFICATION_DELIVERY_RESULT"],
              !resultPath.isEmpty
        else { return }
        guard let command = ownedFile(commandPath, expectedName: "delivery-command.json"),
              let result = ownedFile(resultPath, expectedName: "delivery-result.json"),
              command != result
        else {
            FileHandle.standardError.write(
                Data("baia: refused unsafe notification-delivery self-check instance\n".utf8)
            )
            return
        }
        let observer = DeliveryObserver(command: command, result: result)
        self.observer = observer
        observer.start()
    }

    fileprivate static func finish(_ data: Data?) {
        observer?.complete(data)
    }

    private static func ownedFile(_ path: String, expectedName: String) -> URL? {
        guard path.hasPrefix("/"),
              !path.contains("\0"),
              URL(filePath: path).lastPathComponent == expectedName
        else { return nil }
        guard identityIsDisposable(), let scratch = disposableScratch() else { return nil }
        let resolved = URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL
        guard resolved.lastPathComponent == expectedName, isInside(resolved, scratch: scratch) else {
            return nil
        }
        return resolved
    }

    private static func identityIsDisposable() -> Bool {
        guard let bundle = Bundle.main.bundleIdentifier,
              bundle.hasPrefix("pasqualotto.baia.notification-permission."),
              bundle != "pasqualotto.baia",
              bundle != "pasqualotto.baia.dev"
        else { return false }
        let support = SupportDirectory.name
        return support.hasPrefix("baia-notification-permission.")
            && support != "baia"
            && support != "baia-dev"
    }

    private static func disposableScratch() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        guard let configPath = environment["BAIA_CONFIG_FILE"], configPath.hasPrefix("/") else {
            return nil
        }
        let config = URL(filePath: configPath).resolvingSymlinksInPath().standardizedFileURL
        guard config.lastPathComponent == "config.json" else { return nil }
        let scratch = config.deletingLastPathComponent()
        guard scratch.lastPathComponent.hasPrefix("baia-notification-permission.") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: scratch.path(percentEncoded: false),
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }
        if isProductPath(scratch) || isProductPath(config) { return nil }
        return scratch
    }

    private static func isProductPath(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let roots = [
            home.appending(path: ".config/baia", directoryHint: .isDirectory),
            home.appending(path: "Library/Application Support/baia", directoryHint: .isDirectory),
            home.appending(path: "Library/Application Support/baia-dev", directoryHint: .isDirectory),
        ]
        return roots.contains { root in
            let resolved = root.resolvingSymlinksInPath().standardizedFileURL
            return url.path == resolved.path || isInside(url, scratch: resolved)
        }
    }

    private static func isInside(_ url: URL, scratch: URL) -> Bool {
        let path = url.path
        let root = scratch.path
        guard !root.isEmpty else { return false }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) && path != root
    }
}

private final class DeliveryObserver {
    private let command: URL
    private let result: URL
    private var timer: Timer?
    private var inFlight = false

    init(command: URL, result: URL) {
        self.command = command
        self.result = result
    }

    func start() {
        let start = {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if Thread.isMainThread {
            start()
        } else {
            DispatchQueue.main.sync(execute: start)
        }
    }

    private func poll() {
        guard !inFlight else { return }
        let commandPath = command.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: commandPath) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: command)
            try FileManager.default.removeItem(at: command)
        } catch {
            return
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identifier = payload["id"] as? String,
              (1...128).contains(identifier.count),
              !identifier.contains("\n"),
              !identifier.contains("\r")
        else { return }
        guard payload["action"] as? String == "delivered" else {
            write([
                "id": identifier,
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "error": "unknown-action",
            ])
            return
        }
        inFlight = true
        let commandId = identifier
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let items: [[String: Any]] = notifications.compactMap { notification in
                let notificationIdentifier = notification.request.identifier
                guard notificationIdentifier.hasPrefix("baia.attention.") else { return nil }
                return [
                    "identifier": notificationIdentifier,
                    "body": notification.request.content.body,
                    "date": notification.date.timeIntervalSince1970,
                ]
            }
            let document: [String: Any] = [
                "id": commandId,
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "notifications": items,
            ]
            let data = try? JSONSerialization.data(
                withJSONObject: document,
                options: [.prettyPrinted, .sortedKeys]
            )
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NotificationDeliverySelfCheck.finish(data)
                }
            }
        }
    }

    fileprivate func complete(_ data: Data?) {
        if let data {
            try? data.write(to: result, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: result.path(percentEncoded: false)
            )
        }
        inFlight = false
    }

    private func write(_ document: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        complete(data)
    }
}
#endif
