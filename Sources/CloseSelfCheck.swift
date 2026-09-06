#if DEBUG
    import AppKit
    import Foundation
    import PaneActivity

    /// Drives the close policy (W01) against a real pane whose shell is running
    /// a foreground job, in an isolated Debug copy.
    ///
    /// The external fixture in `Diagnostics/busy-close` seeds a shell that runs
    /// `sleep` in the foreground, launches one mode per process, reads the
    /// events written here, and checks from outside that the job is gone once
    /// a close was confirmed. This side performs only what needs the live
    /// window: the production close actions and the sheet's buttons.
    @MainActor
    enum CloseSelfCheck {
        private static var output: URL?
        private static var failures = 0
        private static var closeObservers: [NSObjectProtocol] = []

        static func runIfRequested(in delegate: AppDelegate) {
            let environment = ProcessInfo.processInfo.environment
            guard let mode = environment["BAIA_CLOSE_SELFCHECK_MODE"],
                  let path = environment["BAIA_CLOSE_SELFCHECK_OUTPUT"], !path.isEmpty
            else { return }
            guard SupportDirectory.name.hasPrefix("baia-busy-close."),
                  environment["BAIA_CONFIG_FILE"]?.isEmpty == false,
                  path.hasPrefix("/")
            else {
                FileHandle.standardError.write(Data("baia: refused unsafe close self-check instance\n".utf8))
                return
            }
            output = URL(filePath: path)
            failures = 0
            try? Data().write(to: output!)
            // Each workspace window is observed by identity, so the note itself
            // never crosses an isolation boundary.
            for controller in delegate.windows {
                closeObservers.append(NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: controller.window, queue: .main
                ) { _ in
                    MainActor.assumeIsolated { emit("window-closed") }
                })
            }
            // The shell needs a moment to start its foreground job.
            after(1.5) {
                switch mode {
                case "busy-pane": busyPane(in: delegate)
                case "busy-quit": busyQuit(in: delegate)
                case "idle-pane": idlePane(in: delegate)
                default:
                    check("known mode", false, mode)
                    finish()
                }
            }
        }

        private static func busyPane(in delegate: AppDelegate) {
            guard let controller = delegate.windows.first else { return fail("no window") }
            let activity = controller.tree.focusedPane?.currentActivity
            check("the pane reports a running command", activity.map { !PaneActivity.isIdle($0) } == true,
                  "\(String(describing: activity))")
            emit("descendants \(descendantNames())")

            delegate.closePane(nil)
            let sheet = controller.window.attachedSheet
            let titles = buttons(in: sheet).map(\.title)
            emit("sheet \(titles.joined(separator: "|"))")
            check("close asked first", titles.sorted() == ["Cancel", "Close Pane"], "\(titles)")
            clickButton("Cancel", in: sheet)
            after(0.4) {
                check("cancel kept the pane", delegate.windows.count == 1 && controller.tree.paneCount == 1)
                check("cancel kept the job", descendantNames().contains("sleep"), "\(descendantNames())")
                delegate.closePane(nil)
                let sheet = controller.window.attachedSheet
                check("asked again on the second close", buttons(in: sheet).map(\.title).sorted() == ["Cancel", "Close Pane"])
                emit("self-check failures=\(failures)")
                // The last pane: confirming closes the window and the app quits
                // on its own. The fixture checks the sleep is gone from outside.
                emit("confirming")
                clickButton("Close Pane", in: sheet)
            }
        }

        private static func busyQuit(in delegate: AppDelegate) {
            guard let controller = delegate.windows.first else { return fail("no window") }
            check("the pane reports a running command",
                  controller.tree.focusedPane.map { !PaneActivity.isIdle($0.currentActivity) } == true)
            after(0.2) {
                let titles = buttons(in: NSApp.modalWindow).map(\.title)
                emit("quit-alert \(titles.joined(separator: "|"))")
                check("quit asked first", titles.sorted() == ["Cancel", "Quit"], "\(titles)")
                clickButton("Cancel", in: NSApp.modalWindow)
            }
            NSApp.terminate(nil)
            check("cancel kept the workspace", delegate.windows.count == 1 && controller.tree.paneCount == 1)
            check("cancel kept the job", descendantNames().contains("sleep"), "\(descendantNames())")
            emit("self-check failures=\(failures)")
            after(0.2) {
                emit("confirming")
                clickButton("Quit", in: NSApp.modalWindow)
            }
            NSApp.terminate(nil)
        }

        private static func idlePane(in delegate: AppDelegate) {
            guard let controller = delegate.windows.first else { return fail("no window") }
            let activity = controller.tree.focusedPane?.currentActivity
            check("the pane is idle", activity == .idleShell, "\(String(describing: activity))")
            emit("self-check failures=\(failures)")
            delegate.closePane(nil)
            let sheet = controller.window.attachedSheet
            emit(sheet == nil ? "closed-without-sheet" : "unexpected-sheet \(buttons(in: sheet).map(\.title))")
        }

        // MARK: - Helpers

        private static func descendantNames() -> [String] {
            let tree = ProcessTree.snapshot(under: ProcessInfo.processInfo.processIdentifier)
            return tree.map(\.name).sorted()
        }

        private static func buttons(in window: NSWindow?) -> [NSButton] {
            guard let root = window?.contentView else { return [] }
            var found: [NSButton] = []
            func walk(_ view: NSView) {
                if let button = view as? NSButton, !button.title.isEmpty { found.append(button) }
                view.subviews.forEach(walk)
            }
            walk(root)
            return found
        }

        private static func clickButton(_ title: String, in window: NSWindow?) {
            guard let button = buttons(in: window).first(where: { $0.title == title }) else {
                return check("button \(title) present", false)
            }
            button.performClick(nil)
        }

        private static func fail(_ detail: String) {
            check("driver precondition", false, detail)
            finish()
        }

        private static func finish() {
            emit("self-check failures=\(failures)")
            after(0.1) { NSApp.terminate(nil) }
        }

        private static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                emit("ok \(name)")
            } else {
                failures += 1
                emit("FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
            }
        }

        private static func emit(_ line: String) {
            guard let output, let handle = try? FileHandle(forWritingTo: output) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        }

        private static func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
            let timer = Timer(timeInterval: delay, repeats: false) { _ in
                MainActor.assumeIsolated { action() }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }
#endif
