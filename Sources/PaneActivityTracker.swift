import AppKit
import PaneActivity
import PaneChrome

/// One pane's answer to "what is running here, and does it want me?"
///
/// Those are two questions with two sources, deliberately kept apart. What is
/// running comes from the kernel and is always available. Whether the pane wants
/// the user cannot be read from a process tree at all: an agent thinking and an
/// agent waiting at a prompt are both a live `node` doing very little, and a CPU
/// threshold would give a confident answer that is wrong about half the time.
/// That second question is answered only when the pane says so, through a bell
/// or an OSC 9 notification.
@MainActor
final class PaneActivityTracker {
    var onChange: (() -> Void)?

    private(set) var agent: PaneStatus.Agent?

    /// Supplied by the pane, because reading it means reaching into a terminal
    /// surface and this type never does.
    private let foregroundPid: () -> pid_t?

    private var attention = PaneAttentionState()
    private var activity: PaneActivity = .idleShell
    private var timer: Timer?

    /// Slower than the anchor's poll. Walking every process on the machine is
    /// more expensive than one `proc_pidinfo` call, and a label naming what is
    /// running does not need to be current to the second.
    private static let pollInterval: TimeInterval = 2

    init(foregroundPid: @escaping () -> pid_t?) {
        self.foregroundPid = foregroundPid
    }

    func startPolling() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
    }

    /// No `deinit` counterpart, for the same reason as the other trackers: Swift
    /// 6 forbids touching a non-Sendable `Timer` from a nonisolated deinit, and a
    /// scheduled timer is retained by the run loop, so a pane relying on
    /// deallocation would leave it firing against a nil target forever.
    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Signals from the surface

    /// A bell. Claude Code emits one when it wants input, if its notification
    /// channel is set to a form that rings, so this is the signal that turns
    /// "which of my four agents needs me" from a guess into a fact.
    func noteBell() {
        guard attention.noteBell() else { return }
        rebuild()
    }

    /// OSC 9 or OSC 777. Carries a message, so the footer can say what is wanted
    /// rather than only that something is.
    func noteNotification(title: String, body: String) {
        guard attention.noteNotification(title: title, body: body) else { return }
        rebuild()
    }

    /// Focusing the pane is the acknowledgement. Nothing else clears attention,
    /// because a pane that stops asking on its own was never answered.
    func noteFocused() {
        guard attention.noteFocused() else { return }
        rebuild()
    }

    var wantsAttention: Bool {
        attention.attention != .none
    }

    // MARK: - Polling

    /// A pane with no foreground process is mid-exec and reports nothing rather
    /// than falling back to idle, which would make every command launch flicker
    /// the label.
    private func poll() {
        guard let foreground = foregroundPid() else { return }
        // Rooted at the app rather than at the pane's foreground process.
        // `foregroundPid` is `tcgetpgrp`, so it names the running command, not
        // the shell, and a tree rooted there cannot see the shell above it.
        let tree = ProcessTree.snapshot(under: ProcessInfo.processInfo.processIdentifier)
        guard let shell = shellPid(above: foreground, in: tree) else { return }
        let next = PaneActivityClassifier.classify(tree: tree, shellPid: shell)
        guard next != activity else { return }
        activity = next
        rebuild()
    }

    /// The pane's shell: the nearest shell at or above the foreground process.
    ///
    /// Passing the foreground pid as the shell instead is the obvious mistake
    /// and it fails silently. `classify` excludes the shell by pid and looks only
    /// below it, so a pane running `sleep` would report the sleep as its own
    /// shell, find nothing beneath, and read as idle forever. The tell is a pane
    /// that never labels anything while plainly running something.
    private func shellPid(above pid: pid_t, in tree: [ProcessSnapshot]) -> pid_t? {
        let byPid = Dictionary(tree.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var current = pid
        // Bounded rather than trusting the parent chain to terminate. These
        // pointers come from one kernel snapshot and should form a tree, but a
        // loop here would hang the main thread on a poll timer.
        for _ in 0 ..< 64 {
            guard let process = byPid[current] else { return nil }
            if PaneActivityClassifier.shellNames.contains(Self.normalized(process.name)) {
                return process.pid
            }
            current = process.parentPid
        }
        return nil
    }

    /// A login shell presents itself as `-zsh`, and the leading hyphen is a
    /// convention rather than part of the name.
    private static func normalized(_ name: String) -> String {
        name.hasPrefix("-") ? String(name.dropFirst()) : name
    }

    private func rebuild() {
        let next = paneAgent()
        guard next != agent else { return }
        agent = next
        onChange?()
    }

    /// An idle shell with nothing to say contributes no segment at all, so a pane
    /// sitting at a prompt shows its project and git state and nothing else.
    private func paneAgent() -> PaneStatus.Agent? {
        let label = label(for: activity)
        guard label != nil || wantsAttention else { return nil }
        return PaneStatus.Agent(
            label: label ?? attentionLabel,
            wantsAttention: wantsAttention
        )
    }

    /// What an attention request says when nothing is running to name. A bell
    /// from a pane whose command already exited still deserves a marker.
    private var attentionLabel: String {
        guard case let .requested(message) = attention.attention, let message else {
            return "!"
        }
        return message
    }

    private func label(for activity: PaneActivity) -> String? {
        switch activity {
        case .idleShell: nil
        case let .agent(name, _): name
        case let .build(command): command
        case let .command(name): name
        }
    }
}
