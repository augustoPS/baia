#if DEBUG
import AppKit
import Foundation
import WorkspaceLayout

/// Drives R05 against the real AppKit windows in an isolated Debug process.
///
/// The external fixture seeds and grades the files. This side performs only the
/// operations that require live `NSWindowTabGroup` objects, then calls the two
/// narrow `AppDelegate` methods whose bodies are the production capture and save
/// paths. Startup itself calls production restore before this driver is entered.
@MainActor
enum WindowGroupSelfCheck {
    private static let a = UUID(uuidString: "BA1AC0DE-0000-4000-8000-0000000000A1")!
    private static let b = UUID(uuidString: "BA1AC0DE-0000-4000-8000-0000000000B2")!
    private static let c = UUID(uuidString: "BA1AC0DE-0000-4000-8000-0000000000C3")!
    private static let d = UUID(uuidString: "BA1AC0DE-0000-4000-8000-0000000000D4")!

    private static var output: URL?
    private static var failures = 0

    static func runIfRequested(in delegate: AppDelegate) {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["BAIA_WINDOW_GROUP_SELFCHECK_MODE"],
              let path = environment["BAIA_WINDOW_GROUP_SELFCHECK_OUTPUT"],
              !path.isEmpty
        else { return }
        guard SupportDirectory.name.hasPrefix("baia-window-groups."),
              environment["BAIA_CONFIG_FILE"]?.isEmpty == false,
              path.hasPrefix("/")
        else {
            FileHandle.standardError.write(Data("baia: refused unsafe window-group self-check instance\n".utf8))
            return
        }
        output = URL(filePath: path)
        failures = 0
        try? Data().write(to: output!)
        after(0.8) {
            switch mode {
            case "arrange": arrange(in: delegate)
            case "verify-arranged-and-mutate": verifyArrangedAndMutate(in: delegate)
            case "verify-mutated": verifyMutated(in: delegate)
            case "verify-missing-repair": verifyMissingRepair(in: delegate)
            default:
                check("known mode", false, mode)
                finish(in: delegate)
            }
        }
    }

    /// Starting from the migrated v1 four-tab group, exercise native detach,
    /// merge, detach and reorder before the first schema-2 save.
    private static func arrange(in delegate: AppDelegate) {
        checkGroups(in: delegate, expected: [[a, b, c, d]], selected: [b],
                    sidebars: nil, durableComparison: false)
        guard let controllers = controllers(in: delegate),
              let firstGroup = controllers[a]?.window.tabGroup,
              let aWindow = controllers[a]?.window,
              let bWindow = controllers[b]?.window,
              let cWindow = controllers[c]?.window,
              let dWindow = controllers[d]?.window
        else {
            check("the v1 restore produced all four native tabs", false)
            return finish(in: delegate)
        }

        firstGroup.removeWindow(dWindow)
        check("native detach produced a singleton group", signatures(in: delegate).count == 2,
              String(describing: signatures(in: delegate)))
        aWindow.addTabbedWindow(dWindow, ordered: .above)
        check("native merge returned to one group", signatures(in: delegate).count == 1,
              String(describing: signatures(in: delegate)))

        guard let merged = aWindow.tabGroup else {
            check("merged window has a native tab group", false)
            return finish(in: delegate)
        }
        merged.removeWindow(cWindow)
        merged.removeWindow(dWindow)
        cWindow.addTabbedWindow(dWindow, ordered: .above)

        // Reinsert through native tab APIs. `addTabbedWindow` inserts after its
        // receiver, so these two calls produce B,A and D,C respectively.
        aWindow.tabGroup?.removeWindow(bWindow)
        bWindow.addTabbedWindow(aWindow, ordered: .above)
        cWindow.tabGroup?.removeWindow(dWindow)
        dWindow.addTabbedWindow(cWindow, ordered: .above)

        let expected = [[b, a], [d, c]]
        settleAndApplyGeometry(in: delegate, expected: expected,
                               sidebars: [(286, 174), (374, 238)]) {
            select(a, in: delegate, makeKey: false)
            select(d, in: delegate, makeKey: true)
            after(0.2) {
                delegate.showSettings(nil)
                after(0.2) {
                    check("Settings is the auxiliary key window",
                          delegate.settingsWindow?.window?.isKeyWindow == true)
                    checkGroups(in: delegate, expected: expected, selected: [a, d],
                                sidebars: [(286, 174), (374, 238)], durableComparison: false,
                                active: [d, c])
                    saveAndFinish(in: delegate)
                }
            }
        }
    }

