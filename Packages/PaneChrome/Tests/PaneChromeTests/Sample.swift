import Foundation

@testable import PaneChrome

/// Builders for the values the pane's chrome consumes, with the boring fields
/// defaulted.
///
/// The production initializers deliberately have no defaults: a caller that
/// forgot to pass `dirty` would ship a capsule claiming a clean tree, which is
/// the exact failure the markers exist to prevent. The defaults live here instead,
/// so a test that is about ahead and behind counts does not have to spell out
/// seven other fields and bury what it is testing.
enum Sample {
    static func status(
        anchorName: String = "baia",
        anchorIsRepository: Bool = true,
        isPinned: Bool = false,
        workingDirectory: String? = nil,
        git: PaneStatus.Git? = nil,
        agent: PaneStatus.Agent? = nil,
        notice: String? = nil
    ) -> PaneStatus {
        PaneStatus(
            anchorName: anchorName,
            anchorIsRepository: anchorIsRepository,
            isPinned: isPinned,
            workingDirectory: workingDirectory,
            git: git,
            agent: agent,
            notice: notice
        )
    }

    static func git(
        head: String = "main",
        hasUpstream: Bool = true,
        ahead: Int = 0,
        behind: Int = 0,
        dirty: Bool = false,
        untracked: Int = 0,
        conflicted: Int = 0,
        operation: String? = nil,
        isLinkedWorktree: Bool = false
    ) -> PaneStatus.Git {
        PaneStatus.Git(
            head: head,
            hasUpstream: hasUpstream,
            ahead: ahead,
            behind: behind,
            dirty: dirty,
            untracked: untracked,
            conflicted: conflicted,
            operation: operation,
            isLinkedWorktree: isLinkedWorktree
        )
    }

}
