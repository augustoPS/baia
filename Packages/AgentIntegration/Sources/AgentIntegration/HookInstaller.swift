import Foundation

/// Putting the hook on disk and into `settings.json`, and taking it off again.
///
/// **Paths are injected rather than reached for**, so every rule below is tested
/// against a temporary directory. An installer whose only exercise is the real
/// run is one whose failure mode is somebody's config.
public enum HookInstaller {
    public struct Layout: Sendable, Equatable {
        public var settings: URL
        public var script: URL

        public init(settings: URL, script: URL) {
            self.settings = settings
            self.script = script
        }

        /// The home directory to install into.
        ///
        /// **`$HOME` first, and `NSHomeDirectory()` only as a fallback.** That
        /// function reads `getpwuid` and ignores the environment, so a caller
        /// pointing `HOME` at a fixture is silently ignored and writes to the real
        /// one instead. Found on 2026-07-30 by doing exactly that: a run meant for
        /// a temporary directory installed into the owner's own `~/.claude`.
        ///
        /// Honouring `$HOME` is also what every other tool that edits a dotfile
        /// does, so a caller who sets it is already expecting this.
        public static func home() -> URL {
            if let home = ProcessInfo.processInfo.environment["HOME"], home.isEmpty == false {
                return URL(fileURLWithPath: home)
            }
            return URL(fileURLWithPath: NSHomeDirectory())
        }

        /// Where Claude Code keeps its settings, and where baia puts a file of its
        /// own beside them rather than inside them.
        public static func standard(home: URL) -> Layout {
            let claude = home.appending(path: ".claude")
            return Layout(
                settings: claude.appending(path: "settings.json"),
                script: claude.appending(path: "hooks").appending(path: "baia-agent-state.sh")
            )
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// What changed, one line per thing, for a command the owner ran at their
        /// own prompt and is entitled to see the effect of.
        case changed([String])
        case unchanged
        case refused(String)
    }

    /// The events baia registers for, and the matchers it registers under.
    ///
    /// **Narrower than the spec's table, on purpose.** Section 3 maps every
    /// `PreToolUse` that is not `AskUserQuestion` to `working`, which is what
    /// herdr does because herdr has no process tree to consult. baia already
    /// knows a pane is working: `PaneActivity` polls the tree once a second and
    /// ranks the agent above every child it spawns.
    ///
    /// So the hook is registered only where the pollers are blind. Blocked cannot
    /// be seen from a process tree, because an agent thinking and an agent waiting
    /// are the same live process doing very little. Idle cannot be seen either,
    /// because a resident agent never exits.
    ///
    /// The cost of the wide reading is the argument: a `PreToolUse` with no
    /// matcher fires on every tool call, and each firing spawns a shell and two
    /// `python3` processes. That is a real tax on a busy agent in exchange for a
    /// fact baia already had.
    ///
    /// The script still answers the wide cases, so a hand-widened matcher keeps
    /// working rather than reporting nothing.
    public static func entries(scriptPath: String) -> [HookEntry] {
        let command = quotedForShell(scriptPath)
        return [
            HookEntry(event: "PreToolUse", matcher: "^AskUserQuestion$", command: command),
            HookEntry(event: "PostToolUse", matcher: "^AskUserQuestion$", command: command),
            HookEntry(event: "Stop", matcher: nil, command: command),
            HookEntry(event: "SessionEnd", matcher: nil, command: command),
        ]
    }

