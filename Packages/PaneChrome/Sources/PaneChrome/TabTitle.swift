import Foundation

/// What a tab is called, given the anchor its pane resolved to.
public enum TabTitle {
    /// `~/Projects/baia/.claude/worktrees/agent-3f9c1a2b` abbreviates to
    /// `agent-3f9c1a`, but only when the directory name is `agent-` followed by
    /// six or more lowercase hex digits.
    ///
    /// The Agent tool's `isolation: "worktree"` names its worktrees after a hex
    /// id, where every character past the sixth is noise in a tab. A superpowers
    /// worktree such as `exif-display-0725-1432` is shown verbatim instead,
    /// because its name is the branch and cutting it loses which piece of work the
    /// tab holds. Both layouts are in daily use in this workspace, so the
    /// distinction is not hypothetical.
    public static func title(anchorName: String, isWorktree: Bool) -> String {
        // The name is only abbreviated inside a worktree. A repository the owner
        // deliberately called `agent-deadbeef` keeps its name, since outside the
        // worktree layouts there is no hex id to throw away.
        guard isWorktree, anchorName.hasPrefix(agentPrefix) else { return anchorName }

        let identifier = anchorName.dropFirst(agentPrefix.count)
        guard identifier.count >= abbreviatedLength,
              identifier.allSatisfy(lowercaseHex.contains)
        else { return anchorName }
        return agentPrefix + identifier.prefix(abbreviatedLength)
    }

    /// Disambiguates repeated titles by appending an increasing parent-path
    /// component, so two tabs both called `baia` become `baia (Projects)` and
    /// `baia (sandbox)`.
    ///
    /// Each entry is a slash-separated path whose last component is the title the
    /// tab wants, which is the only shape that carries anything to disambiguate
    /// *with*. An entry with no parents is valid and simply has nothing to grow
    /// into.
    ///
    /// The loop stops on lack of progress rather than on uniqueness. Two panes on
    /// the same path is not an edge case, it is what splitting a pane produces
    /// immediately, and a uniqueness-driven loop would never return for them. A
    /// group whose members share every component is left where it is rather than
    /// grown to the full path, so those two tabs read `baia` and `baia` instead of
    /// `baia (~/Projects)` twice, which is equally ambiguous and three times as
    /// wide.
    public static func disambiguated(_ titles: [String]) -> [String] {
        let components = titles.map { $0.split(separator: "/").map(String.init) }
        var depths = [Int](repeating: 0, count: titles.count)

        while true {
            var rendered: [String: [Int]] = [:]
            for index in titles.indices {
                rendered[render(components[index], depth: depths[index]), default: []].append(index)
            }

            var progressed = false
            for group in rendered.values where group.count > 1 {
                // A group whose members are the same path cannot be split by any
                // depth, and deepening it is what would spin forever.
                guard Set(group.map { components[$0] }).count > 1 else { continue }
                for index in group where depths[index] < parentCount(components[index]) {
                    depths[index] += 1
                    progressed = true
                }
            }
            if !progressed { break }
        }

        return titles.indices.map { render(components[$0], depth: depths[$0]) }
    }

    /// The title with `depth` of its parents appended in brackets.
    private static func render(_ components: [String], depth: Int) -> String {
        guard let title = components.last else { return "" }
        let parents = components.dropLast().suffix(depth)
        guard !parents.isEmpty else { return title }
        return "\(title) (\(parents.joined(separator: "/")))"
    }

    /// How many parents a path has to offer. Bounds every depth, which is what
    /// makes the loop in ``disambiguated(_:)`` terminate.
    private static func parentCount(_ components: [String]) -> Int {
        max(0, components.count - 1)
    }

