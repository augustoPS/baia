import Foundation

/// What the pane wants from the user, which is a different question from what
/// is running.
public enum PaneAttention: Sendable, Equatable {
    case none

    /// The pane asked for attention: a bell, or an OSC 9 desktop notification.
    /// `message` is nil for a bare bell.
    case requested(message: String?)

    /// The pane is still waiting, but the user has been here since it asked.
    ///
    /// A third case rather than a flag beside the second, because the whole
    /// requirement (loud enough to find across four panes, quiet enough to work
    /// beside, settled once seen) is contradictory only while asking is one
    /// state. Focusing the pane used to drop straight back to ``none``, which
    /// answered "have you seen it" and threw away "is it still waiting", so a
    /// pane the user glanced at and left became indistinguishable from one that
    /// had gone back to work.
    case acknowledged(message: String?)

    /// The pane finished, and nobody has been here since it did.
    ///
    /// **A notification rather than a request**, which is the whole of why it is
    /// a fourth case and not a flag on the first two. ``requested`` persists
    /// because the pane wants something and goes on wanting it until the pane
    /// itself resumes, so a person may see it and choose not to answer, and that
    /// is why sight quiets it rather than clearing it. This carries no request:
    /// there is nothing to do but know, so once known it has no further job and
    /// decays fully.
    ///
    /// It has no message. A finished agent's report is a `idle` with no text
    /// riding it, the message field on the wire being carried on `blocked`
    /// alone, and inventing one here would put a stale `blocked` message on a
    /// pane that stopped asking for it.
    ///
    /// **Derived here rather than reported.** ``PaneReport`` has no fourth state
    /// and deliberately keeps none: a reporting agent can say it is idle, but
    /// whether anybody looked is a fact about the owner, and the channel already
    /// carries everything it can carry. This is resolved the same way
    /// ``acknowledged`` is, from a report and a recorded visit.
    case done

    /// True while the pane wants the user at all, at either volume.
    ///
    /// False for ``done``. A finished pane is worth drawing and is not worth
    /// interrupting for: it asks nothing, so anything reading this to decide
    /// whether the owner is needed must answer no.
    public var isRequesting: Bool {
        switch self {
        case .none, .done: false
        case .requested, .acknowledged: true
        }
    }

    /// True only while the pane has finished unseen.
    public var isDone: Bool {
        if case .done = self { return true }
        return false
    }

    /// True only for an unacknowledged request, which is the loud level.
    ///
    /// False for ``done``, which is unseen but is not loud. The two levels share
    /// the word "unseen" and nothing else: one is a question waiting on the
    /// owner, the other is a fact waiting to be read.
    public var isUnacknowledged: Bool {
        if case .requested = self { return true }
        return false
    }

    /// Whatever the request carried, at either volume. The message names which
    /// repository asked, which is the entire reason for showing it, so it has to
    /// survive being acknowledged.
    public var message: String? {
        switch self {
        case .none, .done: nil
        case let .requested(message), let .acknowledged(message): message
        }
    }

    /// The case as a word, for a reader and never for a comparison.
    public var name: String {
        switch self {
        case .none: "none"
        case .requested: "requested"
        case .acknowledged: "acknowledged"
        case .done: "done"
        }
    }
}

public extension PaneAttention {
    /// This attention once the pane's own statement about itself is taken into
    /// account.
    ///
    /// **The report owns whether the pane is asking; the latch owns how loudly.**
    /// A report answers "does the agent still need me". Acknowledgement answers
    /// "have I been here since it started", which is a different question a
    /// report has no view on, so it passes through untouched.
    ///
    /// A reported block that stayed loud until released was considered and
    /// rejected: it reproduces the failure recorded under the two-level model, a
    /// pane that ever rang staying marked for life, with the owner working in the
    /// very pane that is shouting. Intolerability at four panes is why
    /// ``acknowledged`` exists at all.
    ///
    /// **`blocked` is optional, and that is load-bearing.** Nil is "the pane has
    /// said nothing" and leaves the latch alone; `false` is "the agent says it is
    /// working", which outranks a bell the pane emitted earlier and silences it.
    /// A plain `Bool` folds those together and would make every pane with no
    /// report unable to ring.
    ///
    /// Takes a `Bool?` and a `String?` rather than the channel's own state enum,
    /// because this package imports Foundation and nothing else. The app maps one
    /// onto the other in one place, which is the call ``ActivityReading`` already
    /// makes and the reason `ControlAxis` and `SplitAxis` are separate types.
    /// - Parameter seen: whether the owner has been in this pane since the request
    ///   in force began. Load-bearing when the latch is ``none``, which is every
    ///   pane raised by a report with no bell behind it: the latch has no request
    ///   to have been acknowledged, so without this the volume could only ever be
    ///   loud. That was a real defect, found live on 2026-07-31 and fixed here,
    ///   and it covered the whole hook path while the bell path looked correct.
    func overridden(
        byReportedBlock blocked: Bool?,
        message: String?,
        seen: Bool = false
    ) -> PaneAttention {
        guard let blocked else { return self }
        guard blocked else { return .none }
        // Asking, at whatever volume the latch and the visit between them settle
        // on. The report's message wins, because the report is the thing asking
        // and the latch may be holding an hour-old bell from a build.
        //
        // A pane that had finished and is now blocked is asking again, and the
        // finish is over: the agent went back to work and stopped, so the
        // notification it left is answered by the question that replaced it.
        // Volume is decided by the visit exactly as for a pane that never
        // finished, because the visit a `done` would have consumed is one the
        // raise has already discarded.
        switch self {
        case .none, .requested, .done:
            return seen ? .acknowledged(message: message) : .requested(message: message)
        case .acknowledged: return .acknowledged(message: message)
        }
    }

    /// This attention once a report that the pane has *finished* is taken into
    /// account.
    ///
    /// **Deliberately a second function rather than a case inside
    /// ``overridden(byReportedBlock:message:seen:)``.** The two consume the same
    /// visit in opposite ways, and one function with a flag is how they come to
    /// disagree later:
    ///
    /// | | on a visit | ends on |
    /// |---|---|---|
    /// | a block | quiets, to ``acknowledged`` | `noteResumed`, from the classifier |
    /// | a finish | ends | the visit itself |
    ///
    /// The asymmetry is not a preference. A block is a request and goes on being
    /// one until the pane resumes, so seeing it answers "have you noticed" and
    /// leaves "is it still waiting" alone. A finish asks nothing, so being seen
    /// is the only thing that can happen to it, and `noteResumed` could not end
    /// one anyway: a finished agent does not resume, which is the entire reason
    /// `idle` crosses the channel rather than being read off the process tree.
    ///
    /// - Parameters:
    ///   - finished: whether the pane says it has finished. Not an optional and
    ///     not folded into the other function's `Bool?`, because the caller has
    ///     already decided this is a live report saying `idle`; "no statement"
    ///     and "says it is working" are distinctions that belong to the question
    ///     the other function asks.
    ///   - seen: the same recorded visit the other function reads, consumed
    ///     rather than quieted. False is what makes this ``done`` at all.
    func overridden(byReportedFinish finished: Bool, seen: Bool) -> PaneAttention {
        guard finished, !seen else { return self }
        return .done
    }
}
