#if DEBUG
import AppKit
import Foundation
import WorkspaceLayout

/// Drives the real recovery and termination alerts inside an isolated Debug app.
/// External accessibility drivers cannot address this app on the review machine.
@MainActor
enum SessionSelfCheck {
    private static var output: URL?

    static func runIfRequested(in delegate: AppDelegate) {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["BAIA_SESSION_SELFCHECK_MODE"],
              let path = env["BAIA_SESSION_SELFCHECK_OUTPUT"], !path.isEmpty
        else { return }
        guard SupportDirectory.name.hasPrefix("baia-session-recovery-"),
              let config = env["BAIA_CONFIG_FILE"], !config.isEmpty,
              path.hasPrefix("/")
        else {
            FileHandle.standardError.write(Data("baia: refused unsafe session self-check instance\n".utf8))
            return
        }
        output = URL(filePath: path)
        try? Data().write(to: output!)
        after(0.5) {
            switch mode {
            case "mutation": mutateWorkspace(in: delegate)
            case "keep-file":
                launchSheet(in: delegate, click: "Keep File")
                after(0.2) { mutateWorkspace(in: delegate) }
            case "recovery-success":
                launchSheet(in: delegate, click: "Keep File")
                after(0.2) { recoveryMenu(in: delegate) }
                after(0.8) { recoverySucceeded(in: delegate) }
            case "recovery-refusal": recoveryRefusal(in: delegate)
            case "quit-save-failure": quitFailure(in: delegate)
            default: emit("failure unknown-mode")
            }
        }
    }

    private static func launchSheet(in delegate: AppDelegate, click title: String) {
        let sheet = delegate.windows.first?.window.attachedSheet
        let titles = buttons(in: sheet).map(\.title)
        emit("launch-sheet \(titles.joined(separator: "|"))")
        guard titles.contains("Back Up and Replace"), titles.contains("Keep File") else {
            return emit("failure launch-sheet")
        }
        clickButton(title, in: sheet)
        emit(title == "Keep File" ? "keep-file" : "replace-requested")
    }

    private static func recoveryMenu(in delegate: AppDelegate) {
        guard let item = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?
            .submenu?.items.first(where: { $0.title == "Recover Session…" })
        else { return emit("failure recovery-menu-missing") }
        let enabled = delegate.validateMenuItem(item)
        emit("menu enabled=\(enabled)")
        guard enabled, let action = item.action, NSApp.sendAction(action, to: nil, from: item)
        else { return emit("failure recovery-menu-action") }
    }

    private static func mutateWorkspace(in delegate: AppDelegate) {
        guard let controller = delegate.windows.first else {
            return emit("mutation split=false resize=false")
        }
        let paneCount = controller.tree.paneCount
        delegate.splitPaneRight(nil)
        let split = controller.tree.paneCount == paneCount + 1
        let beforeResize = controller.snapshot?.tab.tree
        delegate.growPaneLeft(nil)
        let resized = controller.snapshot?.tab.tree != beforeResize
        emit("mutation split=\(split) resize=\(resized)")
    }

    private static func recoverySucceeded(in delegate: AppDelegate) {
        let session = sessionURL()
        let backup = session.appendingPathExtension("rejected-backup")
        let backupExists = FileManager.default.fileExists(atPath: backup.path(percentEncoded: false))
        let valid: Bool
        if case .loaded = SessionStore(fileURL: session).inspect() { valid = true } else { valid = false }
        let titles = buttons(in: delegate.windows.first?.window.attachedSheet).map(\.title)
        emit("recovery-success backup=\(backupExists) saved=\(valid) buttons=\(titles.joined(separator: "|"))")
        clickButton("OK", in: delegate.windows.first?.window.attachedSheet)
        NSApp.terminate(nil)
    }

    private static func recoveryRefusal(in delegate: AppDelegate) {
        let directory = sessionURL().deletingLastPathComponent()
        setPermissions(0o500, on: directory)
        launchSheet(in: delegate, click: "Back Up and Replace")
        after(0.5) {
            let sheet = delegate.windows.first?.window.attachedSheet
            let titles = buttons(in: sheet).map(\.title)
            emit("recovery-refused \(titles.joined(separator: "|"))")
            clickButton("Keep File", in: sheet)
            setPermissions(0o700, on: directory)
            NSApp.terminate(nil)
        }
    }

    private static func quitFailure(in delegate: AppDelegate) {
        let directory = sessionURL().deletingLastPathComponent()
        setPermissions(0o500, on: directory)
        after(0.2) {
            let titles = buttons(in: NSApp.modalWindow).map(\.title)
            emit("quit-alert \(titles.joined(separator: "|"))")
            clickButton("Cancel Quit", in: NSApp.modalWindow)
        }
        NSApp.terminate(nil)
        emit("quit-cancelled windows=\(delegate.windows.count)")
        after(0.2) {
            let titles = buttons(in: NSApp.modalWindow).map(\.title)
            emit("quit-retry-alert \(titles.joined(separator: "|"))")
            setPermissions(0o700, on: directory)
            emit("quit-retry")
            clickButton("Retry", in: NSApp.modalWindow)
        }
        NSApp.terminate(nil)
    }

    private static func sessionURL() -> URL {
        SessionStore.defaultFileURL(directoryName: SupportDirectory.name)
    }

    private static func setPermissions(_ permissions: Int, on url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    private static func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func buttons(in window: NSWindow?) -> [NSButton] {
        guard let root = window?.contentView else { return [] }
        return descendants(root).compactMap { $0 as? NSButton }
    }

    private static func clickButton(_ title: String, in window: NSWindow?) {
        guard let button = buttons(in: window).first(where: { $0.title == title })
        else { return emit("failure missing-button \(title)") }
        button.performClick(nil)
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func emit(_ line: String) {
        guard let output else { return }
        guard let handle = try? FileHandle(forWritingTo: output) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}
#endif
