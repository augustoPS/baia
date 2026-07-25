import AppKit
import ProjectAnchor

/// One pane's live anchor: polls the pane's foreground process for its working
/// directory while the window has focus, applies the pin, and reports changes.
///
/// Takes the pid as a closure rather than a terminal view, so ProjectAnchor
/// never learns libghostty exists and this type never reaches into a surface.
@MainActor
final class PaneAnchorTracker {
    /// The pin is app-wide rather than per-pane because pane identity is not yet
    /// stable: `TerminalPaneController.paneID` is a fresh UUID each launch, so a
    /// per-pane key could not survive a relaunch anyway. Migrating to per-session
    /// storage later means deleting this key.
    static let pinDefaultsKey = "pinnedProjectDirectory"

    /// Read with `defaults read gutons.baia pinnedProjectDirectory`. A plain path
    /// rather than a security-scoped bookmark: baia is unsandboxed by design, so
    /// a path is enough and stays inspectable.
    private let defaults: UserDefaults
    private let foregroundPid: () -> pid_t?
    private let resolver: AnchorResolver

    private var timer: Timer?
    private var pinnedDirectory: URL?

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
        defaults: UserDefaults = .standard
    ) {
        self.foregroundPid = foregroundPid
        self.resolver = resolver
        self.defaults = defaults
        if let stored = defaults.string(forKey: Self.pinDefaultsKey) {
            pinnedDirectory = URL(filePath: stored, directoryHint: .isDirectory)
        }
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
        apply(directory)
    }

    /// The OSC 7 path, fed by the pane's pwd delegate. Nothing emits OSC 7 today,
    /// but the conformance is one method: if anything ever does, updates stop
    /// waiting for the next tick.
    func reportWorkingDirectory(_ path: String) {
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

    func setPin(_ directory: URL) {
        pinnedDirectory = directory
        defaults.set(directory.path(percentEncoded: false), forKey: Self.pinDefaultsKey)
        resolveAndNotify()
    }

    func clearPin() {
        pinnedDirectory = nil
        defaults.removeObject(forKey: Self.pinDefaultsKey)
        resolveAndNotify()
    }

    /// Every caller has already changed an input the pane displays, so this
    /// always notifies rather than comparing the resulting anchor.
    private func resolveAndNotify() {
        let resolution = resolver.resolve(workingDirectory: workingDirectory, pin: pinnedDirectory)
        if resolution.pinIsStale {
            pinnedDirectory = nil
            defaults.removeObject(forKey: Self.pinDefaultsKey)
        }
        anchor = resolution.anchor
        onChange?()
    }
}
