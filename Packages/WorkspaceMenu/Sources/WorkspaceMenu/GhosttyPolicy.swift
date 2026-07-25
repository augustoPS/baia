import Foundation

/// What baia does about ghostty's own binding for a menu item's key.
///
/// Three states rather than a `Bool`, because "ghostty never bound this" and
/// "ghostty bound this and should keep it" both mean "emit no unbind line" while
/// being wrong in opposite directions. Splitting them is what lets the tests
/// check each direction against the real default table: a `.unbind` for a key
/// ghostty never bound means the transcribed table is stale or the trigger name
/// is misspelled, and a `.noConflict` for a key ghostty does bind is the ⌘Q bug
/// exactly, a key equivalent that does nothing at all with no error.
public enum GhosttyPolicy: Sendable, Equatable {
    /// baia implements this itself and must take the key from ghostty.
    case unbind

    /// Ghostty's own implementation works and is preferred. The reason is
    /// required so a later reader deciding the table looks incomplete does not
    /// "fix" it by unbinding the key and losing a working action.
    case deferToGhostty(reason: String)

    /// Ghostty does not bind this key at all, so no unbind line is needed. Also
    /// the state for an item with no key equivalent.
    case noConflict
}
