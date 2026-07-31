import Foundation

/// Which directories the file tree was left showing, per anchor.
///
/// The sidebar is one surface pointed at whichever pane has focus, so moving
/// focus to a pane in another repository replaces the tree under it. Before this
/// existed the replacement cleared the open set, and four levels opened in one
/// repository were gone on the way back from a glance at another. The owner read
/// that as loss, which it was: nothing about the second repository says anything
/// about what was open in the first.
///
/// **Keyed by anchor, not shared across them.** One set pruned against each
/// incoming tree is less state and the wrong state: `src/` open in one repository
/// would open `src/` in the next, and the tree would keep answering a question
/// that was asked somewhere else.
///
/// Nothing is ever evicted. An entry is a repository path and a set of
/// directories under it, the map only grows by anchors visited in one run, and
/// this is held by a surface that dies with its window. An eviction rule here
/// would be code defending against a number that cannot get large.
public struct FileTreeExpansions: Equatable, Sendable {
    /// The anchor the live set belongs to, and nil before the surface has been
    /// pointed anywhere.
    public private(set) var anchor: String?

    private var byAnchor: [String: Set<String>] = [:]

    public init() {}

    /// Points the memory at `anchor` and answers with what that anchor was left
    /// showing, having first put `open` away under the anchor it was pointed at.
    ///
    /// The caller holds the live set, so it has to be handed back in on every
    /// move: this type never sees a click. That is what keeps it a value type
    /// with no view in it, and what lets the whole rule be read in one function.
    ///
    /// **The same anchor answers `open` unchanged**, which is the case that
    /// happens most. The sidebar is repointed on every focus change and every git
    /// poll that reports something new, and the great majority of those land on
    /// the anchor already showing. Answering anything but the identical set there
    /// would make a redraw out of a poll.
    ///
    /// A nil anchor is a pane with nothing to list. The set that was open is still
    /// put away, so a pane that loses its anchor and gets it back is not a loss
    /// either.
    public mutating func retarget(to anchor: String?, keeping open: Set<String>) -> Set<String> {
        guard anchor != self.anchor else { return open }
        if let previous = self.anchor { byAnchor[previous] = open }
        self.anchor = anchor
        guard let anchor else { return [] }
        return byAnchor[anchor] ?? []
    }
}