    /// A path Claude Code will hand to a shell, so a home directory with a space
    /// in it does not become two arguments.
    static func quotedForShell(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Installing

    public static func install(_ layout: Layout, version: Int = ManagedHeader.currentVersion) -> Outcome {
        var notes: [String] = []

        guard let document = readSettings(layout.settings) else {
            return .refused(
                "\(layout.settings.path) is not valid JSON. Nothing was changed: a hand edit is "
                    + "worth more than this install, and repairing it is not baia's to attempt."
            )
        }

        let installed = HookDocument.install(
            entries(scriptPath: layout.script.path), ownedBy: layout.script.path, into: document
        )
        guard let installed else {
            return .refused(
                "\(layout.settings.path) holds a hooks section in a shape baia does not understand. "
                    + "Nothing was changed."
            )
        }

        // The script first. A settings file pointing at a file that is not there
        // yet is a window in which every hook invocation fails, and though the
        // hook fails silently by design, the window is avoidable.
        switch writeScript(layout, version: version) {
        case let .refused(reason): return .refused(reason)
        case let .changed(lines): notes += lines
        case .unchanged: break
        }

        if installed == document {
            return notes.isEmpty ? .unchanged : .changed(notes)
        }
        guard let backup = backUp(layout.settings) else {
            return .refused("could not back up \(layout.settings.path). Nothing was changed.")
        }
        notes += backup
        guard writeAtomically(installed.serialized() + "\n", to: layout.settings) else {
            return .refused("could not write \(layout.settings.path). Nothing was changed.")
        }
        for entry in entries(scriptPath: layout.script.path) {
            notes.append("hooked \(entry.event)\(entry.matcher.map { " on \($0)" } ?? "")")
        }
        return .changed(notes)
    }

    // MARK: Uninstalling

    public static func uninstall(_ layout: Layout) -> Outcome {
        guard let document = readSettings(layout.settings) else {
            return .refused("\(layout.settings.path) is not valid JSON. Nothing was changed.")
        }
        guard let stripped = HookDocument.uninstall(ownedBy: layout.script.path, from: document) else {
            return .refused(
                "\(layout.settings.path) holds a hooks section in a shape baia does not understand. "
                    + "Nothing was changed."
            )
        }

        var notes: [String] = []
        if stripped != document {
            guard let backup = backUp(layout.settings) else {
                return .refused("could not back up \(layout.settings.path). Nothing was changed.")
            }
            notes += backup
            guard writeAtomically(stripped.serialized() + "\n", to: layout.settings) else {
                return .refused("could not write \(layout.settings.path). Nothing was changed.")
            }
            notes.append("unhooked every event baia had registered")
        }

        if FileManager.default.fileExists(atPath: layout.script.path) {
            // Removed only when baia wrote it. A file at that path with no managed
            // header is somebody else's, however unlikely, and deleting it would
            // be the destructive half of a command meant to leave no trace.
            let text = (try? String(contentsOf: layout.script, encoding: .utf8)) ?? ""
            if ManagedHeader.version(in: text) != nil {
                try? FileManager.default.removeItem(at: layout.script)
                notes.append("removed \(layout.script.path)")
            } else {
                notes.append("left \(layout.script.path) alone: it carries no baia header")
            }
        }

        return notes.isEmpty ? .unchanged : .changed(notes)
    }

    // MARK: The pieces

    /// An absent settings file is an empty document rather than a refusal: a
    /// machine that has never written one is a machine baia can still install on.
    static func readSettings(_ url: URL) -> JSON? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .object(JSONObject())
        }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return .object(JSONObject())
        }
        return JSON.parse(text)
    }

    static func writeScript(_ layout: Layout, version: Int) -> Outcome {
        let wanted = HookScript.installable(version: version)
        if let existing = try? String(contentsOf: layout.script, encoding: .utf8), existing == wanted {
            return .unchanged
        }
        let directory = layout.script.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard writeAtomically(wanted, to: layout.script) else {
            return .refused("could not write \(layout.script.path). Nothing was changed.")
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: layout.script.path
        )
        return .changed(["wrote \(layout.script.path)"])
    }

    /// A copy beside the original before the first write of a run.
    ///
    /// Named rather than hidden, and left behind rather than cleaned up: the point
    /// is that the owner can find it without being told where to look.
    ///
    /// **An existing backup is never overwritten.** The first version was clobbered
    /// by the next run, so an uninstall replaced the pre-install copy with the
    /// installed state, and the one file worth having if the uninstall were wrong
    /// was destroyed by the uninstall itself. Found 2026-07-30 the only way that
    /// can be found. Later runs write `.baia-backup-2` and so on, so the oldest
    /// copy, which is the one from before baia touched anything, always survives.
    static func backUp(_ url: URL) -> [String]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var backup = url.appendingPathExtension("baia-backup")
        var suffix = 2
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = url.appendingPathExtension("baia-backup-\(suffix)")
            suffix += 1
            guard suffix < 100 else {
                return ["kept \(url.lastPathComponent) backups already on disk and made no more"]
            }
        }
        do {
            try FileManager.default.copyItem(at: url, to: backup)
        } catch {
            return nil
        }
        return ["backed up to \(backup.path)"]
    }

    /// Temp file plus rename, so a crash between the two leaves the original whole
    /// rather than a half-written config.
    static func writeAtomically(_ text: String, to url: URL) -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