    /// Prove the first saved arrangement came through production restore, then
    /// exercise merge, detach and reorder again on the restored native groups.
    private static func verifyArrangedAndMutate(in delegate: AppDelegate) {
        checkGroups(in: delegate, expected: [[b, a], [d, c]], selected: [a, d],
                    sidebars: [(286, 174), (374, 238)], durableComparison: true,
                    active: [d, c])
        guard let controllers = controllers(in: delegate),
              let aWindow = controllers[a]?.window,
              let bWindow = controllers[b]?.window,
              let cWindow = controllers[c]?.window,
              let dWindow = controllers[d]?.window
        else {
            check("the restored arrangement exposes all four tabs", false)
            return finish(in: delegate)
        }

        // Merge to B,A,D,C by chaining each insertion after the preceding tab.
        aWindow.addTabbedWindow(dWindow, ordered: .above)
        dWindow.addTabbedWindow(cWindow, ordered: .above)
        check("native post-restore merge produced one group", signatures(in: delegate).count == 1,
              String(describing: signatures(in: delegate)))

        guard let merged = aWindow.tabGroup else {
            check("post-restore merge has a native group", false)
            return finish(in: delegate)
        }
        merged.removeWindow(bWindow)
        merged.removeWindow(cWindow)
        cWindow.addTabbedWindow(bWindow, ordered: .above)

        let expected = [[a, d], [c, b]]
        settleAndApplyGeometry(in: delegate, expected: expected,
                               sidebars: [(302, 188), (358, 226)]) {
            select(b, in: delegate, makeKey: false)
            select(d, in: delegate, makeKey: true)
            after(0.2) {
                delegate.showSettings(nil)
                after(0.2) {
                    check("Settings is key before the second production capture",
                          delegate.settingsWindow?.window?.isKeyWindow == true)
                    checkGroups(in: delegate, expected: expected, selected: [d, b],
                                sidebars: [(302, 188), (358, 226)], durableComparison: false,
                                active: [a, d])
                    saveAndFinish(in: delegate)
                }
            }
        }
    }

    private static func verifyMutated(in delegate: AppDelegate) {
        checkGroups(in: delegate, expected: [[a, d], [c, b]], selected: [d, b],
                    sidebars: [(302, 188), (358, 226)], durableComparison: true,
                    active: [a, d])
        saveAndFinish(in: delegate)
    }

    private static func verifyMissingRepair(in delegate: AppDelegate) {
        checkGroups(in: delegate, expected: [[a]], selected: [a],
                    sidebars: [(286, 174)], durableComparison: false, active: [a])
        check("missing-directory restore created one actual window", delegate.windows.count == 1,
              "windows=\(delegate.windows.count)")
        saveAndFinish(in: delegate)
    }

    private static func saveAndFinish(in delegate: AppDelegate) {
        let result = delegate.saveWindowGroupSelfCheckSnapshot()
        check("production save returned saved", result == .saved, String(describing: result))
        finish(in: delegate)
    }

    private static func finish(in _: AppDelegate) {
        emit("self-check failures=\(failures)")
        after(0.1) { NSApp.terminate(nil) }
    }

    private static func controllers(in delegate: AppDelegate) -> [UUID: WorkspaceWindowController]? {
        let pairs = delegate.windows.compactMap { controller -> (UUID, WorkspaceWindowController)? in
            guard let id = controller.snapshot?.tab.id else { return nil }
            return (id, controller)
        }
        guard pairs.count == delegate.windows.count else { return nil }
        return Dictionary(uniqueKeysWithValues: pairs)
    }

