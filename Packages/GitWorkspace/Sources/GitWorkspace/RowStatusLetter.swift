import Foundation

/// The sidebar CHANGED row's fixed status-letter column: `M`, `A`, or `D`.
///
/// Design v5 §5. A different vocabulary from ``FileChangeMark``, which the file
/// tree already uses: that type collapses every kind to one of four *urgency*
/// bands for a single rollup glyph, and this type keeps git's own single letter
/// for the specific thing that changed, beside the row's own two-column `XY`
/// marker. The two are not the same read: the tree asks "how much should I care
/// about this subtree", the row asks "what kind of change is this".
public enum RowStatusLetter: Sendable, Equatable, CaseIterable {
    case modified, added, deleted, conflict

    /// The worktree column outranks the index column for a file that is both,
    /// the same precedence ``FileChangeMark`` already uses and for the same
    /// reason: `MM` means committing now leaves the second `M` behind, so the
    /// letter has to name the half still owed rather than the half already
    /// staged.
    public init(_ change: RepositoryFileChange) {
        switch change.kind {
        case .unmerged:
            self = .conflict
        case .untracked:
            self = .added
        case .ordinary, .renamedOrCopied:
            self = Self.letter(for: change.worktree ?? change.index)
        }
    }

    /// Maps one `XY` column state to this row's three-letter vocabulary. `R`/`C`
    /// (rename or copy) and `T` (type change) have no letter of their own here
    /// and fall back to modified: the row already draws the real `XY` letters in
    /// its two-column marker, so this fixed column only has to say which of the
    /// three broad things happened, not spell every git state a second time.
    private static func letter(for state: RepositoryFileChange.State?) -> RowStatusLetter {
        switch state {
        case .added: .added
        case .deleted: .deleted
        case .modified, .renamed, .copied, .typeChanged, .unmerged, nil: .modified
        }
    }
}
