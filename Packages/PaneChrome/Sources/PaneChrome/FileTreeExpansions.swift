import Foundation
import GitWorkspace

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
/// Nothing is evicted here. An entry is a repository path and a set of
/// directories under it, and the map only grows by anchors visited in one run.
/// The one thing that could make it grow without bound is the session file,
/// which carries it across relaunches, and that is pruned where it is read:
/// `SessionStore.reconciled` drops every anchor no surviving pane resolves to.
/// An eviction rule here as well would be a second answer to a question already
/// answered at the boundary that raised it.
/// **The live set is byte-exact and the file is not.** A directory is held as a
/// ``RepositoryPath``, so two siblings differing only outside UTF-8 open and
/// close separately while the app runs. ``recording(_:)`` still writes the drawn
/// spelling, because a JSON string is Unicode and cannot carry a byte that is not:
/// the cost is that such a directory's state is not restored across a relaunch,
/// and the encoding that would fix it is a decision deferred on purpose rather
/// than an oversight. Nothing collapses in a running session, which is where the
/// owner sees it.
public struct FileTreeExpansions: Equatable, Sendable {
    /// The anchor the live set belongs to, and nil before the surface has been
    /// pointed anywhere.
    ///
    /// A `String` rather than a ``RepositoryPath``: this is a repository root the
    /// owner opened, not a path git reported, and it keys the session file.
    public private(set) var anchor: String?

    private var byAnchor: [String: Set<RepositoryPath>] = [:]

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
    public mutating func retarget(
        to anchor: String?,
        keeping open: Set<RepositoryPath>
    ) -> Set<RepositoryPath> {
        guard anchor != self.anchor else { return open }
        if let previous = self.anchor { byAnchor[previous] = open }
        self.anchor = anchor
        guard let anchor else { return [] }
        return byAnchor[anchor] ?? []
    }

    /// Every anchor's set, with `open` put away under the live anchor first.
    ///
    /// The live set is the caller's, exactly as in ``retarget(to:keeping:)``, and
    /// it is the one this type has never been handed: `retarget` stores the set it
    /// is moving *away* from. Recording without taking `open` would write the
    /// session file with every anchor the run visited except the one on screen,
    /// which is the one the owner just arranged.
    ///
    /// Sorted arrays rather than sets, because `Set` has no stable encoding and
    /// this is written to a file that is compared in tests and read by a human
    /// when a restore goes wrong.
    ///
    /// **The drawn spelling, which is the one lossy step left in this type.** A
    /// JSON string is a sequence of Unicode scalars and a path is a byte string,
    /// so a directory whose name is not UTF-8 cannot be written here as it is. It
    /// is written as it draws and read back as those bytes, which is a different
    /// name, so its expansion is silently not restored. Two such siblings also
    /// merge into one entry on the way out. Both are the deferred half of the byte
    /// pass, and neither can be reached while the app is running: the live set
    /// above is byte-exact.
    ///
    /// Sorted on the drawn spelling for the same reason it is written that way, so
    /// the file's order is the order a reader sees.
    public func recording(_ open: Set<RepositoryPath>) -> [String: [String]] {
        var stored = byAnchor
        if let anchor { stored[anchor] = open }
        return stored.mapValues { paths in paths.map(\.display).sorted() }
    }

    /// Fills the memory from a restored session, and answers what the caller
    /// should now be showing.
    ///
    /// **The return value is what makes this reach the screen.** Seeding can
    /// arrive after the surface has already been pointed somewhere: the sidebar is
    /// refreshed when its window opens, and the session's expansions are applied
    /// once every window exists. A seed that only filled the map would leave that
    /// first anchor displaying the empty set it was given a moment earlier, and
    /// the restored field would be written, read back, and change nothing.
    ///
    /// An anchor this run has already put away wins over the file. The set on
    /// disk describes the previous run, and by the time it is applied the owner
    /// may have opened directories in this one.
    /// The restored names are text, and a directory whose name is not UTF-8 was
    /// not written as itself, so it does not come back as itself. Seeding takes
    /// them at face value: a name that round-trips restores, and one that does not
    /// simply never matches a node and opens nothing. It cannot open the *wrong*
    /// directory, because the tree keys on bytes and no real node carries U+FFFD
    /// unless its name truly holds one.
    public mutating func seed(
        _ stored: [String: [String]],
        showing open: Set<RepositoryPath>
    ) -> Set<RepositoryPath> {
        for (anchor, directories) in stored where byAnchor[anchor] == nil {
            byAnchor[anchor] = Set(directories.map { RepositoryPath($0) })
        }
        guard let anchor else { return open }
        return byAnchor[anchor] ?? open
    }
}
