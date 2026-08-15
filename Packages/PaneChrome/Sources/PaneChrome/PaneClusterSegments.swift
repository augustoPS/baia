import Foundation

/// What a capsule segment is, independent of what it says, in the fixed order
/// the capsule wears them: operation, place, changes, agent, attention.
public enum PaneClusterSegmentRole: Sendable, Equatable, CaseIterable {
    case operation, place, changes, agent, attention

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

    /// What the segment says. For ``PaneClusterSegmentRole/attention`` this is
    /// the level's glyph (see
    /// ``PaneClusterSegments/attentionGlyph(for:)``); it was empty, and the
    /// attention mark a colourless dot, until 2026-08-15.
    public var text: String

    /// Whether an asking pane has been looked at since it started asking, which
    /// is the one thing the glyph cannot say: `asking` and `acknowledged` are
    /// the same request and wear the same `!`, separated by whether the capsule
    /// under it is filled or stroked.
    ///
    /// A field on the segment rather than a second input on the view, so the
    /// capsule has exactly one source of truth about attention and no two
    /// channels that could disagree. False for every other role and for a level
    /// that is not `acknowledged`.
    public var isAcknowledged: Bool

    /// Whether this is a pane that finished rather than one that is asking.
    ///
    /// Separate from ``isAcknowledged`` because the two say different things and
    /// the drawing differs in kind rather than in degree: an asking pane wears a
    /// capsule in the attention colour, filled or stroked by whether it has been
    /// seen, and a finished pane wears no capsule at all and takes the pill's own
    /// ink. A finish is a notification, not a request, so it does not wear the
    /// colour that means "answer me".
    public var isFinished: Bool

    public init(
        role: PaneClusterSegmentRole,
        text: String,
        isAcknowledged: Bool = false,
        isFinished: Bool = false
    ) {
        self.role = role
        self.text = text
        self.isAcknowledged = isAcknowledged
        self.isFinished = isFinished
    }
}

/// The capsule's resting segments, derived from a ``PaneStatus``. Order is fixed
/// and right-anchored: operation, place, changes, agent, attention. A segment
/// with nothing to say is absent, never empty, which is the footer's vanish
/// discipline, inherited from the surface this replaced.
public enum PaneClusterSegments {
    public static func build(from status: PaneStatus) -> [PaneClusterSegment] {
        // A notice takes the pill alone and returns before anything else is
        // built — the footer's own first clause, moved to the surface that now
        // carries the facts, and moved rather than copied because the footer's
        // argument for it survives the move intact. The footer itself was
        // deleted on 2026-08-13, so this is the only place the clause lives.
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
            // The operation leads, which is the footer's own order
            // (its git group led with the operation "because a half-finished
            // rebase changes what every other fact on the bar means") and it
            // survives the move for a reason the pill
            // makes sharper than the bar did. Mid-rebase, git detaches HEAD, so
            // ``GitWorkspace/RepositoryStatus/displayHead`` answers `(a1b2c3d)`
            // and the place segment stops naming a branch at all. The operation
            // is what turns that bare hash from a mystery into a step of
            // something. Behind it, the hash is the only thing on the pill and
            // nothing explains it.
            //
            // **Persistent, so it shares the pill rather than taking it.** The
            // notice above may take the pill alone precisely because it clears
            // itself in three seconds; this one appears when a rebase halts on a
            // conflict and stays until the operation is finished or aborted, and
            // `BISECT_LOG` outlives the whole session until `git bisect reset`
            // (``GitWorkspace/InProgressProbe/detect(gitDirectory:)`` records
            // that measurement). A takeover here would hide the branch, the
            // markers and the agent for hours, which is the resting capsule
            // switched off rather than a fact given a home.
            //
            // **The full label, not a mark.** The `wt:` prefix went the other
            // way one task ago — dropped to the place card to keep the pill
            // narrow — and the two facts look alike enough that the same answer
            // is tempting. They differ where it counts: `wt:` qualifies a fact
            // that is already fully drawn beside it, so abbreviating it costs
            // the reader a nuance, while the operation has no other
            // representation on the pill at all, so abbreviating it to a mark
            // costs the reader the fact.
            //
            // **The width is budgeted rather than assumed affordable, and the
            // first version of this comment got that wrong twice.** It argued
            // the label is free because "the pill has never budgeted a resting
            // segment", on two claims that do not survive measurement:
            //
            // - *That an operation only joins a pill already too wide.*
            //   Measured in the shipped font: `(a1b2c3d) *` is a 92.0 pt pill,
            //   and `CHERRY-PICK (a1b2c3d) *` is 174.8 pt. So the operation
            //   moves the pane width the pill needs from 98 pt to 181 pt, into a
            //   band where the pill was displaying correctly a moment earlier.
            //   The pane that breaks is not one that was already broken.
            // - *That `WorkspaceLayout/PaneTree` floors a pane at 70 pt.* It
            //   does not. The 0.05 clamp is per split and yields 70 pt only on a
            //   1400 pt window; `PaneTree.swift:663-665` records that five
            //   nested splits at 0.05 still reach three points. There is no
            //   floor to lean on.
            //
            // And the asymmetry that settles it: ``PaneClusterLayout``'s
            // `noticeTextBudget` exists, with a long doc, to stop a *three
            // second* sentence growing leftward off the pane "because it is
            // pinned by its top-right corner and nothing else". This fact has
            // identical geometry and lasts until the operation ends — for
            // `git bisect`, until `bisect reset`, which can be the whole
            // session. So the pill is fitted to its pane by
            // ``PaneClusterLayout/fitting(segments:widths:budget:)`` and the
            // operation takes its place in ``PaneClusterLayout/dropOrder``,
            // where the reasoning for its rank lives. It is still the label,
            // whole, on every pane wide enough for it.
            //
            // ``PaneStatus/Git/displayableOperation``, the one predicate every
            // surface that draws this fact asks: a label formatted from an empty
            // git file arrives as `" "`, which is not nothing to `isEmpty` and
            // draws as an empty box either way. Asked rather than re-spelled
            // because the place card spelled its own and got a blank row
            // (2026-08-13); the predicate's own doc carries that history.
            if let operation = git.displayableOperation {
                segments.append(PaneClusterSegment(role: .operation, text: operation))
            }

            if !git.head.isEmpty {
                // Bare `head`, without the footer's `wt:` worktree prefix, on
                // purpose (ruled at Task 2 review, 2026-08-11): the pill stays
                // narrow, and the linked-worktree fact lives one click away in
                // the place card. The dial-in can promote it back to the
                // resting face if the owner misses it there.
                segments.append(PaneClusterSegment(role: .place, text: git.head))
            }

            // One assembly, not a copy of the vocabulary: the string is the
            // marker text the footer used, kept in `PaneGitRuns` when that view
            // was deleted on 2026-08-13, so no surface reading it can disagree
            // about what `↑1*?3` says. The tab title is the other reader. Absent when empty, since a clean
            // repository is the common case.
            let markers = PaneGitRuns.markerText(for: git)
            if !markers.isEmpty {
                segments.append(PaneClusterSegment(role: .changes, text: markers))
            }
        }

