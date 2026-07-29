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

    /// What to call this, or nil when nothing is running.
    ///
    /// **Here rather than in the app, because this is the answer to "what is
    /// running" and it must not be reachable from anything holding the answer to
    /// "does the pane want the owner".** The two questions have different sources
    /// and the type's own note above says conflating them is the mistake to
    /// avoid. It was made anyway: the footer's combined value substituted the
    /// attention message whenever this was nil, so an idle pane that rang
    /// reported the message as the thing it was running, and the control
    /// channel's `activityChanged` inherited that when it read the same property.
    ///
    /// Nil for an idle shell is the load-bearing case. A caller that wants
    /// something to draw for an idle pane substitutes at the point of drawing,
    /// where the substitution is a display decision and stays one.
    public var label: String? {
        switch self {
        case .idleShell: nil
        case let .agent(name, _): name
        case let .build(command): command
        case let .command(name): name
        }
    }
}
