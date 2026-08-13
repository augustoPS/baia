import BaiaSettings
import Foundation

/// Everything one pane's status bar shows, already reduced to display values.
///
/// Nothing here is read from disk or from a process. The git counts arrive
/// computed, the operation label arrives formatted, and the working directory
/// arrives abbreviated, which is what keeps this package free of AppKit, of git,
/// and of any test that needs a repository on disk.
public struct PaneStatus: Sendable, Equatable {
    /// A pane's git facts, in the vocabulary of the owner's own statusline
    /// (`claude-dotfiles/statusline/ps1-style.sh`): `↑` ahead, `↓` behind, `*`
    /// dirty, `?` untracked. Reusing that vocabulary rather than inventing one
    /// means the bar reads the same as the prompt he already scans.
    public struct Git: Sendable, Equatable {
        /// The branch name, or whatever the caller decided to show for a
        /// detached HEAD. The statusline shows a parenthesised short SHA there,
        /// and this type takes it verbatim rather than reformatting it.
        public var head: String

        /// False for a detached HEAD and for a branch whose upstream was
        /// deleted. ``PaneStatusSegments`` then drops ``ahead`` and ``behind``,
        /// because with no upstream to count against they are stale numbers
        /// rather than zeroes.
        public var hasUpstream: Bool

        public var ahead: Int
        public var behind: Int
        public var dirty: Bool
        public var untracked: Int

        /// Unmerged paths. Non-zero forces the indicators segment to
        /// ``PaneStatusEmphasis/alert``, since a conflicted tree is the one git
        /// state where running the next command makes things worse.
        public var conflicted: Int

        /// Already-formatted operation label, for example `REBASE 1/3`, or nil.
        /// The caller formats it because only the caller can read
        /// `.git/rebase-merge/msgnum`, and a half-parsed operation shown as
        /// `REBASE` with no position is worse than the label the caller built.
        ///
        /// Read it through ``displayableOperation`` rather than directly, unless
        /// you mean the raw field: a label formatted from an empty git file
        /// arrives as `" "`, which is not nil and not `isEmpty`.
        public var operation: String?

        /// True when the pane sits in a linked worktree rather than the main
        /// checkout. Two incompatible worktree layouts are in daily use here
        /// (`.worktrees/<branch>-MMDD-HHMM` from superpowers and
        /// `.claude/worktrees/agent-<hex>` from the Agent tool), and running a
        /// command in the wrong one of them is a recorded, repeated mistake.
        public var isLinkedWorktree: Bool

        public init(
            head: String,
            hasUpstream: Bool,
            ahead: Int,
            behind: Int,
            dirty: Bool,
            untracked: Int,
            conflicted: Int,
            operation: String?,
            isLinkedWorktree: Bool
        ) {
            self.head = head
            self.hasUpstream = hasUpstream
            self.ahead = ahead
            self.behind = behind
            self.dirty = dirty
            self.untracked = untracked
            self.conflicted = conflicted
            self.operation = operation
            self.isLinkedWorktree = isLinkedWorktree
        }

        /// The operation as a surface may show it, or nil when there is nothing
        /// to show. **The one predicate, for every surface that draws this
        /// fact.**
        ///
        /// Three surfaces read the operation — the footer's segment
        /// (``PaneStatusSegments/build(from:)``), the capsule's pill segment
        /// (``PaneClusterSegments/build(from:)``) and the place card's row
        /// (`ClusterPlaceCardView.Model.operation`, assembled in
        /// `TerminalPaneController.presentPlaceCard`) — and until 2026-08-13 they
        /// shared the *input* while each spelled its own *test*. Two applied
        /// ``PaneStatusSegments/isBlank(_:)``; the card applied `if let` alone,
        /// so `git.operation == "   "` drew no pill segment and grew a card row
        /// captioned `operation` with a blank value beside it. That is exactly
        /// the empty box `isBlank` exists to prevent, reintroduced on the one
        /// surface that had not been given the predicate.
        ///
        /// A shared input is not a shared derivation. This is the derivation, and
        /// nil is the whole answer to "should this be drawn": a caller that
        /// unwraps this cannot construct the blank case, because the blank case
        /// is already nil here.
        public var displayableOperation: String? {
            guard let operation, !PaneStatusSegments.isBlank(operation) else { return nil }
            return operation
        }
    }

    /// How hard a pane is asking, which is not the same question as whether it is
    /// asking.
    ///
    /// The requirement reads as a contradiction: urgent enough to find across
    /// four panes, tolerable to sit beside while it waits, and settled once it
    /// has been seen. It is only contradictory while attention is one state. A
    /// pane that has been looked at and is still waiting is a different thing
    /// from one that just started asking, and the two want opposite volumes.
    ///
    /// A third case rather than a second boolean, so the exhaustive switches that
    /// draw it fail to compile when a state is added rather than falling through
    /// to whatever `else` was nearest.
    public enum Attention: Sendable, Equatable, CaseIterable {
        /// Not asking. Either idle or working.
        case none

        /// Asking, and not yet seen. The loud level.
        case asking

