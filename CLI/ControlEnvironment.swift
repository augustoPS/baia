import Foundation

/// The two environment values a pane carries, and what each absence means.
///
/// Both arrive through `TerminalSurfaceOptions.envVars`, which is the one
/// channel macOS does not let another process read. The socket path deliberately
/// does not arrive through the terminal stream: rule 1 keeps every byte of this
/// protocol off the PTY, so there is no escape sequence that could tell a pane
/// where to talk.
enum ControlEnvironment {
    /// Where the instance that owns this pane is listening.
    ///
    /// Absent means this instance runs without a channel, which happens when a
    /// second baia found the socket already owned. That instance deliberately
    /// injects nothing rather than handing its panes the *first* instance's live
    /// socket, where their secrets were never registered: that would answer
    /// `badToken` with a completely misleading story.
    static var socketPath: String? {
        nonEmpty("BAIA_SOCK")
    }

    /// The calling pane's per-run secret.
    ///
    /// Read here and put straight into the request body. It is never echoed,
    /// never logged, and never placed in argv, because `ps -ww` and
    /// `KERN_PROCARGS2` show any same-uid process the full argv of any other.
    static var paneSecret: String? {
        nonEmpty("BAIA_TOKEN")
    }

    /// An empty variable is treated as an absent one. A shell that exported the
    /// name and lost the value is in the same position as one that never had it,
    /// and answering `badToken` for it would send the reader looking at the
    /// registry instead of at their environment.
    private static func nonEmpty(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            return nil
        }
        return value
    }
}
