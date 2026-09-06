#if DEBUG
    import AppKit
    import Foundation
    import WorkspaceLayout

    /// Drives the launch-time restore against a filesystem that does not answer.
    ///
    /// `BAIA_RESTORE_STALL_FILE` names a file the restore's directory checks wait
    /// for on the filesystem lane. While it is absent the restore is pending,
    /// which is the state this driver measures from the main thread. That the
    /// driver runs at all is the first proof: a timer cannot fire on a thread that
    /// is inside a stalled syscall, and before 2026-09-06 that thread was this one.
    ///
    /// It then does what an owner waiting on a slow launch would do, opens a
    /// window, and asks for the save that window would normally arm. The save must
    /// be refused and the file on disk must be byte for byte what was seeded. Then
    /// it releases the stall and expects the saved group to land beside the window
    /// it opened, the keys to stay in that window, and the next save to write both.
    ///
    /// The external fixture in `Diagnostics/restore-stall` seeds the file, reads
    /// this driver's events, and grades the durable result.
    @MainActor
    enum RestoreSelfCheck {
        /// The seeded tab, spelled the way `Diagnostics/session-recovery`'s oracle
        /// spells it, so the fixture and this driver agree on what was restored.
        private static let seededTab = UUID(uuidString: "BA1AC0DE-0000-4000-8000-0000000000AA")!

        /// Nil in every process that is not an isolated restore-stall instance.
        /// Read once on the main thread, before the lane task is built.
        static let stallFile: String? = {
            let environment = ProcessInfo.processInfo.environment
            guard let path = environment["BAIA_RESTORE_STALL_FILE"], !path.isEmpty,
                  path.hasPrefix("/"),
                  SupportDirectory.name.hasPrefix("baia-restore-stall."),
                  environment["BAIA_CONFIG_FILE"]?.isEmpty == false
            else { return nil }
            return path
        }()

        /// Runs on the filesystem lane, never on the main thread. Bounded so a
        /// fixture that dies without releasing cannot leave a process waiting
        /// forever; the bound is far past every deadline the fixture applies.
        nonisolated static func holdUntilReleased(_ path: String?) {
            guard let path else { return }
            let deadline = Date().addingTimeInterval(120)
            while !FileManager.default.fileExists(atPath: path), Date() < deadline {
                usleep(50_000)
            }
        }

        private static var output: URL?
        private static var failures = 0
        private static var seeded: Data?

        static func runIfRequested(in delegate: AppDelegate) {
            let environment = ProcessInfo.processInfo.environment
            guard let stall = stallFile,
                  let path = environment["BAIA_RESTORE_SELFCHECK_OUTPUT"], !path.isEmpty,
                  path.hasPrefix("/")
            else { return }
            output = URL(filePath: path)
            failures = 0
            try? Data().write(to: output!)
            seeded = try? Data(contentsOf: delegate.sessionFileURL)
            after(0.3) { whilePending(in: delegate, release: stall) }
        }

        private static func whilePending(in delegate: AppDelegate, release: String) {
            check("main thread turned while the restore is pending", delegate.isRestorePending)
            check("no window before the result", delegate.windows.isEmpty)

            // What an owner does while waiting.
            delegate.newWorkspaceWindow(nil)
            check("the owner's window opened", delegate.windows.count == 1)

            // What that window arms, called through the production save path.
            let result = delegate.saveWindowGroupSelfCheckSnapshot()
            check("save refused while pending", result == nil, "\(String(describing: result))")
            let current = try? Data(contentsOf: delegate.sessionFileURL)
            check("seeded file untouched while pending", current == seeded)

            check("stall released", FileManager.default.createFile(atPath: release, contents: nil))
            waitForApply(in: delegate, deadline: Date().addingTimeInterval(10))
        }

        private static func waitForApply(in delegate: AppDelegate, deadline: Date) {
            if delegate.isRestorePending {
                guard Date() < deadline else {
                    check("restore applied after release", false, "still pending")
                    return finish()
                }
                return after(0.1) { waitForApply(in: delegate, deadline: deadline) }
            }
            afterApply(in: delegate)
        }

        private static func afterApply(in delegate: AppDelegate) {
            check("restore applied after release", true)
            let tabs = delegate.windows.compactMap { $0.snapshot?.tab.id }
            check("saved group opened beside the owner's window", delegate.windows.count == 2, "\(tabs)")
            check("the restored tab is the seeded one", tabs.contains(seededTab), "\(tabs)")
            let key = delegate.windows.first { $0.window.isKeyWindow }
            check(
                "keys stayed in the owner's window",
                key != nil && key?.snapshot?.tab.id != seededTab,
                "\(String(describing: key?.snapshot?.tab.id))"
            )
            waitForSave(in: delegate, deadline: Date().addingTimeInterval(6))
        }

        /// The autosave armed by `settleLaunch` writes both groups within its
        /// one-second coalescing window.
        private static func waitForSave(in delegate: AppDelegate, deadline: Date) {
            let current = try? Data(contentsOf: delegate.sessionFileURL)
            if let current, current != seeded {
                grade(current)
                return finish()
            }
            guard Date() < deadline else {
                check("autosave wrote after apply", false, "file unchanged")
                return finish()
            }
            after(0.1) { waitForSave(in: delegate, deadline: deadline) }
        }

        private static func grade(_ data: Data) {
            check("autosave wrote after apply", true)
            guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let groups = document["groups"] as? [[String: Any]]
            else { return check("written session decodes", false) }
            let tabs = groups.flatMap { group in
                (group["tabs"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            }
            check("written session holds both groups", groups.count == 2, "\(groups.count)")
            check("written session holds the seeded tab", tabs.contains(seededTab.uuidString), "\(tabs)")
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
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }

        private static func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
            let timer = Timer(timeInterval: delay, repeats: false) { _ in
                MainActor.assumeIsolated { action() }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }
#endif