        /// Still asking, but the owner has been here since it started. Quiet
        /// enough to work beside, still visible from across the window.
        case acknowledged

        /// The pane finished and nobody has been in it since. Drawn as a bare
        /// `✓` on the bar, and gone the moment the pane takes focus: a finish
        /// is a notification rather than a request, so being seen is the only
        /// thing that can happen to it. Derived in `PaneActivity` (see
        /// `PaneAttention.done`); this is that level's display name.
        case done

        /// The level an agent value represents, and the only copy of that
        /// derivation anywhere.
        ///
        /// Takes the agent rather than the whole status, because a caller
        /// holding only the agent would otherwise have to write the two lines
        /// out again. The app target did exactly that, and a second copy of this
        /// rule is a copy that can disagree with ``PaneStatus/attention`` about
        /// whether a pane is asking.
        public init(_ agent: Agent?) {
            guard let agent else { self = .none; return }
            if agent.wantsAttention {
                self = agent.isAcknowledged ? .acknowledged : .asking
            } else if agent.hasFinishedUnseen {
                self = .done
            } else {
                self = .none
            }
        }

        /// Whether a pane at this level wears the 2 pt `PaneEdgeFrameView`
        /// stroke around its whole compartment.
        ///
        /// **The one copy of the rule, here for the reason ``init(_:)`` above is
        /// here.** It was spelled in `TerminalPaneController.drawsAttentionFrame`
        /// and nowhere else while the pane was the only thing that drew a frame.
        /// `SettingsPreviewPane` became the second drawer on 2026-08-13, when it
        /// swapped its chrome from the retired footer to the capsule and found
        /// that `attentionStyle` is the one of the four signal keys the capsule
        /// carries nothing of — `PaneClusterView` has no `attentionStyle`
        /// property, and the frame is the key's only expression. Two sites
        /// drawing one frame from two copies of one conjunction is precisely the
        /// arrangement the app target has no test target to catch.
        ///
        /// Not gated on window activation, unlike focus, and
        /// `TerminalPaneController`'s own doc carries why: focus is a statement
        /// about a window that has the keyboard, while an unanswered agent in a
        /// background window is exactly the thing worth finding.
        ///
        /// `acknowledged` does not qualify and that is the level's whole
        /// meaning: the owner has been in the pane since it started asking, so
        /// the cross-window carrier has done its job and comes off. `done` does
        /// not either — a finish is a notification rather than a request.
        public func wearsFrame(under style: AttentionStyle) -> Bool {
            self == .asking && style == .loud
        }

        /// This level, spelled for a reader. Nil for `none`, so a pane that is
        /// not asking prints no `attention` line at all rather than a line
        /// saying nothing happened. No `default:`: a fourth level has to decide
        /// what it is called here before this compiles.
        public static func name(of attention: Attention) -> String? {
            switch attention {
            case .none: nil
            case .asking: "asking"
            case .acknowledged: "acknowledged"
            case .done: "done"
            }
        }
    }

    /// What is running in the pane, and whether it asked for the owner.
    public struct Agent: Sendable, Equatable {
        public var label: String

        /// Set from the pane's bell or OSC 9 notification, not from a guess
        /// about the process tree. The signal it replaces is a single
        /// `afplay Blow.aiff` on the Stop hook, identical for every session, so
        /// with four or five panes open it says something finished and nothing
        /// about which.
        public var wantsAttention: Bool

        /// True once the pane has taken focus, or a key has reached its surface,
        /// since it started asking.
        ///
        /// Never stored as an independent fact: ``PaneStatus/attention`` only
        /// consults it while ``wantsAttention`` is true, so an acknowledgement
        /// cannot outlive the request that earned it. That is the "cleared
        /// whenever wantsAttention goes false" rule, expressed as something that
        /// cannot be forgotten rather than as a line someone has to remember to
        /// write.
        public var isAcknowledged: Bool

        /// True while the agent is working rather than waiting. Drawn as a dot
        /// beside the label, and it is the state most panes are in most of the
        /// time, so it must be the calmest thing in the app.
        public var isBusy: Bool

        /// True when the pane reported it finished and the owner has not been
        /// in it since. The third fact ``PaneStatus/Attention/init(_:)`` reads,
        /// beside the request and its acknowledgement. Never true while
        /// ``wantsAttention`` is: a pane that finished and then asked again is
        /// asking, and `PaneAttention.overridden(byReportedBlock:message:seen:)`
        /// already discards the finish on a raise.
        public var hasFinishedUnseen: Bool

        /// Defaulted so that adding the two newer facts did not have to touch
        /// every call site that only ever knew about a label and a bell.
        public init(
            label: String,
            wantsAttention: Bool,
            isAcknowledged: Bool = false,
            isBusy: Bool = false,
            hasFinishedUnseen: Bool = false
        ) {
            self.label = label
            self.wantsAttention = wantsAttention
            self.isAcknowledged = isAcknowledged
            self.isBusy = isBusy
            self.hasFinishedUnseen = hasFinishedUnseen
        }
    }

