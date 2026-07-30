import AppKit
import ProjectAnchor

/// One pane's live anchor: polls the pane's foreground process for its working
/// directory while the window has focus, applies the pin, and reports changes.
///
/// Takes the pid as a closure rather than a terminal view, so ProjectAnchor
/// never learns libghostty exists and this type never reaches into a surface.
@MainActor
final class PaneAnchorTracker {
    /// The `UserDefaults` key the pin used to live under, kept only to delete it.
    ///
    /// It was app-wide, which was wrong in a way that only showed up once a
    /// window held several panes: every pane resolved to the one pinned project
    /// regardless of where its own shell was, so the footer confidently named the
    /// wrong repository. The pin is now per-pane and lives in the session file
    /// alongside the pane it belongs to.
    private static let legacyPinDefaultsKey = "pinnedProjectDirectory"

    private let foregroundPid: () -> pid_t?
    private let resolver: AnchorResolver

    private var timer: Timer?

    /// A plain path rather than a security-scoped bookmark: baia is unsandboxed
    /// by design, so a path is enough and stays readable in the session file.
    /// Exposed so the owner can snapshot it; this type no longer persists
    /// anything itself.
    private(set) var pinnedDirectory: URL?

    /// Last directory successfully read. Exposed so the pane can show it as the
    /// window subtitle, which is the cwd rather than the anchor.
    private(set) var workingDirectory: URL?

    private(set) var anchor: Anchor?

    /// Fires when anything the pane displays changes, which is the anchor *or*
    /// the working directory. Keying this on the anchor alone was a bug: under an
    /// active pin the anchor never moves, so a `cd` left the subtitle showing a
    /// directory the shell had already left. Not once per poll, because `apply`
    /// returns early when the directory is unchanged.
    var onChange: (() -> Void)?

    var isPinned: Bool { pinnedDirectory != nil }

    init(
        foregroundPid: @escaping () -> pid_t?,
        resolver: AnchorResolver = .init(),
        pinnedDirectory: URL? = nil
    ) {
        self.foregroundPid = foregroundPid
        self.resolver = resolver
        self.pinnedDirectory = pinnedDirectory
    }

    /// Removes the app-wide pin the earlier design left behind.
    ///
    /// Nothing reads that key any more, so a leftover value is inert rather than
    /// harmful, but it would sit in the defaults domain forever looking like live
    /// configuration to anyone inspecting it. One call at launch is cheaper than
    /// explaining it later.
    static func removeLegacyPin(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: legacyPinDefaultsKey)
    }

    // MARK: - Polling

    private static let pollInterval: TimeInterval = 1

    /// Started when the window becomes key. An unfocused pane polls nothing, and
    /// the first poll runs immediately so focus returns a current anchor.
    func startPolling() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// A failed read keeps the last known directory. A shell mid-exec has no
    /// foreground process for a moment, and the title must not flicker.
    private func poll() {
        guard let pid = foregroundPid(),
              let directory = ProcessWorkingDirectory.url(ofProcess: pid)
        else { return }
        // Compared against what the *poll* last saw, not against
        // `workingDirectory`, and the difference is the whole point. An
        // announcement through `reportWorkingDirectory` moves
        // `workingDirectory` and cannot move the process, so a poll comparing
        // against `workingDirectory` would find a disagreement every single tick
        // and overwrite the announcement within the second. That is exactly the
        // case the announcement exists for: an agent that cds in a subshell moves
        // no process cwd at all, so the poll would clobber it forever.
        //
        // Comparing against the last polled value instead means the poll speaks
        // only when the process genuinely moved, which is what earns it the right
        // to overrule what it was told.
        guard directory != lastPolledDirectory else { return }
        lastPolledDirectory = directory
        apply(directory)
    }

    /// What the last successful poll read, whether or not it was applied.
    private var lastPolledDirectory: URL?

    /// The OSC 7 path, fed by the pane's pwd delegate.
    ///
    /// Something does emit OSC 7, contrary to what this comment used to claim: it
    /// arrives about 100 ms after every command, when the shell redraws its
    /// prompt, and it re-states the shell's directory whether or not that
    /// directory moved.
    ///
    /// Which is why it is guarded the same way the poll is. An unguarded OSC 7
    /// overwrote an announcement within a tenth of a second of it landing, so
    /// ``announceWorkingDirectory(_:)`` appeared to do nothing at all while doing
    /// exactly what it was asked. A source that repeats itself every prompt has
    /// no business overruling something it does not know about; it speaks only
    /// when its own reading changed.
    func reportWorkingDirectory(_ path: String) {
        let directory = URL(filePath: path, directoryHint: .isDirectory)
        guard directory != lastShellReport else { return }
        lastShellReport = directory
        apply(directory)
    }

    /// What the shell last said through OSC 7, whether or not it was applied.
    private var lastShellReport: URL?

    /// A working directory the pane was explicitly told about, over the control
    /// channel.
    ///
    /// Always applied, unlike the two observers. The poll and OSC 7 both watch a
    /// process that an agent cd-ing inside a subshell never moves, so neither can
    /// see what this reports, and neither should be able to talk over it. They
    /// take it back only by genuinely moving.
    func announceWorkingDirectory(_ path: String) {
        apply(URL(filePath: path, directoryHint: .isDirectory))
    }

    /// The early return is what keeps this quiet: a poll that reads the same
    /// directory changes nothing and notifies nobody.
    private func apply(_ directory: URL) {
        guard directory != workingDirectory else { return }
        workingDirectory = directory
        resolveAndNotify()
    }

    // MARK: - Pin

    /// Nothing is written here. The pin is part of the pane's state and is
    /// persisted with it, so the owner snapshots after `onChange` rather than
    /// this type reaching into storage of its own.
    func setPin(_ directory: URL) {
        pinnedDirectory = directory
        resolveAndNotify()
    }

    func clearPin() {
        pinnedDirectory = nil
        resolveAndNotify()
    }

    /// Every caller has already changed an input the pane displays, so this
    /// always notifies rather than comparing the resulting anchor.
    private func resolveAndNotify() {
        let resolution = resolver.resolve(workingDirectory: workingDirectory, pin: pinnedDirectory)
        // A pin whose directory has been deleted is dropped rather than kept and
        // ignored, so the next snapshot records the pane as unpinned instead of
        // restoring a pin that will never resolve again.
        if resolution.pinIsStale {
            pinnedDirectory = nil
        }
        anchor = resolution.anchor
        onChange?()
    }
}
