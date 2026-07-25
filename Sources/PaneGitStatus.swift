import AppKit
import GitWorkspace
import PaneChrome
import ProjectAnchor

/// One pane's git state, refreshed off the main thread.
///
/// Reads the repository the pane's anchor names, never the shell's working
/// directory. A pane sitting three directories deep in a repository shows that
/// repository's branch, which is the whole point of anchoring.
@MainActor
final class PaneGitStatus {
    /// Fires only when the rendered value actually changes, so a poll that finds
    /// nothing new redraws nothing.
    var onChange: ((PaneStatus.Git?) -> Void)?

    private(set) var git: PaneStatus.Git?

    private let command = GitCommand()

    /// Utility rather than default: a status read is never what the user is
    /// waiting on, and forking git at user-initiated priority on every poll
    /// would have four panes competing with the terminal for the main queue.
    private let queue = DispatchQueue(label: "gutons.baia.git-status", qos: .utility)

    /// The repository currently being watched. Compared before every refresh
    /// because `anchorTracker.onChange` fires on every `cd`, and a pane moving
    /// around inside one repository must not restart the poll each time.
    private var root: URL?
    private var isLinkedWorktree = false

    /// A read is in flight. Without this a slow `git status`, which happens on a
    /// large repository or a cold cache, would let the poll timer stack requests
    /// until several forks return at once.
    private var isReading = false

    /// A change arrived while a read was in flight, so the answer now in flight
    /// is already stale and one more read is owed.
    private var isStale = false

    private var timer: Timer?

    private static let pollInterval: TimeInterval = 3

    /// Points at a new anchor, or at none.
    ///
    /// Returns without work when the repository has not moved. That guard is
    /// load bearing: this is called from the one-second anchor poll, so without
    /// it every tick would fork git in every pane.
    func setAnchor(_ anchor: Anchor?) {
        let next = repositoryRoot(for: anchor)
        guard next != root else { return }
        root = next
        isLinkedWorktree = next.map { GitDirectory.isLinkedWorktree(repositoryRoot: $0) } ?? false
        // Cleared rather than left stale. Showing the previous repository's
        // branch under a new anchor's name is worse than showing nothing, and it
        // is exactly the wrong-repo confusion the footer exists to prevent.
        apply(nil)
        refresh()
    }

    /// Polling follows the window's focus, like the anchor tracker's. An
    /// unfocused window forks nothing.
    func startPolling() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    /// Called when the pane loses focus and when it leaves the window. There is
    /// deliberately no `deinit` doing this: Swift 6 forbids touching a
    /// non-Sendable `Timer` from a nonisolated deinit, and a scheduled timer is
    /// retained by the run loop, so a pane that relied on deallocation to stop
    /// it would leave it firing against a nil target forever.
    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// Only a repository anchor has git state. A plain directory anchor gets
    /// nil, and `PaneStatusSegments` then emits no git segments at all rather
    /// than a branch-shaped blank.
    private func repositoryRoot(for anchor: Anchor?) -> URL? {
        guard let anchor, anchor.kind == .repository else { return nil }
        return anchor.url
    }

    private func refresh() {
        guard let root else {
            apply(nil)
            return
        }
        guard !isReading else {
            isStale = true
            return
        }
        isReading = true

        let command = self.command
        let requested = root
        queue.async { [weak self] in
            let status = command.status(ofRepositoryRoot: requested)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finish(status, from: requested)
                }
            }
        }
    }

    private func finish(_ status: RepositoryStatus?, from requested: URL) {
        isReading = false
        // The anchor may have moved while git was running. Applying this answer
        // would label the new repository with the old one's branch, so it is
        // dropped and the newer read stands on its own.
        guard requested == root else {
            if isStale { isStale = false; refresh() }
            return
        }
        apply(status.map(paneGit))
        if isStale {
            isStale = false
            refresh()
        }
    }

    private func apply(_ next: PaneStatus.Git?) {
        guard next != git else { return }
        git = next
        onChange?(next)
    }

    private func paneGit(_ status: RepositoryStatus) -> PaneStatus.Git {
        PaneStatus.Git(
            head: status.displayHead,
            hasUpstream: status.upstream != nil,
            ahead: status.ahead,
            behind: status.behind,
            // Conflicts count as dirty, matching how the owner's own statusline
            // derives its asterisk from `git diff --quiet`, which reports an
            // unmerged path as a difference.
            dirty: status.staged > 0 || status.unstaged > 0 || status.conflicted > 0,
            untracked: status.untracked,
            conflicted: status.conflicted,
            operation: label(for: status.inProgress),
            isLinkedWorktree: isLinkedWorktree
        )
    }

    /// Upper case because these are the states where the next command does
    /// something other than what it usually does, and the footer is otherwise
    /// all lower case.
    private func label(for operation: RepositoryStatus.InProgress?) -> String? {
        switch operation {
        case .none: nil
        case .rebase: "REBASE"
        case .merge: "MERGE"
        case .cherryPick: "CHERRY-PICK"
        case .revert: "REVERT"
        case .bisect: "BISECT"
        }
    }
}