        if let agent = status.agent, !agent.label.isEmpty {
            segments.append(PaneClusterSegment(role: .agent, text: agent.label))
        }

        // The footer's own predicate, inherited: a mark is drawn for every
        // ``PaneStatus/Attention`` level except `.none`, and
        // ``PaneStatus/attention`` is the one derivation of the level, so every
        // surface reading it agrees about when attention shows. The predicate
        // outlived the footer because it was never about that view: it is the
        // rule that `.none` is the only level with nothing to draw.
        //
        // **The glyph rides in `text`, and that is the seam rather than a
        // convenience** (2026-08-15). It carried `""` from the footer's deletion
        // until then, because `PaneStatusBarView.capsuleGlyph(ink:)` drew the
        // `!`/`✓` pair and went with that view, leaving the capsule drawing one
        // colourless dot for three levels it was handed and never read. Putting
        // the glyph here means the level crosses to the view through the field
        // every other segment already uses, so the width falls out of measuring
        // the text the way `place` and `agent` do, and no second channel has to
        // agree with this one. See
        // `vault/projects/baia/specs/2026-08-15-what-the-capsule-says-about-attention.md`.
        if let glyph = PaneClusterSegments.attentionGlyph(for: status.attention) {
            segments.append(PaneClusterSegment(
                role: .attention,
                text: glyph,
                isAcknowledged: status.attention == .acknowledged,
                isFinished: status.attention == .done
            ))
        }

        return segments
    }

    /// The mark a level wears, or nil for the level that wears none.
    ///
    /// The pair is `PaneStatusBarView.capsuleGlyph(ink:)`'s, restored rather
    /// than redesigned: `!` for a pane that is asking, whether or not the owner
    /// has been in it since, and `✓` for one that finished unseen. What
    /// separates `asking` from `acknowledged` is the capsule under the glyph
    /// (filled against stroked), not the glyph itself, because both levels are
    /// the same request and the difference between them is whether it has been
    /// looked at.
    ///
    /// One function rather than a `switch` at the call site, so the predicate
    /// "which levels draw a mark" has one home. `.none` returning nil is that
    /// predicate: it is the only level with nothing to say.
    static func attentionGlyph(for attention: PaneStatus.Attention) -> String? {
        switch attention {
        case .none: nil
        case .asking, .acknowledged: "!"
        case .done: "\u{2713}"
        }
    }
}
