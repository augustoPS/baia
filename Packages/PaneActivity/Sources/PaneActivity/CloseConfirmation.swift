import Foundation

/// What a close is about to take with it.
public enum CloseScope: Sendable, Equatable {
    case pane
    case tab
    case window
    case quit
}

/// Whether a close has to ask first, and what it says when it does.
///
/// The policy is the owner's (2026-09-06): any close that would end a running
/// job asks; a close of idle shells does not. `baia close` over the control
/// socket never comes here, because automation that asks for a close has
/// already decided.
///
/// Busy is everything except ``PaneActivity/idleShell``. That includes
/// ``PaneActivity/unnameable``: the detector could not name what is below the
/// shell, and the honest response to "I cannot tell" is to ask, not to close.
public struct CloseConfirmation: Sendable, Equatable {
    public let title: String
    public let detail: String
    public let confirmTitle: String

    /// Nil when nothing in `activities` is running, which means close now.
    public static func needed(for scope: CloseScope, activities: [PaneActivity]) -> CloseConfirmation? {
        let busy = activities.filter { !PaneActivity.isIdle($0) }
        guard !busy.isEmpty else { return nil }

        var labels: [String] = []
        for activity in busy {
            let label = activity.label ?? "an unnamed process"
            if !labels.contains(label) { labels.append(label) }
        }

        let (noun, verb, confirm) = switch scope {
        case .pane: ("the pane", "Closing the pane", "Close Pane")
        case .tab: ("the tab", "Closing the tab", "Close Tab")
        case .window: ("the window", "Closing the window", "Close Window")
        case .quit: ("", "Quitting", "Quit")
        }
        let action = scope == .quit ? "Quit" : "Close \(noun)"

        if busy.count == 1 {
            let named = busy[0].label.map { "\($0) is running" } ?? "something is still running"
            return CloseConfirmation(
                title: "\(action) while \(named)?",
                detail: "\(verb) ends \(labels[0]) and everything it started.",
                confirmTitle: confirm
            )
        }
        return CloseConfirmation(
            title: "\(action) while \(busy.count) panes are still running?",
            detail: "Running: \(labels.joined(separator: ", ")). \(verb) ends them.",
            confirmTitle: confirm
        )
    }
}
