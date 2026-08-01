import Foundation

/// Tracks a pane's attention over time. A pure state machine with no timers and
/// no AppKit: the app layer feeds it events and focus changes and reads the
/// result.
///
/// This exists because ``PaneActivityClassifier`` cannot answer the question
/// the owner actually asks, which is whether a pane wants them. An agent
/// thinking and an agent waiting at a prompt are the same live process doing
/// very little, and no reading of the process tree separates them. The reliable
/// signal is the pane *telling* us, which libghostty surfaces as
/// `TerminalSurfaceBellDelegate` and
/// `TerminalSurfaceDesktopNotificationDelegate`. Neither needs shell
/// integration, which matters because the bundled libghostty is a trimmed build
/// that ships none: both are driven by bytes the running program already emits.
///
/// The classifier names what is running, this answers whether it wants the
/// user, and conflating them is the mistake to avoid. Today the whole signal is
/// one `afplay Blow.aiff` fired identically from every session's Stop hook,
/// which across five concurrent panes names none of them.
public struct PaneAttentionState: Sendable, Equatable {
    private var current: PaneAttention = .none

    /// The pane's own last statement about itself, and what rode with it. Held
    /// here rather than beside the tracker so that one type answers "what does
    /// this pane want", which is what let the two disagree: acknowledgement lived
    /// in the latch, the report lived outside it, and a request that existed only
    /// outside had nothing acknowledgeable in it.
    private var reported: Bool?
    private var reportedMessage: String?

    /// Whether the owner has been in this pane since the request in force began.
    ///
    /// Separate from the latch's own ``PaneAttention/acknowledged`` case, and not
    /// a duplicate of it. That case can only exist where a bell or an OSC
    /// notification put a request into the latch; this holds for a pane whose only
    /// request came over the channel, where the latch stays ``PaneAttention/none``
    /// throughout. Reset when a request begins rather than when one ends, so a
    /// visit that predates a question does not answer it.
    private var seen = false

    public init() {}

    /// What the chrome draws, with the pane's own statement taken into account.
    ///
    /// **The report owns whether the pane is asking; the latch and the visit own
    /// how loudly.** Resolved on read rather than stored, so there is one place
    /// the three facts meet and no cached answer to go stale behind them.
    public var attention: PaneAttention {
        current.overridden(byReportedBlock: reported, message: reportedMessage, seen: seen)
    }

    /// Records what the pane says about itself.
    ///
    /// Returns true when the resolved attention moved, which is the same contract
    /// every other mutation here answers: the caller redraws on true and does
    /// nothing on false. A report that repeats itself moves nothing, and the hook
    /// repeats itself every few minutes.
    ///
    /// A block arriving where there was none is a *new* request, so an
    /// acknowledgement earned before it is dropped. The agent answered, went back
    /// to work and asked something else, and being in the pane for the first
    /// question says nothing about the second.
    public mutating func noteReported(blocked: Bool?, message: String?) -> Bool {
        let before = attention
        if blocked == true, reported != true { seen = false }
        reported = blocked
        reportedMessage = message
        return attention != before
    }

    /// Returns true when the attention state changed, so the caller only
    /// redraws on change.
    ///
    /// A bell while already requesting is not a change. A program at a prompt
    /// may ring on every keystroke it rejects, and a pane whose indicator
    /// redrew on each one would flash rather than stay lit.
    public mutating func noteBell() -> Bool {
        let before = attention
        switch current {
        case .none:
            current = .requested(message: nil)
            seen = false

        // A bell after the owner has already been here is a *new* request, and
        // it goes back to the loud level. An agent that finishes twice in one
        // session has to light the indicator twice, and the acknowledgement it
        // earned the first time was for the first request.
        //
        // The message is carried across rather than dropped. A bare bell has
        // none of its own, and the one already held names which repository
        // asked, which is the entire reason for showing it. A genuinely new
        // message arrives through `noteNotification` and overwrites this.
        case let .acknowledged(message):
            current = .requested(message: message)
            seen = false

        // A bare bell must not overwrite a message that arrived first, and a
        // repeat while already asking is not a change. OSC 9 plus a bell is one
        // event delivered twice: Claude Code's `iterm2_with_bell` channel emits
        // both for a single request, and a program at a prompt may ring on every
        // keystroke it rejects.
        case .requested:
            break
        }
        return attention != before
    }

    public mutating func noteNotification(title: String, body: String) -> Bool {
        let next = PaneAttention.requested(message: Self.message(title: title, body: body))
        // Compared as a whole rather than only against `.none`, because a
        // second notification with new text is new information the caller has
        // to redraw for, while a repeat of the same text is not.
        guard next != current else { return false }
        let before = attention
        current = next
        seen = false
        return attention != before
    }

    /// Focusing a pane acknowledges its request without ending it.
    ///
    /// There is no timeout and no explicit dismiss. The owner moving to the
    /// pane is the only acknowledgement that means anything, and a timeout
    /// would clear the indicator on a pane that is still sitting at a prompt
    /// waiting.
    ///
    /// This used to drop straight to ``PaneAttention/none``, which is the bug the
    /// two levels fix: a pane the owner glanced at is still waiting for him, and
    /// clearing the marker on sight made it indistinguishable from one that had
    /// gone back to work. The request now stays visible, quietly, until the pane
    /// actually resumes.
    public mutating func noteFocused() -> Bool {
        let before = attention
        // Recorded whatever the latch holds, including for a pane asking nothing.
        // The visit is the answer to "have I been here since it started", and a
        // pane with no request yet still has to be able to answer it. Nothing is
        // drawn for it until something asks, which is why this can be
        // unconditional without repainting every pane the owner clicks through.
        seen = true
        if case let .requested(message) = current {
            current = .acknowledged(message: message)
        }
        return attention != before
    }

    /// The pane went back to work, so whatever it was waiting for has arrived.
    ///
    /// This is the only thing that ends a request, and it is driven by the
    /// activity classifier rather than by a user action, because the question
    /// "is it still waiting" is about the pane and not about who looked at it.
    ///
    /// Called on the transition into a running agent rather than on every poll:
    /// an idle shell is not a resumption, or a pane whose bell arrived after its
    /// command exited would clear itself on the very next tick and the marker
    /// would never be seen at all.
    public mutating func noteResumed() -> Bool {
        let before = attention
        guard current.isRequesting else { return false }
        current = .none
        // The visit is left alone. It is reset where a request begins, and
        // clearing it here would silence nothing while costing the next request
        // its loud level if the owner never left the pane.
        return attention != before
    }

    /// Collapses a notification payload into one line, or nil when it carries
    /// nothing.
    ///
    /// OSC 9 has no title field, so the title arrives empty and the body is the
    /// whole message, while OSC 777 supplies both. Joining them here rather
    /// than in the app layer stops the two spellings of one request from
    /// producing two different looking indicators.
    ///
    /// An empty payload degrades to nil, which is the bare bell case. A
    /// notification with no text tells the user no more than a bell does, and
    /// keeping it as an empty string would put an empty tooltip on the
    /// indicator.
    private static func message(title: String, body: String) -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return body.isEmpty ? nil : body }
        if body.isEmpty { return title }
        return "\(title): \(body)"
    }
}