    /// Actual AppKit group membership and order, independently of production
    /// capture. This is the live oracle that prevents a helper-only proxy.
    private static func nativeGroups(in delegate: AppDelegate) -> [[WorkspaceWindowController]] {
        var seen: Set<ObjectIdentifier> = []
        var result: [[WorkspaceWindowController]] = []
        for controller in delegate.windows where !seen.contains(ObjectIdentifier(controller)) {
            let windows = controller.window.tabGroup?.windows ?? [controller.window]
            let group = windows.compactMap { window in
                delegate.windows.first { $0.window === window }
            }
            for member in group { seen.insert(ObjectIdentifier(member)) }
            if !group.isEmpty { result.append(group) }
        }
        return result
    }

    private static func signatures(in delegate: AppDelegate) -> [[UUID]] {
        nativeGroups(in: delegate).map { group in
            group.compactMap { $0.snapshot?.tab.id }
        }
    }

    private static func selectedID(in group: [WorkspaceWindowController]) -> UUID? {
        guard let first = group.first else { return nil }
        let selectedWindow = first.window.tabGroup?.selectedWindow ?? first.window
        return group.first { $0.window === selectedWindow }?.snapshot?.tab.id
    }

    private static func checkGroups(
        in delegate: AppDelegate,
        expected: [[UUID]],
        selected: [UUID],
        sidebars: [(Double, Double)]?,
        durableComparison: Bool,
        active: [UUID]? = nil
    ) {
        let native = nativeGroups(in: delegate)
        let actual = signatures(in: delegate)
        emit("evidence native \(describe(native))")
        let membershipAndOrderMatch = actual.count == expected.count
            && actual.allSatisfy { group in expected.contains(group) }
            && expected.allSatisfy { group in actual.contains(group) }
        check("actual native group membership and tab order", membershipAndOrderMatch,
              "actual=\(actual) expected=\(expected)")
        check("one controller exists per expected tab",
              actual.flatMap { $0 }.count == delegate.windows.count,
              "tabs=\(actual.flatMap { $0 }.count) windows=\(delegate.windows.count)")
        check("every live window accepts native tabbing",
              delegate.windows.allSatisfy { $0.window.tabbingMode == .preferred })
        for group in native {
            let tabs = group.compactMap { $0.snapshot?.tab.id }
            guard let index = expected.firstIndex(of: tabs), selected.indices.contains(index) else {
                continue
            }
            check("group \(tabs) selected tab", selectedID(in: group) == selected[index],
                  "actual=\(String(describing: selectedID(in: group)))")
            if let sidebars, sidebars.indices.contains(index) {
                let wanted = sidebars[index]
                check("group \(tabs) sidebar geometry",
                      group.allSatisfy {
                          close($0.sidebar.geometry.width, wanted.0)
                              && close($0.sidebar.geometry.splitHeight, wanted.1)
                      },
                      String(describing: group.map(\.sidebar.geometry)))
            }
        }
        if native.count > 1 {
            let frames = native.compactMap { $0.first?.frame }
            check("groups have distinct actual frames", frames.count == native.count && frames[0] != frames[1],
                  String(describing: frames))
        }

        let captured = delegate.captureWindowGroupSelfCheckSnapshot()
        emit("evidence captured \(describe(captured.groups)) active=\(String(describing: captured.activeGroup))")
        let capturedOrders = captured.groups.map { $0.tabs.map(\.id) }
        let capturedMembershipAndOrderMatch = capturedOrders.count == expected.count
            && capturedOrders.allSatisfy { group in expected.contains(group) }
            && expected.allSatisfy { group in capturedOrders.contains(group) }
        check("production capture preserves native membership", capturedMembershipAndOrderMatch,
              "captured=\(capturedOrders)")
        let capturedSelectionsMatch = captured.groups.allSatisfy { group in
            guard let index = expected.firstIndex(of: group.tabs.map(\.id)), selected.indices.contains(index)
            else { return false }
            return group.selectedTab == selected[index]
        }
        check("production capture preserves native selection", capturedSelectionsMatch,
              "captured=\(captured.groups.map { ($0.tabs.map(\.id), $0.selectedTab) })")
        if let active {
            let activeTabs = captured.active?.tabs.map(\.id)
            check("production capture preserves the last active group", activeTabs == active,
                  "captured=\(String(describing: activeTabs))")
            if delegate.settingsWindow?.window?.isKeyWindow != true {
                check("restored active group is the actual key group",
                      native.first(where: { $0.contains { $0.window.isKeyWindow } })?
                          .compactMap { $0.snapshot?.tab.id } == active)
            }
        }

        if durableComparison {
            compareWithDurableSession(captured, native: native, expected: expected)
        }
    }

