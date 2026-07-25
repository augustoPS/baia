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

    public init() {}

    public var attention: PaneAttention { current }

    /// Returns true when the attention state changed, so the caller only
    /// redraws on change.
    ///
    /// A bell while already requesting is not a change. A program at a prompt
    /// may ring on every keystroke it rejects, and a pane whose indicator
    /// redrew on each one would flash rather than stay lit.
    public mutating func noteBell() -> Bool {
        // A bare bell must not overwrite a message that arrived first. The
        // message carries which repository asked, which is the entire reason
        // for showing it, and OSC 9 plus a bell is one event delivered twice:
        // Claude Code's `iterm2_with_bell` channel emits both for a single
        // request.
        guard case .none = current else { return false }
        current = .requested(message: nil)
        return true
    }

    public mutating func noteNotification(title: String, body: String) -> Bool {
        let next = PaneAttention.requested(message: Self.message(title: title, body: body))
        // Compared as a whole rather than only against `.none`, because a
        // second notification with new text is new information the caller has
        // to redraw for, while a repeat of the same text is not.
        guard next != current else { return false }
        current = next
        return true
    }

    /// Focusing a pane is the acknowledgement. Clears attention.
    ///
    /// There is no timeout and no explicit dismiss. The owner moving to the
    /// pane is the only acknowledgement that means anything, and a timeout
    /// would clear the indicator on a pane that is still sitting at a prompt
    /// waiting.
    public mutating func noteFocused() -> Bool {
        guard case .requested = current else { return false }
        current = .none
        return true
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