    /// How much of the grammar a tab has room for.
    ///
    /// Driven off the tab count rather than off a measurement, because AppKit
    /// gives no way to ask how wide a native tab is: the bar divides the titlebar
    /// between however many tabs exist, and the width is known only to it. The
    /// count is the one input that predicts the width, so the drop order is
    /// expressed against the count and lands on the same answer.
    ///
    /// The ladder emptied on 2026-08-12, when the owner ruled the capsule the
    /// one home for repo facts and the branch and markers left the title
    /// grammar entirely (see ``tab(project:branch:isDefaultBranch:markers:attention:isBusy:budget:)``).
    /// With nothing left for width pressure to drop, every budget renders the
    /// same title. The enum and its resolution stay: the call sites still
    /// speak width pressure through it, and the vocabulary is where a future
    /// drop would be expressed rather than re-invented.
    public enum Budget: Sendable, Equatable, CaseIterable {
        /// One or two tabs. Everything fits.
        case everything

        /// Three or four. The markers went first, being the only part that was
        /// still readable from the pane's own capsule.
        case withoutMarkers

        /// Five or six. The branch went too.
        case withoutBranch

        /// Seven or more. The project name, and the state glyph in front of it.
        case projectOnly

        public static func forTabCount(_ count: Int) -> Budget {
            switch count {
            case ...2: .everything
            case 3 ... 4: .withoutMarkers
            case 5 ... 6: .withoutBranch
            default: .projectOnly
            }
        }
    }

    /// What a tab says: `[state] project`.
    ///
    /// The app name is deliberately absent. Every tab used to open with
    /// `baia — `, which cost about a quarter of a 240 pt tab to say the thing
    /// every tab in the bar had in common. The window already knows which
    /// application it belongs to and so does the person reading it.
    ///
    /// The branch and the markers left on 2026-08-12, by owner ruling: the
    /// capsule is the one home for repo facts, and everything else slims
    /// around it. A title reading `baia--design-v6-native:design-v6-native *?8`
    /// was saying the pill's place and changes segments a second time, and the
    /// duplication cost more than the width — two surfaces free to disagree.
    /// The state glyphs stay: `!` and the busy circle are pane attention, not
    /// repo facts, and the title is the one carrier macOS shows for a window
    /// nobody is looking at.
    ///
    /// - Parameters:
    ///   - project: already abbreviated and disambiguated by ``title(anchorName:isWorktree:)``
    ///     and ``disambiguated(_:)``. Never truncated here: it is the identity,
    ///     and a tab nobody can identify is the failure the whole bar exists to
    ///     prevent. AppKit truncates it if it must, which is the right last
    ///     resort because it happens per tab rather than to all of them.
    ///   - branch: unread since the 2026-08-12 ruling; the capsule's place
    ///     segment owns it. The parameter stays so call sites that still hold
    ///     the fact compile unchanged; removing it is cleanup the ruling does
    ///     not require.
    ///   - markers: unread since the same ruling; the capsule's changes
    ///     segment owns them. Kept for the same call-site reason.
    ///   - attention: `!` when asking. An acknowledged pane shows nothing,
    ///     because you have already been there and the tab is not where you were
    ///     told about it.
    public static func tab(
        project: String,
        branch _: String? = nil,
        isDefaultBranch _: Bool = true,
        markers _: String = "",
        attention: PaneStatus.Attention = .none,
        isBusy: Bool = false,
        budget _: Budget = .everything
    ) -> String {
        var title = ""

        // Only the unacknowledged level earns a glyph. A busy pane gets the
        // half-filled circle, which reads as motion without animating anything:
        // a tab bar that animates is a tab bar that pulls the eye off the pane
        // being worked in.
        switch attention {
        case .asking: title += "! "
        case .acknowledged, .none, .done: if isBusy { title += "\u{25D0} " }
        }

        title += project
        return title
    }

