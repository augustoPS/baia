import Foundation

/// Names the operation a repository is halfway through, by looking for the marker
/// files git leaves in the git directory.
public enum InProgressProbe {
    /// Filesystem probes inside the git directory: rebase-merge, rebase-apply,
    /// MERGE_HEAD, CHERRY_PICK_HEAD, REVERT_HEAD, BISECT_LOG. Cheaper and more
    /// reliable than parsing, since porcelain v2 does not report them at all.
    ///
    /// Pass the git directory, not the repository root. A linked worktree keeps
    /// its own markers under `.git/worktrees/<name>/`, so probing the root's
    /// `.git` would report the main tree's half-finished rebase in every worktree
    /// of the repository. ``GitDirectory/url(forRepositoryRoot:)`` resolves the
    /// right one.
    public static func detect(gitDirectory: URL) -> RepositoryStatus.InProgress? {
        // Rebase first, and both backends. The default merge backend writes
        // `rebase-merge`, while `git rebase --apply` and `git am` write
        // `rebase-apply`, so checking one covers half the cases. A halted rebase
        // also leaves `MERGE_MSG` and `AUTO_MERGE` behind (measured on git
        // 2.50.1), which is why neither of those is a marker here.
        if exists("rebase-merge", in: gitDirectory) { return .rebase }
        if exists("rebase-apply", in: gitDirectory) { return .rebase }

        if exists("MERGE_HEAD", in: gitDirectory) { return .merge }
        if exists("CHERRY_PICK_HEAD", in: gitDirectory) { return .cherryPick }
        if exists("REVERT_HEAD", in: gitDirectory) { return .revert }

        // Bisect last, because `BISECT_LOG` is written once by `git bisect start`
        // and removed only by `git bisect reset`, so it outlives every merge and
        // cherry-pick performed during the session (measured: present with
        // nothing else in progress, still present after a merge attempt).
        // Checking it first would report `.bisect` while the owner is actually
        // blocked on a conflict, which is the thing he has to fix.
        if exists("BISECT_LOG", in: gitDirectory) { return .bisect }
        return nil
    }

    /// True when `name` exists inside the git directory, as a file or a
    /// directory.
    ///
    /// `rebase-merge` and `rebase-apply` are directories while the rest are
    /// files, and `fileExists` covers both in one call, so the probe does not
    /// have to know which is which.
    private static func exists(_ name: String, in gitDirectory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: gitDirectory.appending(path: name).path(percentEncoded: false)
        )
    }
}
