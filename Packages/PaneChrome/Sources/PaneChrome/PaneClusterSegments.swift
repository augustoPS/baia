import Foundation

/// What a capsule segment is, independent of what it says, in the fixed order
/// the capsule wears them: place, changes, agent, attention.
public enum PaneClusterSegmentRole: Sendable, Equatable, CaseIterable {
    case place, changes, agent, attention
}

/// One piece of the capsule's resting state.
public struct PaneClusterSegment: Sendable, Equatable {
    public var role: PaneClusterSegmentRole

    /// Empty for ``PaneClusterSegmentRole/attention``; the dot draws, not
    /// reads.
    public var text: String

    public init(role: PaneClusterSegmentRole, text: String) {
        self.role = role
        self.text = text
    }
}

/// The capsule's resting segments, derived from the same ``PaneStatus`` the
/// footer consumes. Order is fixed and right-anchored: place, changes, agent,
/// attention. A segment with nothing to say is absent, never empty, which is
/// the footer's vanish discipline, moved.
public enum PaneClusterSegments {
    public static func build(from status: PaneStatus) -> [PaneClusterSegment] {
        var segments: [PaneClusterSegment] = []

        // The footer's stale-facts rule, kept: a plain directory emits no git
        // segments even when `git` is non-nil, because the caller can hold
        // facts from before a `cd` out of the repository, and a branch name on
        // a directory that has no branch is a lie the owner would act on.
        if status.anchorIsRepository, let git = status.git {
            if !git.head.isEmpty {
                // Bare `head`, without the footer's `wt:` worktree prefix, on
                // purpose (ruled at Task 2 review, 2026-08-11): the pill stays
                // narrow, and the linked-worktree fact lives one click away in
                // the place card. The dial-in can promote it back to the
                // resting face if the owner misses it there.
                segments.append(PaneClusterSegment(role: .place, text: git.head))
            }

            // One assembly, not a copy of the vocabulary: the string is the
            // footer's own marker text, so the two surfaces cannot disagree
            // about what `↑1*?3` says. Absent when empty, since a clean
            // repository is the common case.
            let markers = PaneStatusSegments.markerText(for: git)
            if !markers.isEmpty {
                segments.append(PaneClusterSegment(role: .changes, text: markers))
            }
        }

        if let agent = status.agent, !agent.label.isEmpty {
            segments.append(PaneClusterSegment(role: .agent, text: agent.label))
        }

        // The footer's own predicate: `PaneStatusBarView.capsuleGlyph(ink:)`
        // draws a mark for every ``PaneStatus/Attention`` level except `.none`
        // (`!` for asking and acknowledged, `✓` for done), and
        // ``PaneStatus/attention`` is the one derivation of the level, so the
        // capsule and the footer cannot disagree about when attention shows.
        if status.attention != .none {
            segments.append(PaneClusterSegment(role: .attention, text: ""))
        }

        return segments
    }
}