    private static func compareWithDurableSession(
        _ captured: SessionSnapshot,
        native: [[WorkspaceWindowController]],
        expected: [[UUID]]
    ) {
        guard case let .loaded(durable) = SessionStore(fileURL: sessionURL()).inspect() else {
            return check("durable schema-2 session loads", false)
        }
        emit("evidence durable \(describe(durable.groups)) active=\(String(describing: durable.activeGroup))")
        let capturedByID = Dictionary(uniqueKeysWithValues: captured.groups.map { ($0.id, $0) })
        let durableByID = Dictionary(uniqueKeysWithValues: durable.groups.map { ($0.id, $0) })
        check("production capture group ids match the restored file",
              Set(capturedByID.keys) == Set(durableByID.keys),
              "captured=\(captured.groups.map { ($0.id, $0.tabs.map(\.id)) }) durable=\(durable.groups.map { ($0.id, $0.tabs.map(\.id)) })")
        let frameMismatches = durable.groups.compactMap { group -> String? in
            guard let capturedGroup = capturedByID[group.id], !close(capturedGroup.frame, group.frame) else {
                return nil
            }
            return "id=\(group.id) tabs=\(group.tabs.map(\.id)) durable=\(String(describing: group.frame)) captured=\(String(describing: capturedGroup.frame))"
        }
        check("restored frames match the durable per-group frames", frameMismatches.isEmpty,
              frameMismatches.joined(separator: " | "))
        let nativeFrameMismatches = native.compactMap { controllers -> String? in
            let tabs = controllers.compactMap { $0.snapshot?.tab.id }
            guard let capturedGroup = captured.groups.first(where: { $0.tabs.map(\.id) == tabs }),
                  let durableFrame = durableByID[capturedGroup.id]?.frame
            else { return "tabs=\(tabs) have no matching durable group" }
            let actualFrames = controllers.map(\.frame)
            guard actualFrames.allSatisfy({ close($0, durableFrame) }) else {
                return "tabs=\(tabs) durable=\(String(describing: durableFrame)) actual=\(actualFrames)"
            }
            return nil
        }
        check("every restored native tab carries its group's durable frame",
              nativeFrameMismatches.isEmpty, nativeFrameMismatches.joined(separator: " | "))

        let durableTrees = Dictionary(uniqueKeysWithValues: durable.groups.flatMap(\.tabs).map { ($0.id, $0.tree) })
        let capturedTrees = Dictionary(uniqueKeysWithValues: captured.groups.flatMap(\.tabs).map { ($0.id, $0.tree) })
        check("pane trees round-trip through production restore", expected.flatMap { $0 }.allSatisfy {
            durableTrees[$0] == capturedTrees[$0]
        })
    }

    private static func describe(_ groups: [[WorkspaceWindowController]]) -> String {
        String(describing: groups.map { group in
            (
                tabs: group.compactMap { $0.snapshot?.tab.id },
                selected: selectedID(in: group),
                frames: group.map(\.frame),
                sidebars: group.map(\.sidebar.geometry)
            )
        })
    }

    private static func describe(_ groups: [WindowGroup]) -> String {
        String(describing: groups.map {
            (id: $0.id, tabs: $0.tabs.map(\.id), selected: $0.selectedTab,
             frame: $0.frame, sidebar: $0.sidebar)
        })
    }

