import Foundation

@testable import PaneChrome

/// Builders for the values the bar consumes, with the boring fields defaulted.
///
/// The production initializers deliberately have no defaults: a caller that
/// forgot to pass `dirty` would ship a bar claiming a clean tree, which is the
/// exact failure the indicators exist to prevent. The defaults live here instead,
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

    /// A segment with no meaning of its own, for the layout tests. They are about
    /// priority, alignment and width, so building them out of a real
    /// ``PaneStatus`` would tie every layout assertion to the segment table and
    /// make a priority change fail tests that are not about priorities.
    static func segment(
        role: PaneStatusSegmentRole,
        alignment: PaneStatusAlignment = .leading,
        priority: Int = 50,
        text: String = "x"
    ) -> PaneStatusSegment {
        PaneStatusSegment(
            role: role,
            text: text,
            alignment: alignment,
            priority: priority,
            truncation: .none,
            emphasis: .normal
        )
    }

    /// A status with every optional populated, used by the tests that assert over
    /// every role at once.
    static func everything(notice: String? = nil) -> PaneStatus {
        status(
            isPinned: true,
            workingDirectory: "~/Projects/baia/Packages",
            git: git(
                ahead: 1,
                behind: 2,
                dirty: true,
                untracked: 3,
                operation: "REBASE 1/3"
            ),
            agent: PaneStatus.Agent(label: "claude", wantsAttention: false),
            notice: notice
        )
    }
}