    /// A window's full title: what is waiting anywhere, then what this window is.
    ///
    /// The waiting half is the only cross-window carrier baia has.
    /// `NSApp.dockTile.badgeLabel` does nothing in this app, so the title is what
    /// macOS shows for a window nobody is looking at: the Window menu, Mission
    /// Control and the switcher all read it. That is why it goes on *every*
    /// window rather than only the one that is asking, and why the window keeps
    /// its own name after it rather than being replaced by the announcement.
    ///
    /// Names rather than a count, up to two. A count answers "how many", which
    /// nobody asked; a name answers "which", which is the entire reason the
    /// marker exists, since the signal it replaces was one identical sound per
    /// session. Three or more is where naming stops paying for its width.
    ///
    /// `!` rather than a filled circle, because it is the glyph the capsule and
    /// the git markers already use for "act now", and a second symbol for the
    /// same idea is one the reader has to learn separately.
    ///
    /// **Not what the workspace window uses since 2026-08-13.** The owner's
    /// ruling removed the folder name from the titlebar, so `AppDelegate` writes
    /// ``announcement(waitingProjects:)`` alone and there is no `tab` to join.
    /// This stays because the joined grammar is still the correct answer wherever
    /// a window *does* have a name to carry — and because it is the definition
    /// ``announcement(waitingProjects:)`` is kept honest against by
    /// `theAnnouncementAgreesWithTheTitleItReplaces`.
    public static func windowTitle(waitingProjects: [String], tab: String) -> String {
        let announced = announcement(waitingProjects: waitingProjects)
        guard !announced.isEmpty else { return tab }
        return "\(announced)  \u{00B7}  \(tab)"
    }

    /// The waiting half on its own: what a window says when it has no name to
    /// say it *after*.
    ///
    /// **The owner's 2026-08-13 ruling took the folder name out of the titlebar,
    /// and the name was the whole of a quiet window's title.** The band now
    /// carries a folder icon and the path, and the path is the *subtitle*
    /// (``TerminalPaneController/windowTitle``), which leaves the title line with
    /// nothing to hold at rest. So it holds nothing: empty, rather than a
    /// placeholder or the path promoted up a line, which would draw one
    /// directory twice in one 40 pt band.
    ///
    /// **What must not leave with the name is the announcement**, and it is the
    /// reason this is a separate entry point rather than a call to
    /// ``windowTitle(waitingProjects:tab:)`` with an empty `tab`. That spelling
    /// would return `"! vault  ·  "` — the joiner is there to attach the
    /// announcement to a name, and with no name it is a dangling `·` in the
    /// Window menu. `AttentionNotifier` records why the announcement itself is
    /// not negotiable: `NSApp.dockTile.badgeLabel` does nothing in this app, so
    /// the window title is the **primary** carrier for "a pane is asking" and not
    /// a fallback, and it is the only thing macOS shows for a window nobody is
    /// looking at.
    ///
    /// ``windowTitle(waitingProjects:tab:)`` is now composed from this, so the
    /// glyph, the joiner between names, and the two-name threshold are one rule
    /// in one place. Written twice they would be two rules free to disagree,
    /// which is the shape of duplication the 2026-08-12 capsule ruling spent a
    /// commit removing from this very file.
    public static func announcement(waitingProjects: [String]) -> String {
        guard !waitingProjects.isEmpty else { return "" }
        // Names rather than a count, up to two: a count answers "how many",
        // which nobody asked, and a name answers "which", which is the entire
        // reason the marker exists. Three or more is where naming stops paying
        // for its width. Unchanged by the name leaving, because this threshold
        // was never about the window's own name.
        let subject = waitingProjects.count <= 2
            ? waitingProjects.joined(separator: ", ")
            : "\(waitingProjects.count) waiting"
        return "! \(subject)"
    }

    private static let agentPrefix = "agent-"

    /// Six digits of a hex id, which is what `git rev-parse --short` and the
    /// owner's own statusline show, so the tab and the prompt truncate a hash to
    /// the same length.
    private static let abbreviatedLength = 6

    /// Lowercase hex only, as the Agent tool writes it.
    ///
    /// An explicit set rather than `Character.isHexDigit`, which also accepts
    /// `A` through `F` and the fullwidth forms, and would let a repository
    /// deliberately named `agent-ABCDEF12` lose half its name.
    private static let lowercaseHex = Set("0123456789abcdef")
}
