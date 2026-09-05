#if DEBUG
    import AppKit
    import BaiaSettings
    import PaneChrome
    import WorkspaceMenu

    /// The app-level checks for the Settings window, run inside the real app.
    ///
    /// `Diagnostics/settings-window/run.sh` launches the Debug build with
    /// `BAIA_SETTINGS_SELFCHECK=1` and `BAIA_CONFIG_FILE` pointing at a scratch
    /// copy of the config. After launch this opens the window, drives it the
    /// way a person would (selecting categories, committing edits through the
    /// controls' own editor, undoing through the window's undo manager) and
    /// prints one line per check. The process exits 0 when every check passed
    /// and 1 otherwise, so the script under `set -e` is the test.
    ///
    /// Why in-process rather than a `swiftc` probe: the window needs
    /// `ConfigurationCenter`, which needs libghostty, which no probe links. And
    /// why not computer-use: the questions here are about responder routing,
    /// toolbar selection and the values the pages hold, which the running
    /// object graph answers exactly and a screenshot answers approximately.
    ///
    /// Debug-only in the strongest sense: the whole file is fenced, so Release
    /// carries no self-check and no environment variable that starts one.
    @MainActor
    enum SettingsSelfCheck {
        private static var failures = 0

        static func runIfRequested(in delegate: AppDelegate) {
            guard ProcessInfo.processInfo.environment["BAIA_SETTINGS_SELFCHECK"] == "1" else { return }
            // Line-buffered even when stdout is a file, so the window number
            // reaches the capture script before the hold ends.
            setlinebuf(stdout)
            guard ProcessInfo.processInfo.environment["BAIA_CONFIG_FILE"]?.isEmpty == false else {
                print("FAIL the self-check needs BAIA_CONFIG_FILE, so it never touches the real config")
                exit(1)
            }
            // A second run-loop turn, so the restored session's windows exist
            // and the toolbar has been laid out before anything is asserted.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                run(in: delegate)
                print(failures == 0 ? "settings self-check: all checks passed" : "settings self-check: \(failures) failed")
                // `BAIA_SETTINGS_HOLD_SECONDS` keeps the window on screen after
                // the checks, so `screencapture -l <window>` from outside can
                // photograph each page through the window server; the window
                // number is printed for it. Cached offscreen drawing was tried
                // first and drops modern controls' text and bezels.
                let hold = Double(ProcessInfo.processInfo.environment["BAIA_SETTINGS_HOLD_SECONDS"] ?? "") ?? 0
                if hold > 0, let window = delegate.settingsWindow?.window {
                    print("window \(window.windowNumber)")
                    var remaining = hold
                    for category in SettingsCategory.allCases {
                        let delay = hold - remaining
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            delegate.settingsWindow?.select(category)
                            print("showing \(category.rawValue)")
                        }
                        remaining -= hold / Double(SettingsCategory.allCases.count)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                    exit(failures == 0 ? 0 : 1)
                }
            }
        }

        private static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                print("ok   \(name)")
            } else {
                failures += 1
                print("FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
            }
        }

        private static func run(in delegate: AppDelegate) {
            let center = delegate.configuration
            delegate.showSettings(nil)
            guard let controller = delegate.settingsWindow, let window = controller.window else {
                check("the settings window exists", false)
                return
            }
            let first = ObjectIdentifier(controller)

            // Reuse: a second Settings brings the same window forward.
            delegate.showSettings(nil)
            check("a second Settings invocation reuses the window",
                  delegate.settingsWindow.map(ObjectIdentifier.init) == first)
            check("the settings window is key", window.isKeyWindow)

            // Toolbar: every category, selectable, in the spec's order.
            let identifiers = window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
            check("the toolbar lists the seven categories in order",
                  identifiers == SettingsCategory.allCases.map(\.rawValue), "\(identifiers)")
            check("the toolbar's selected item is the selected category",
                  window.toolbar?.selectedItemIdentifier?.rawValue == controller.selected.rawValue)

            // Every page: one control per key it edits, and the title follows.
            for category in SettingsCategory.allCases {
                controller.select(category)
                let page = controller.page(for: category)
                check("\(category.rawValue): one control per key",
                      page.controls.count == category.keys.count,
                      "\(page.controls.count) controls for \(category.keys.count) keys")
                check("\(category.rawValue): window title follows the selection",
                      window.title == category.title)
                check("\(category.rawValue): toolbar selection follows",
                      window.toolbar?.selectedItemIdentifier?.rawValue == category.rawValue)
            }
            controller.select(.appearance)

            // Responder routing while Settings is key.
            let closeTarget = NSApp.target(forAction: #selector(AppDelegate.closePane(_:))) as AnyObject?
            check("⌘W resolves to the settings window, not the app delegate",
                  closeTarget === controller, String(describing: closeTarget))
            let split = NSMenuItem()
            split.tag = MenuCommand.splitRight.tag
            check("a pane command validates disabled while Settings is key",
                  !delegate.validateMenuItem(split))
            let close = NSMenuItem()
            close.tag = MenuCommand.closePane.tag
            check("Close Pane validates disabled for the delegate while Settings is key",
                  !delegate.validateMenuItem(close))
            check("the window's undo manager is the settings manager",
                  window.undoManager === controller.settingsUndoManager)

            // Transactions through the window's own editor: every active key
            // moves the running settings, the file, and the panes.
            let store = center.store
            let before = center.settings
            for key in SettingsKey.allCases where key.isActive {
                let edit = moved(key, from: before)
                let error = controller.commit(edit, actionName: "self-check \(key.rawValue)")
                let expected = center.settings.applying(edit)
                check("\(key.rawValue): commits without a validation error", error == nil, error?.message ?? "")
                check("\(key.rawValue): the running settings moved", center.settings == expected)
                check("\(key.rawValue): the file holds the value", store.load().settings == expected)
            }
            let pane = delegate.windows.first?.tree.allPanes.first
            check("a live pane received the new appearance",
                  pane?.lastAppliedAppearance == center.paneAppearance,
                  pane == nil ? "no pane to check" : "")
            check("a live pane's theme is the new theme",
                  pane?.lastAppliedAppearance?.theme == center.paneTheme)
            check("the notifier follows notificationsEnabled",
                  delegate.notifierIsEnabled == center.settings.notificationsEnabled)
            check("command execution stays off without the acknowledgement",
                  delegate.commandExecutionAcknowledgement.isAcknowledged || !delegate.effectiveAllowRun)
            check("the control server's run flag matches the gate",
                  delegate.control.isRunAllowed == delegate.effectiveAllowRun)

            // Undo reverses the last edit in both places; redo puts it back.
            let manager = controller.settingsUndoManager
            let lastKey = SettingsKey.allCases.last { $0.isActive }!
            check("undo is available after an edit", manager.canUndo)
            let beforeUndo = center.settings
            manager.undo()
            check("undo moved the running settings", center.settings != beforeUndo)
            check("undo moved the file", store.load().settings == center.settings)
            check("undo restored \(lastKey.rawValue)",
                  SettingsEdit.value(of: lastKey, in: center.settings) == SettingsEdit.value(of: lastKey, in: before))
            manager.redo()
            check("redo put it back in the running settings", center.settings == beforeUndo)
            check("redo put it back in the file", store.load().settings == beforeUndo)

            // Invalid input: nothing written, error shown, value retained.
            let fileBefore = (try? Data(contentsOf: store.url)) ?? Data()
            let invalid = controller.commit(.backgroundHex("not-a-colour"), actionName: "invalid")
            check("invalid colour answers a validation error", invalid?.key == .backgroundHex)
            check("invalid colour wrote nothing", (try? Data(contentsOf: store.url)) == fileBefore)
            check("invalid colour raised no recovery banner", controller.banner.isHidden)

            // A slider gesture is one undo step.
            let undoDepthBefore = undoDepth(manager)
            _ = controller.preview(.backgroundOpacity(0.31))
            _ = controller.preview(.backgroundOpacity(0.32))
            check("a preview frame reaches the running settings", center.settings.backgroundOpacity == 0.32)
            _ = controller.endGesture(.backgroundOpacity(0.33), actionName: "Change Opacity")
            check("the gesture's end wrote the file", store.load().settings.backgroundOpacity == 0.33)
            manager.undo()
            check("one undo reverses the whole gesture", center.settings.backgroundOpacity == beforeUndo.backgroundOpacity)
            check("the gesture was one undo step", undoDepth(manager) == undoDepthBefore)

            // The preview: real chrome, resolved the way a pane resolves it.
            let sample = controller.preview.sample
            let appearance = center.appearance(for: center.settings)
            check("the sample pane wears the pane's resolved chrome",
                  sample.pane.chrome.resolvedChrome == appearance.resolvedChrome)
            check("the sample pane wears the pane's theme",
                  sample.pane.chrome.theme == appearance.theme)
            check("the sample sidebar follows the sidebar setting",
                  sample.showsFiles == (center.settings.sidebar == .files))
            check("the sample sidebar wears the resolved chrome",
                  sample.sidebar.resolvedChrome == appearance.resolvedChrome)
            for state in SamplePaneState.allCases {
                sample.state = state
                check("sample state \(state.title.lowercased()) sets focus and activation",
                      sample.pane.chrome.isPaneFocused == state.isPaneFocused
                          && sample.pane.chrome.isWindowActive == state.isWindowActive)
                check("sample state \(state.title.lowercased()) sets the attention level",
                      sample.pane.chrome.attention == PaneStatus.Attention(state.agent))
            }
            sample.state = .focused
            check("the sample renders pixels", renders(sample.frame))

            // Malformed file: refused, banner up, repair keeps a backup.
            let good = (try? Data(contentsOf: store.url)) ?? Data()
            try? Data("{ broken".utf8).write(to: store.url)
            let refused = controller.commit(.fontSize(21), actionName: "on a broken file")
            check("a write onto a malformed file is refused", refused == nil && controller.transactions.lastFailure == .malformed)
            check("the malformed file's bytes are untouched", (try? Data(contentsOf: store.url)) == Data("{ broken".utf8))
            controller.refreshRecoveryState()
            check("the recovery banner is shown for a malformed file", !controller.banner.isHidden)
            switch controller.transactions.repair() {
            case let .success(backup):
                check("repair kept the original bytes", (try? Data(contentsOf: backup)) == Data("{ broken".utf8))
                check("repair left a valid file", store.inspect() == .valid)
                try? FileManager.default.removeItem(at: backup)
            case let .failure(failure):
                check("repair succeeded", false, failure.message)
            }
            controller.refreshRecoveryState()
            check("the recovery banner hides after repair", controller.banner.isHidden)
            try? good.write(to: store.url)

        }

        // MARK: - Helpers

        private static func undoDepth(_ manager: UndoManager) -> Int {
            // `UndoManager` exposes no count; the number of undos until empty is
            // measured by undoing and redoing, which is safe here because every
            // registered action round-trips exactly.
            var depth = 0
            while manager.canUndo {
                manager.undo()
                depth += 1
            }
            for _ in 0 ..< depth { manager.redo() }
            return depth
        }

        private static func renders(_ view: NSView) -> Bool {
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.bitmapData else { return false }
            let count = bitmap.bytesPerPlane
            var distinct = Set<UInt8>()
            for index in stride(from: 0, to: count, by: 64) {
                distinct.insert(data[index])
                if distinct.count > 8 { return true }
            }
            return false
        }

        /// A value for `key` that differs from `settings`.
        private static func moved(_ key: SettingsKey, from settings: Settings) -> SettingsEdit {
            switch key {
            case .fontFamily: .fontFamily(settings.fontFamily == "Menlo" ? "Monaco" : "Menlo")
            case .fontSize: .fontSize(settings.fontSize == 13 ? 14 : 13)
            case .themeName: .themeName(settings.themeName == "Dracula" ? "Nord" : "Dracula")
            case .backgroundHex: .backgroundHex(settings.backgroundHex == "#101010" ? "#202020" : "#101010")
            case .backgroundOpacity: .backgroundOpacity(settings.backgroundOpacity == 0.5 ? 0.6 : 0.5)
            case .backgroundBlur: .backgroundBlur(!settings.backgroundBlur)
            case .windowPadding: .windowPadding(settings.windowPadding == 12 ? 14 : 12)
            case .windowPaddingBalance: .windowPaddingBalance(!settings.windowPaddingBalance)
            case .transparentTitlebar: .transparentTitlebar(!settings.transparentTitlebar)
            case .optionAsAlt: .optionAsAlt(!settings.optionAsAlt)
            case .cursorStyle: .cursorStyle(settings.cursorStyle == .bar ? .underline : .bar)
            case .projectRoots: .projectRoots(settings.projectRoots == ["/opt/src"] ? ["/opt/work"] : ["/opt/src"])
            case .discoveryMaxDepth: .discoveryMaxDepth(settings.discoveryMaxDepth == 5 ? 6 : 5)
            case .notificationsEnabled: .notificationsEnabled(!settings.notificationsEnabled)
            case .gitPollSeconds: .gitPollSeconds(settings.gitPollSeconds == 7 ? 8 : 7)
            case .activityPollSeconds: .activityPollSeconds(settings.activityPollSeconds == 3 ? 4 : 3)
            case .restoreSession: .restoreSession(!settings.restoreSession)
            case .focusAccent: .focusAccent(settings.focusAccent == .bone ? .sea : .bone)
            case .attentionStyle: .attentionStyle(settings.attentionStyle == .quiet ? .loud : .quiet)
            case .attentionAccent: .attentionAccent(settings.attentionAccent == .accent ? .alert : .accent)
            case .alertBehavior: .alertBehavior(settings.alertBehavior == .derive ? .noCollision : .derive)
            case .chromeStyle: .chromeStyle(settings.chromeStyle == .solid ? .sheer : .solid)
            case .sidebar: .sidebar(settings.sidebar == .files ? .off : .files)
            case .controlChannelEnabled: .controlChannelEnabled(!settings.controlChannelEnabled)
            case .controlAllowRun: .controlAllowRun(!settings.controlAllowRun)
            case .controlAllowRead: .controlAllowRead(!settings.controlAllowRead)
            }
        }

    }
#endif