    /// The anchor's display name.
    public var anchorName: String

    /// True when the anchor is a git repository. A plain directory emits no git
    /// segments at all, even when ``git`` is non-nil.
    public var anchorIsRepository: Bool

    public var isPinned: Bool

    /// Tilde-abbreviated working directory, shown only when it differs from the
    /// anchor. Build it with ``workingDirectory(ofShellAt:anchoredAt:home:)``
    /// rather than by hand, which is where the "differs from the anchor" half of
    /// that rule lives: this type holds the anchor's *name*, not its path, so it
    /// cannot make the comparison itself.
    public var workingDirectory: String?

    public var git: Git?
    public var agent: Agent?

    /// How hard this pane is asking.
    ///
    /// Derived rather than stored, which is what keeps the acknowledgement from
    /// surviving the request. A pane whose agent stops asking goes straight back
    /// to ``Attention/none`` with no transition to run and nothing to reset.
    public var attention: Attention { Attention(agent) }

    /// A sentence the bar shows instead of everything else, for a few seconds.
    ///
    /// **For an action the pane refused, and nothing else.** A click on a sidebar
    /// row either lands on the prompt or does not, and until this existed the only
    /// answer to "does not" was a beep and a red flash on the row: the owner
    /// learned that something was refused and never why. The reason is the whole
    /// value, so this carries a sentence rather than a state.
    ///
    /// **It replaces the bar rather than joining it**, which is the one design
    /// decision here worth defending. The alternative is a segment competing for
    /// width with the branch and the markers, and under width pressure
    /// ``PaneStatusLayout`` would drop either the notice, which makes the feature
    /// pointless on a narrow pane, or the git markers, which are the thing the
    /// bar exists for. A notice is rare, brief, and caused by something the owner
    /// did a moment ago, so taking the bar for three seconds costs less than
    /// either.
    ///
    /// **It does not touch attention.** The wash, the frame and the tab glyph are
    /// drawn from ``attention``, which this leaves alone, so a pane that is asking
    /// keeps saying so in colour while the notice occupies the text. That is why
    /// the two can share a bar without a rule about which wins.
    public var notice: String?

    public init(
        anchorName: String,
        anchorIsRepository: Bool,
        isPinned: Bool,
        workingDirectory: String?,
        git: Git?,
        agent: Agent?,
        notice: String? = nil
    ) {
        self.anchorName = anchorName
        self.anchorIsRepository = anchorIsRepository
        self.isPinned = isPinned
        self.workingDirectory = workingDirectory
        self.git = git
        self.agent = agent
        self.notice = notice
    }

    /// The value for ``workingDirectory``: nil when the shell sits at the
    /// anchor, otherwise the shell's directory with `home` abbreviated to `~`.
    ///
    /// Nil rather than the anchor's own path, because a pane whose shell has not
    /// left the project root would otherwise spend the widest trailing segment
    /// restating what the leading segment already says.
    ///
    /// - Parameter home: passed in rather than read from
    ///   `FileManager.default.homeDirectoryForCurrentUser`, so the abbreviation
    ///   is a pure function of its arguments and the tests do not depend on
    ///   whose machine they run on.
    public static func workingDirectory(
        ofShellAt directory: String,
        anchoredAt anchor: String,
        home: String
    ) -> String? {
        let shell = trimmingTrailingSlashes(directory)
        guard shell != trimmingTrailingSlashes(anchor) else { return nil }
        guard !shell.isEmpty else { return nil }
        return abbreviated(shell, home: home)
    }

    /// `path` with `home` shortened to `~`, and otherwise untouched beyond
    /// trailing-slash trimming.
    ///
    /// The tilde half of ``workingDirectory(ofShellAt:anchoredAt:home:)``,
    /// split out for the place card, which abbreviates a directory with no
    /// anchor to compare against. One copy on purpose: the first hand copy of
    /// this in the app target forgot that a directory URL's `path` carries a
    /// trailing slash, so its `home + "/"` prefix never matched and the
    /// abbreviation silently never fired, exactly the class of bug this
    /// package's tests exist to make impossible.
    ///
    /// Both operands are trimmed of trailing slashes first, so `/Users/gu/`
    /// as a home still abbreviates `/Users/gu/p`. The prefix has to end at a
    /// path boundary: `/Users/gu` against `/Users/gutao/p` matches as a plain
    /// string prefix and would abbreviate to `~tao/p`, a path that does not
    /// exist and cannot be pasted anywhere.
    public static func abbreviated(_ path: String, home: String) -> String {
        let trimmed = trimmingTrailingSlashes(path)
        let root = trimmingTrailingSlashes(home)
        guard !root.isEmpty else { return trimmed }
        if trimmed == root { return "~" }
        guard trimmed.hasPrefix(root + "/") else { return trimmed }
        return "~" + trimmed.dropFirst(root.count)
    }

    /// Drops trailing slashes so `/a/b` and `/a/b/` compare equal. Leaves a
    /// lone `/` alone, since a shell really can sit at the root.
    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
