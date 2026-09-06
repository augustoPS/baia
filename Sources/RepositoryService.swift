import Foundation
import GitWorkspace
import PaneChrome

/// The app's one ``RepositoryCenter``: one observer, one filesystem watch per
/// physical root, shared by every pane and every sidebar.
///
/// A single instance rather than one per pane, and this is the R07/R08 repair
/// at the ownership level: `PaneGitStatus` was one poller per pane, so two
/// panes on `~/Projects/vault` ran two identical `git status` processes every
/// tick, and the sidebar's tree cache was a second owner beside it with its own
/// lifecycle. Both are gone. A pane holds a ``RepositoryBinding`` from here and
/// nothing else reads git on a timer.
///
/// Reached as a static rather than threaded through `PaneTreeController`,
/// because the pane is built there with only its own facts and the centre is a
/// fact about the process: there is one, it outlives every window, and a pane
/// that took it as a parameter would take the same one every time.
@MainActor
enum RepositoryService {
    static let shared = RepositoryCenter(
        observer: RepositoryObserver(),
        events: FSEventsRepositoryAttacher()
    )
}

/// `RepositoryEvents` as the centre's watch. Constructed off the main actor by
/// the centre, since it resolves Git metadata and starts a stream synchronously.
struct FSEventsRepositoryAttacher: RepositoryEventsAttaching {
    func attach(
        root: URL,
        invalidate: @escaping @Sendable (URL, RepositoryInvalidation) -> Void
    ) throws -> any RepositoryEventsHandle {
        try RepositoryEvents(root: root) { url, reason in
            invalidate(url, reason == .metadata ? .metadata : .workingTree)
        }
    }
}

extension RepositoryEvents: RepositoryEventsHandle {}

extension RepositoryBinding {
    /// What the capsule, the place card and the control channel draw, from the
    /// current snapshot. Nil outside a repository and before the first read.
    var git: PaneStatus.Git? {
        guard let snapshot, let status = snapshot.status else { return nil }
        return PaneStatus.Git(
            status,
            operation: PaneStatus.Git.operationLabel(for: status.inProgress),
            isLinkedWorktree: snapshot.isLinkedWorktree
        )
    }

    /// The changed paths from the same snapshot as ``git``. Empty outside a
    /// repository, which is the same answer as a clean one; the capsule already
    /// says which.
    var changes: [RepositoryFileChange] {
        snapshot?.changes ?? []
    }

    /// True while nothing is known, which keeps an unresolved pane on a bare
    /// project name rather than flashing a branch for one poll.
    var isOnDefaultBranch: Bool {
        snapshot?.isOnDefaultBranch ?? true
    }
}
