import Foundation

/// A changed file's status letter in one fixed column: `M`, `A`, or `D`.
///
/// **Two surfaces draw it, which is the point.** The capsule's changes card, and
/// since the owner's 2026-08-12 ruling (option B) the sidebar's file rows. The
/// sidebar's own CHANGED rows were the third reader until that same day's ruling
/// removed the section. One assembly and two surfaces, the shape
/// ``PaneChrome/PaneStatusSegments/markerText(for:)`` already has between the
/// footer and the capsule: the alternative is deriving letters a second time in
/// the tree and getting a vocabulary that drifts.
///
/// Design v5 §5. A different vocabulary from ``FileChangeMark``, which the file
/// tree also uses: that type collapses every kind to one of four *urgency*
/// bands for a single rollup glyph, and this type keeps git's own single letter
/// for the specific thing that changed. The two are not the same read and the
/// tree now draws both, at two grains — the letter on a file, which says what
/// kind of change this is, and the rollup dot on a directory, which is the one
/// thing a collapsed row can say that its own rows cannot.
public enum RowStatusLetter: Sendable, Equatable, CaseIterable {
    case modified, added, deleted, conflict

    /// The character each letter draws, shared rather than spelled per surface.
    ///
    /// **This lived as a private `glyph(for:)` in `ClusterChangesCardView` until
    /// the file rows needed the same letters (2026-08-12, option B).** A second
    /// copy in the tree would have been the duplication the ruling exists to
    /// remove: the ruling asks the two surfaces to speak one vocabulary, and a
    /// vocabulary spelled twice is two vocabularies that happen to agree today.
    ///
    /// `!` for a conflict rather than a letter, matching ``FileChangeMark/glyph``
    /// exactly: a conflict is the one state both vocabularies already draw the
    /// same way, because it is not a kind of change so much as a thing that has
    /// to be resolved before any change can be recorded.
    public var glyph: Character {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .conflict: "!"
        }
    }

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
