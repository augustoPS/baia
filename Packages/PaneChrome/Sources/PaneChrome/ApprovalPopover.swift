import Foundation

/// What the approval popover does, decided without a window (design v5 §6).
///
/// The popover springs from the footer's attention capsule and writes exactly
/// one keystroke into the pane it was opened from: nothing here reaches a
/// pane, a surface, or AppKit. `TerminalPaneController.send(_:)` already
/// exists (the sidebar's path picker uses it) and is the one place the bytes
/// this type produces are handed to a real terminal.
public enum ApprovalPopover {
    /// The popover's two buttons. Both are also what ⏎ and ⎋ mean while the
    /// popover holds the keyboard — there is no third action, so a caller
    /// mapping a key event has nowhere else to route it.
    public enum Action: Sendable, Equatable, CaseIterable {
        case approve
        case deny
    }

    /// Whether a click inside the capsule's frame should present the popover.
    ///
    /// Gated on attention rather than on the click alone, because the capsule
    /// only draws for `.asking` and `.acknowledged`
    /// (``PaneStatusBarView/capsuleRect()``'s own rule): a done pane shows a
    /// bare ✓, a fact rather than a question, and there is nothing to open on
    /// it. Matching that rule here rather than re-deriving it from
    /// `PaneStatus.Attention` at the call site is what keeps the capsule's
    /// fill, its hit target, and the popover's gate from drifting apart.
    public static func presents(for attention: PaneStatus.Attention) -> Bool {
        attention == .asking || attention == .acknowledged
    }

    /// The bytes ``Action`` writes into the pane's own surface, one keystroke
    /// per press and nothing else on the wire. Approve is what ⏎ means to the
    /// prompt the agent is showing; deny is what ⎋ means. Both are exactly the
    /// single byte a real key press would send, not a line of text: sending
    /// more would be answering a question the popover was never shown.
    public static func bytes(for action: Action) -> [UInt8] {
        switch action {
        case .approve: [0x0D] // carriage return, the same byte a real ⏎ sends
        case .deny: [0x1B] // escape, the same byte a real ⎋ sends
        }
    }

    /// The popover's body text: the reported attention message verbatim, or a
    /// fallback for a pane that only rang the bell and said nothing.
    ///
    /// Trimmed rather than tested for exact emptiness, because a message that
    /// is all whitespace reads as blank to the owner and should fall back the
    /// same way nil does.
    public static func body(for message: String?) -> String {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Waiting for input" : trimmed
    }
}
