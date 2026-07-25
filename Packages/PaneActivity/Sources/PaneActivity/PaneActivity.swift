import Foundation

/// What is running in a pane, as far as a process tree can honestly say.
///
/// A process tree cannot distinguish an agent that is thinking from one that is
/// waiting for input. Both are a live process doing very little, and both look
/// identical in every field ``ProcessTree`` can read. A CPU threshold does not
/// rescue it either: an agent streaming a long answer and an agent blocked at a
/// prompt swap places depending on the second the poll happens to sample, so a
/// threshold would produce a confident answer that is wrong half the time.
///
/// So this type answers only what is running, and ``PaneAttentionState``
/// answers whether the pane wants the user. Conflating the two is the mistake
/// to avoid: the second question has a reliable answer and it does not come
/// from the kernel, it comes from the pane saying so.
public enum PaneActivity: Sendable, Equatable {
    /// Nothing but the pane's own shell.
    case idleShell
    /// A coding agent. `name` is the canonical agent name, not the process
    /// name.
    case agent(name: String, pid: pid_t)
    /// A build or a package manager. `command` is the canonical command name
    /// from ``PaneActivityClassifier/buildCommands``, not the whole command
    /// line, which is unavailable for anything this user does not own.
    case build(command: String)
    /// Anything else the shell is running, named by the most specific
    /// identifier the kernel yielded for it.
    case command(name: String)
}
