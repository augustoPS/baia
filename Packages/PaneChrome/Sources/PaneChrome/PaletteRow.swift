import Foundation
import GitWorkspace

/// What kind of thing a palette row is offering to open.
///
/// A local mirror of `GitWorkspace.Project.Kind` rather than the type itself,
/// so a row can be built and tested (``PaletteRow/make(relativePath:matchedIndices:kind:)``)
/// without a `Project` in hand. ``PaletteRow/kind(of:)`` is the one place that
/// maps between them, and the mapping is a `switch` the compiler checks.
public enum PaletteRowKind: Sendable, Equatable, CaseIterable {
    case repository
    case worktree
    case directory
}

/// One row of the project palette, reduced to coloured runs.
///
/// Pure and AppKit-free, for the same reason ``PaneGitRuns`` is: what a row says
/// and how it is tiered is decidable without a window, and the whole suite runs
/// in milliseconds because of it.
///
/// The row reuses ``PaneStatusRun`` and the pane chrome's own emphasis tiers
/// rather than inventing a palette vocabulary. That is deliberate. The palette
/// and the pane are the same person's two views of the same workspace, and a
/// project that reads `website/` + `shop` in one should read the same way in the
/// other.
public struct PaletteRow: Sendable, Equatable {
    /// Everything up to and including the last slash, for example `website/`.
    /// Empty for a project sitting directly under a root.
    public var parent: [PaneStatusRun]

    /// The last path component, which is the project's name.
    public var name: [PaneStatusRun]

    /// `WT` for a linked worktree, `DIR` for a plain directory, nil for an
    /// ordinary repository.
    ///
    /// Nil rather than `"REPO"` because a repository is the overwhelming common
    /// case, and a chip on every row would be a column of noise saying what the
    /// absence of a chip already says. Segments vanish rather than render empty,
    /// which is the rule the footer follows too.
    public var chip: String?

    public init(parent: [PaneStatusRun], name: [PaneStatusRun], chip: String?) {
        self.parent = parent
        self.name = name
        self.chip = chip
    }

    /// Builds a row from the string the ranker matched and the placement it
    /// found.
    ///
    /// - Parameters:
    ///   - relativePath: the candidate `ProjectRanker` scored, for example
    ///     `website/shop`. It is the matched string rather than the display name
    ///     on purpose: `website/shop` and `website/admin` share no display name
    ///     worth typing, and the path is what the owner already types in a shell.
    ///   - matchedIndices: character offsets into `relativePath`, as
    ///     `FuzzyMatch` reports them. Offsets rather than `String.Index` values,
    ///     which is what lets them survive being mapped onto runs here.
    ///   - kind: decides the chip.
    public static func make(
        relativePath: String,
        matchedIndices: [Int] = [],
        kind: PaletteRowKind = .repository
    ) -> PaletteRow {
        let characters = Array(relativePath)
        let hits = Set(matchedIndices)

        // Everything at or after the last slash is the name. The same rule
        // `FuzzyMatcher` uses to award its last-component bonus, so the part
        // scored highest is the part drawn loudest.
        let split = (characters.lastIndex(of: "/").map { $0 + 1 }) ?? 0

        return PaletteRow(
            parent: runs(characters[0 ..< split], hits: hits, base: .context),
            name: runs(characters[split ..< characters.count], hits: hits, base: .normal),
            chip: chip(for: kind)
        )
    }

    /// Builds a row for a verb, which has a title and a shortcut where a project
    /// has a name and a parent.
    ///
    /// The shortcut goes in ``parent`` rather than into a new field, and that is
    /// a claim about the layout rather than a saving: `parent` is the quiet run
    /// drawn ahead of the loud one, which is exactly what a shortcut is next to
    /// the verb it belongs to. A third field would draw in the same place and
    /// need its own tier.
    ///
    /// The chip is always `CMD`. A project row leaves it nil for the common case
    /// so the column is not noise, and here the common case is the opposite: in
    /// verb mode every row is a verb, but the two modes share a list view, and a
    /// row that carried no chip would be indistinguishable from a project row in
    /// a screenshot or a capture.
    ///
    /// - Parameters:
    ///   - title: what the menu calls it, which is what was matched.
    ///   - shortcut: as drawn, `⌃⌘=`, or empty when the verb has none.
    ///   - matchedIndices: offsets into `title`, as `FuzzyMatch` reports them.
    public static func verb(
        title: String,
        shortcut: String = "",
        matchedIndices: [Int] = [],
        unavailableReason: String? = nil
    ) -> PaletteRow {
        let characters = Array(title)

        // An unavailable verb draws its whole title in the quiet tier, including
        // the characters that matched. The match highlight is an invitation, and
        // accenting a row that Return refuses would be the loudest thing on
        // screen pointing at the one row that does nothing.
        let base: PaneStatusEmphasis = unavailableReason == nil ? .normal : .context
        let hits = unavailableReason == nil ? Set(matchedIndices) : []

        var leading: [PaneStatusRun] = []
        if !shortcut.isEmpty {
            leading.append(PaneStatusRun(text: shortcut + "  ", emphasis: .context))
        }

        var trailing = runs(characters[0 ..< characters.count], hits: hits, base: base)
        if let unavailableReason {
            // After the title rather than before it, so the eye reaches the verb
            // first and the requirement second. A reason drawn ahead of the name
            // would make every unavailable row start with the same few words.
            trailing.append(
                PaneStatusRun(text: "  " + unavailableReason, emphasis: .context)
            )
        }

        return PaletteRow(parent: leading, name: trailing, chip: "CMD")
    }

    /// Groups a stretch of characters into the fewest runs that still say which
    /// ones matched.
    ///
    /// One run per character would render identically and cost a measurement and
    /// an attribute range each, on every row, on every keystroke. Grouping is
    /// what keeps a query that matches eight scattered characters from turning a
    /// row into sixteen runs.
    private static func runs(
        _ slice: ArraySlice<Character>,
        hits: Set<Int>,
        base: PaneStatusEmphasis
    ) -> [PaneStatusRun] {
        var runs: [PaneStatusRun] = []
        for index in slice.indices {
            // A matched character takes `.strong`, which is the accent. The rest
            // of the run keeps the tier the stretch belongs to, so the name still
            // outranks the parent whether or not either was matched.
            let emphasis: PaneStatusEmphasis = hits.contains(index) ? .strong : base
            if var last = runs.last, last.emphasis == emphasis {
                last.text.append(slice[index])
                runs[runs.count - 1] = last
            } else {
                runs.append(PaneStatusRun(text: String(slice[index]), emphasis: emphasis))
            }
        }
        return runs
    }

    /// `GitWorkspace`'s vocabulary onto this package's own.
    ///
    /// No `default:` arm, so a fourth `Project.Kind` case fails this to compile
    /// rather than falling through to whichever arm `default:` would have
    /// picked. `--kinds` broke exactly this way once, in a mapping this shape.
    public static func kind(of kind: Project.Kind) -> PaletteRowKind {
        switch kind {
        case .repository: .repository
        case .worktree: .worktree
        case .directory: .directory
        }
    }

    private static func chip(for kind: PaletteRowKind) -> String? {
        switch kind {
        case .repository: nil
        case .worktree: "WT"
        case .directory: "DIR"
        }
    }

    /// The whole row as one string, which is what the ranker matched and what a
    /// test can assert against without reassembling runs by hand.
    public var text: String {
        (parent + name).map(\.text).joined()
    }
}
