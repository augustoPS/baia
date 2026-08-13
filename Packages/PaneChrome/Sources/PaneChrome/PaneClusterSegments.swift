import Foundation

/// What a capsule segment is, independent of what it says, in the fixed order
/// the capsule wears them: place, changes, agent, attention.
public enum PaneClusterSegmentRole: Sendable, Equatable, CaseIterable {
    case place, changes, agent, attention

    /// A transient sentence answering a click the pane refused, and the only
    /// role that takes the pill alone rather than sharing it. See
    /// ``PaneStatus/notice`` and ``PaneClusterSegments/build(from:)``.
    case notice
}

public extension PaneClusterSegmentRole {
    /// Whether this role opens a card when clicked.
    ///
    /// Every resting role does; ``notice`` does not, and that is the one
    /// asymmetry in the capsule's click contract. The notice *is* the whole
    /// answer — a sentence naming the fix — so there is nothing a card could
    /// add, and a card is a key window (``ClusterCardController``'s panel takes
    /// first responder), which would pull the keyboard off the terminal for a
    /// message that clears itself three seconds later. The refusal came from a
    /// sidebar click; taking the keyboard in response would be a second,
    /// larger surprise than the one being explained.
    ///
    /// Derived here rather than branched at the call site, so the view's hit
    /// resolution and the controller's routing cannot disagree about which
    /// roles are clickable.
    var opensCard: Bool { self != .notice }
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
        // A notice takes the pill alone and returns before anything else is
        // built — ``PaneStatusSegments/build(from:)``'s first clause, moved to
        // the surface that now carries the facts, and moved rather than copied
        // because the footer's argument for it survives the move intact.
        //
        // **The takeover, and why it is still the right shape on a pill.** On
        // the bar the alternative was a segment competing for width with the
        // branch and the markers, which width pressure would drop on exactly
        // the narrow pane where an unexplained refusal confuses most. The pill
        // sizes to its content rather than solving against a fixed bar, so it
        // would not *drop* the notice — it would grow to hold a sixty-six
        // character sentence, roughly 435 pt of monospace, and a pill anchored
        // to the pane's top-right corner that wide either eats the pane's whole
        // top edge or runs off its leading side. Both are worse than the three
        // seconds of takeover the footer settled on, and the takeover is what
        // the owner already read on the bar, so it costs no new vocabulary.
        //
        // The transience is what makes it affordable, and it is the reason this
        // may take the pill when nothing else may: ``PaneStatus/notice`` is
        // written by `TerminalPaneController.showNotice(_:)` and cleared three
        // seconds later, so the resting facts are gone for one glance rather
        // than for a session. Everything else on the capsule is persistent and
        // shares.
        if let notice = status.notice, !notice.isEmpty {
            return [PaneClusterSegment(role: .notice, text: notice)]
        }

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
