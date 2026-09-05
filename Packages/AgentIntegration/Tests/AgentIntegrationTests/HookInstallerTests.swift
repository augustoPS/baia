import Foundation
import Testing

@testable import AgentIntegration

/// The installer against a temporary directory, never against the owner's own.
///
/// Every path is injected, so these exercise the real file writes without going
/// anywhere near `~/.claude`.
@Suite struct HookInstallerTests {
    private func makeHome() -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "baia-installer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func readData(_ url: URL) -> Data {
        (try? Data(contentsOf: url)) ?? Data()
    }

    // MARK: Installing

    @Test func installingOnAMachineWithNoSettingsFileStillWorks() {
        let layout = HookInstaller.Layout.standard(home: makeHome())
        guard case .changed = HookInstaller.install(layout) else {
            Issue.record("did not install")
            return
        }
        #expect(FileManager.default.fileExists(atPath: layout.script.path))
        #expect(read(layout.settings).contains("baia-agent-state.sh"))
    }

    @Test func theScriptIsWrittenExecutableAndWithItsHeader() {
        let layout = HookInstaller.Layout.standard(home: makeHome())
        _ = HookInstaller.install(layout, version: 7)
        #expect(ManagedHeader.version(in: read(layout.script)) == 7)
        let mode = (try? FileManager.default.attributesOfItem(atPath: layout.script.path))?[.posixPermissions] as? Int
        #expect(mode == 0o755)
    }

    /// **The owner's file survives.** Same fixture the merge suites use, through
    /// the real read, write and reparse.
    @Test func aRealSettingsFileKeepsEverythingElse() {
        let layout = HookInstaller.Layout.standard(home: makeHome())
        write(HookInstallTests.foreign, to: layout.settings)
        _ = HookInstaller.install(layout)

        guard case let .object(after)? = JSON.parse(read(layout.settings)) else {
            Issue.record("the installer wrote something unparseable")
            return
        }
        #expect(after.keys == ["permissions", "hooks", "theme"])
        #expect(after["theme"] == .string("dark"))
    }

    @Test func aBackupIsLeftBeside() {
        let layout = HookInstaller.Layout.standard(home: makeHome())
        write(HookInstallTests.foreign, to: layout.settings)
        _ = HookInstaller.install(layout)
        let backup = layout.settings.appendingPathExtension("baia-backup")
        #expect(read(backup) == HookInstallTests.foreign)
    }

    /// A second install writes nothing new, so running it twice does not churn a
    /// file under version control or leave two hooks behind.
    @Test func installingTwiceLeavesTheFileIdentical() {
        let layout = HookInstaller.Layout.standard(home: makeHome())
        write(HookInstallTests.foreign, to: layout.settings)
        _ = HookInstaller.install(layout)
        let once = read(layout.settings)

        let outcome = HookInstaller.install(layout)
        #expect(outcome == .unchanged)
        #expect(read(layout.settings) == once)
    }

    /// **Refused, and the file is not touched.** The whole reason a malformed
    /// document is not repaired.
    @Test func aMalformedSettingsFileIsRefusedAndLeftAlone() {
        let layout = HookInstaller.Layout.standard(home: makeHome())
        let broken = "{ \"hooks\": "
        write(broken, to: layout.settings)

        guard case let .refused(reason) = HookInstaller.install(layout) else {
            Issue.record("a malformed file was accepted")
            return
        }
        #expect(reason.contains("not valid JSON"))
        #expect(read(layout.settings) == broken)
        #expect(FileManager.default.fileExists(atPath: layout.script.path) == false)
    }

    @Test func settingsWithInvalidUTF8AreRefusedAndLeftAlone() throws {
        let layout = HookInstaller.Layout.standard(home: makeHome())
        let broken = Data([0x7b, 0xff, 0x7d])
        try FileManager.default.createDirectory(
            at: layout.settings.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try broken.write(to: layout.settings)

        guard case let .refused(reason) = HookInstaller.install(layout) else {
            Issue.record("invalid UTF-8 settings were accepted")
            return
        }
        #expect(reason.contains("could not be read as UTF-8"))
        #expect(readData(layout.settings) == broken)
        #expect(FileManager.default.fileExists(atPath: layout.script.path) == false)
    }

    @Test func danglingSettingsSymlinkIsRefusedAndPreserved() throws {
        let layout = HookInstaller.Layout.standard(home: makeHome())
        try FileManager.default.createDirectory(
            at: layout.settings.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let destination = "missing-settings.json"
        try FileManager.default.createSymbolicLink(atPath: layout.settings.path, withDestinationPath: destination)

        guard case let .refused(reason) = HookInstaller.install(layout) else {
            Issue.record("a dangling settings symlink was treated as an absent file")
            return
        }
        #expect(reason.contains("could not be read as UTF-8"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: layout.settings.path) == destination)
        #expect(FileManager.default.fileExists(atPath: layout.script.path) == false)
        #expect(FileManager.default.fileExists(
            atPath: layout.settings.appendingPathExtension("baia-backup").path
        ) == false)
    }

    @Test func settingsBehindAnInaccessibleParentAreRefusedBeforeMutation() throws {
        let layout = HookInstaller.Layout.standard(home: makeHome())
        let claude = layout.settings.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try "{}".write(to: layout.settings, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: claude.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: claude.path)
        }

        guard case .refused = HookInstaller.install(layout) else {
            Issue.record("an indeterminate settings path was treated as absent")
            return
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: claude.path)
        #expect(read(layout.settings) == "{}")
        #expect(FileManager.default.fileExists(atPath: layout.script.path) == false)
    }

    @Test func unreadableExistingSettingsAreRefusedAndLeftAlone() throws {
        let layout = HookInstaller.Layout.standard(home: makeHome())
        let original = Data("{\"theme\":\"dark\"}".utf8)
        try FileManager.default.createDirectory(
            at: layout.settings.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try original.write(to: layout.settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: layout.settings.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: layout.settings.path)
        }

        guard case let .refused(reason) = HookInstaller.install(layout) else {
            Issue.record("unreadable settings were accepted")
            return
        }
        #expect(reason.contains("could not be read as UTF-8"))
        #expect(FileManager.default.fileExists(atPath: layout.script.path) == false)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: layout.settings.path)
        #expect(readData(layout.settings) == original)
    }

    @Test func aHooksSectionInAStrangeShapeIsRefused() {
        let layout = HookInstaller.Layout.standard(home: makeHome())
        let original = "{\n  \"hooks\": \"surprise\"\n}"
        write(original, to: layout.settings)
        guard case let .refused(reason) = HookInstaller.install(layout) else {
            Issue.record("a strange hooks section was accepted")
            return
        }
        #expect(reason.contains("does not understand"))
        #expect(read(layout.settings) == original)
        #expect(FileManager.default.fileExists(atPath: layout.script.path) == false)
    }

    @Test func exhaustedBackupNamesRefuseReplacementAndReportTheScriptChange() {
        let layout = HookInstaller.Layout.standard(home: makeHome())
        write(HookInstallTests.foreign, to: layout.settings)
        for suffix in ["baia-backup"] + (2 ... 99).map({ "baia-backup-\($0)" }) {
            write("occupied", to: layout.settings.appendingPathExtension(suffix))
        }

        guard case let .refused(reason) = HookInstaller.install(layout) else {
            Issue.record("settings were replaced without a fresh backup")
            return
        }
        #expect(reason.contains("could not back up"))
        #expect(reason.contains("wrote \(layout.script.path)"))
        #expect(reason.contains("Nothing was changed") == false)
        #expect(read(layout.settings) == HookInstallTests.foreign)
        #expect(FileManager.default.fileExists(atPath: layout.script.path))
    }

    // MARK: The registration

    /// Registered only where the pollers are blind. A `PreToolUse` with no matcher
    /// would fire on every tool call and spawn three processes each time, to learn
    /// something `PaneActivity` already knows.
    @Test func onlyTheEventsThePollersCannotSeeAreRegistered() {
        let entries = HookInstaller.entries(scriptPath: "/x/baia-agent-state.sh")
        #expect(entries.map(\.event) == ["PreToolUse", "PostToolUse", "Stop", "StopFailure", "SessionEnd"])
        #expect(entries[0].matcher == "^AskUserQuestion$")
        #expect(entries[1].matcher == "^AskUserQuestion$")
        #expect(entries[2].matcher == nil)
    }

    /// A home directory with a space in it must not become two arguments.
    @Test func theCommandIsQuotedForTheShellThatRunsIt() {
        let quoted = HookInstaller.quotedForShell("/Users/a b/.claude/hooks/baia-agent-state.sh")
        #expect(quoted == "'/Users/a b/.claude/hooks/baia-agent-state.sh'")
        #expect(HookInstaller.quotedForShell("/it's/here") == "'/it'\\''s/here'")
    }

    // MARK: Uninstalling

    @Test func uninstallRemovesTheHooksAndTheScript() {
        let layout = HookInstaller.Layout.standard(home: makeHome())
        write(HookInstallTests.foreign, to: layout.settings)
        _ = HookInstaller.install(layout)

        guard case .changed = HookInstaller.uninstall(layout) else {
            Issue.record("did not uninstall")
            return
        }
        #expect(FileManager.default.fileExists(atPath: layout.script.path) == false)
        #expect(read(layout.settings).contains("baia-agent-state.sh") == false)
    }

    /// **The round trip through the real filesystem.** What the owner had before
    /// the install is what they have after the uninstall, byte for byte.
    @Test func installThenUninstallLeavesTheFileAsItWas() {
        let layout = HookInstaller.Layout.standard(home: makeHome())
        write(HookInstallTests.foreign, to: layout.settings)
        _ = HookInstaller.install(layout)
        _ = HookInstaller.uninstall(layout)
        #expect(read(layout.settings) == HookInstallTests.foreign + "\n")
    }

    @Test func uninstallingTwiceIsNotAnError() {
        let layout = HookInstaller.Layout.standard(home: makeHome())
        write(HookInstallTests.foreign, to: layout.settings)
        _ = HookInstaller.install(layout)
        _ = HookInstaller.uninstall(layout)
        #expect(HookInstaller.uninstall(layout) == .unchanged)
    }

    /// A file at baia's path carrying no baia header is somebody else's, however
    /// unlikely, and deleting it would be the destructive half of a command whose
    /// whole job is to leave no trace.
    @Test func aScriptWithNoHeaderIsLeftWhereItIs() {
        let layout = HookInstaller.Layout.standard(home: makeHome())
        write(HookInstallTests.foreign, to: layout.settings)
        _ = HookInstaller.install(layout)
        write("#!/bin/sh\necho not baia\n", to: layout.script)

        guard case let .changed(notes) = HookInstaller.uninstall(layout) else {
            Issue.record("did not uninstall")
            return
        }
        #expect(FileManager.default.fileExists(atPath: layout.script.path))
        #expect(notes.contains { $0.contains("no baia header") })
    }

    // MARK: Two bugs found by running it for real

    /// **`$HOME` wins over `NSHomeDirectory()`.** That function reads `getpwuid`
    /// and ignores the environment, so a caller pointing `HOME` at a fixture was
    /// silently ignored. Found 2026-07-30 by a run meant for a temporary directory
    /// that installed into the owner's own `~/.claude` instead.
    @Test func theHomeComesFromTheEnvironmentWhenThereIsOne() {
        let resolved = HookInstaller.Layout.home()
        if let fromEnvironment = ProcessInfo.processInfo.environment["HOME"],
           fromEnvironment.isEmpty == false {
            #expect(resolved.path == URL(fileURLWithPath: fromEnvironment).path)
        }
    }

    /// **A backup never overwrites a backup.** The first version clobbered its
    /// own, so an uninstall replaced the pre-install copy with the installed
    /// state, and the one file worth having if the uninstall were wrong was
    /// destroyed by the uninstall itself.
    @Test func theOldestBackupSurvivesEveryLaterRun() {
        let layout = HookInstaller.Layout.standard(home: makeHome())
        write(HookInstallTests.foreign, to: layout.settings)

        _ = HookInstaller.install(layout)
        _ = HookInstaller.uninstall(layout)

        let first = layout.settings.appendingPathExtension("baia-backup")
        #expect(read(first) == HookInstallTests.foreign, "the pre-install backup was overwritten")
        #expect(FileManager.default.fileExists(
            atPath: layout.settings.appendingPathExtension("baia-backup-2").path
        ), "the second run did not leave its own backup")
    }
}