    private static func applyGeometry(
        in delegate: AppDelegate,
        expected: [[UUID]],
        sidebars: [(Double, Double)]
    ) {
        let frames = targetFrames()
        for group in nativeGroups(in: delegate) {
            let tabs = group.compactMap { $0.snapshot?.tab.id }
            guard let index = expected.firstIndex(of: tabs),
                  sidebars.indices.contains(index), frames.indices.contains(index)
            else { continue }
            // AppKit retains a frame on each tab window even though only the
            // selected member is visible. Assign every member so selecting a tab
            // after a detach cannot resurrect that member's old group frame.
            for controller in group {
                controller.window.setFrame(frames[index], display: false)
                controller.sidebar.geometry = SidebarGeometry(
                    width: sidebars[index].0,
                    splitHeight: sidebars[index].1
                )
            }
        }
    }

    /// Native merge/detach updates group ownership over later AppKit turns. Wait
    /// for the requested membership, then keep applying geometry until the live
    /// windows report it or the bounded diagnostic deadline expires.
    private static func settleAndApplyGeometry(
        in delegate: AppDelegate,
        expected: [[UUID]],
        sidebars: [(Double, Double)],
        attempt: Int = 0,
        completion: @escaping @MainActor () -> Void
    ) {
        let actual = signatures(in: delegate)
        let membershipSettled = actual.count == expected.count
            && actual.allSatisfy { expected.contains($0) }
            && expected.allSatisfy { actual.contains($0) }
        if membershipSettled {
            applyGeometry(in: delegate, expected: expected, sidebars: sidebars)
        }
        after(0.05) {
            if membershipSettled && geometryMatches(in: delegate, expected: expected, sidebars: sidebars) {
                completion()
            } else if attempt < 39 {
                settleAndApplyGeometry(in: delegate, expected: expected, sidebars: sidebars,
                                       attempt: attempt + 1, completion: completion)
            } else {
                check("native groups settled with requested geometry", false,
                      "actual=\(describe(nativeGroups(in: delegate)))")
                completion()
            }
        }
    }

    private static func geometryMatches(
        in delegate: AppDelegate,
        expected: [[UUID]],
        sidebars: [(Double, Double)]
    ) -> Bool {
        let frames = targetFrames().map {
            WindowFrame(x: $0.origin.x, y: $0.origin.y, width: $0.width, height: $0.height)
        }
        let native = nativeGroups(in: delegate)
        guard native.count == expected.count else { return false }
        for group in native {
            let tabs = group.compactMap { $0.snapshot?.tab.id }
            guard let index = expected.firstIndex(of: tabs),
                  sidebars.indices.contains(index), frames.indices.contains(index)
            else { return false }
            let sidebar = sidebars[index]
            guard group.allSatisfy({
                close($0.frame, frames[index])
                    && close($0.sidebar.geometry.width, sidebar.0)
                    && close($0.sidebar.geometry.splitHeight, sidebar.1)
            }) else { return false }
        }
        return true
    }

    private static func targetFrames() -> [NSRect] {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(650, max(520, (visible.width - 120) / 2))
        let height = min(560, max(420, visible.height - 180))
        return [
            NSRect(x: visible.minX + 30, y: visible.minY + 50, width: width, height: height),
            NSRect(x: visible.maxX - width - 30, y: visible.minY + 90, width: width, height: height - 20),
        ]
    }

    private static func select(_ id: UUID, in delegate: AppDelegate, makeKey: Bool) {
        guard let controller = controllers(in: delegate)?[id] else {
            return check("select tab \(id)", false, "missing controller")
        }
        controller.window.tabGroup?.selectedWindow = controller.window
        if makeKey { controller.window.makeKeyAndOrderFront(nil) }
    }

    private static func close(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= 0.5
    }

    private static func close(_ lhs: WindowFrame?, _ rhs: WindowFrame?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return close(lhs.x, rhs.x) && close(lhs.y, rhs.y)
            && close(lhs.width, rhs.width) && close(lhs.height, rhs.height)
    }

    private static func sessionURL() -> URL {
        SessionStore.defaultFileURL(directoryName: SupportDirectory.name)
    }

    private static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            emit("ok \(name)")
        } else {
            failures += 1
            emit("FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
        }
    }

    private static func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func emit(_ line: String) {
        guard let output, let handle = try? FileHandle(forWritingTo: output) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}
#endif
