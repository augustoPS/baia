import Darwin
import Foundation

/// Reads and writes the session file, and repairs what it read.
///
/// Nothing here throws. A missing file, an unreadable one, a file this build's
/// schema does not know, and a file some editor left half written all mean one
/// thing to the caller: there is no session to restore, open a fresh workspace.
///
/// The two `try?` expressions below are the only ones in the package.
/// `JSONEncoder` and `JSONDecoder` have no non-throwing entry point, and the
/// alternative is a hand-written `init(from:)` and `encode(to:)` on every type
/// here, each of them a `throws` function.
public struct SessionStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// ~/Library/Application Support/baia/session.json
    ///
    /// `urls(for:in:)` rather than `url(for:in:appropriateFor:create:)`, which
    /// throws and creates the directory as a side effect of being asked where it
    /// is. Creating it belongs to `save`, the only writer, so a launch that only
    /// reads never leaves an empty directory behind.
    public static func defaultFileURL() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
                .appending(path: "Library/Application Support")
        return support.appending(path: "baia/session.json")
    }

    /// The stored session, or nil when there is nothing usable to restore.
    public func load() -> SessionSnapshot? {
        // `contents(atPath:)` rather than `Data(contentsOf:)`: it answers nil for a
        // missing or unreadable file instead of throwing, and a first launch has no
        // session file at all, which is not an error worth a type.
        guard let data = FileManager.default.contents(atPath: fileURL.path(percentEncoded: false))
        else { return nil }
        guard let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data)
        else { return nil }

        // A version this build does not know is refused whole. A file from a newer
        // baia may hold a tree shape or a ratio convention this one would decode
        // into a plausible but wrong workspace, and a wrong workspace is worse than
        // a fresh one: it would be saved back over the good file on quit.
        guard snapshot.schemaVersion == SessionSnapshot.currentSchemaVersion else { return nil }
        return snapshot
    }

    /// Writes the session, and reports whether it landed.
    ///
    /// Written to a sibling temporary file and renamed over the target. A crash
    /// between the first and last write of an in-place save leaves a truncated file,
    /// which decodes to nil and loses the session; a crash anywhere in this one
    /// leaves the previous file exactly as it was.
    ///
    /// `rename(2)` rather than `FileManager.replaceItemAt`, which throws and stages
    /// its own temporary directory. The temporary file is a sibling precisely so the
    /// rename stays inside one filesystem, which is where it is atomic.
    ///
    /// This survives a process crash, not a power cut: without an `fsync` the rename
    /// can reach disk before the bytes do. Buying that means a hand-rolled
    /// `open`/`write` loop, for a file whose whole value is saving the user a
    /// re-split.
    public func save(_ snapshot: SessionSnapshot) -> Bool {
        let path = fileURL.path(percentEncoded: false)
        let directory = fileURL.deletingLastPathComponent().path(percentEncoded: false)
        guard Self.createDirectory(atPath: directory) else { return false }
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }

        // A fixed `.tmp` name, not a unique one. One app process owns this file, so
        // there is no second writer to collide with, and a temporary left behind by
        // an earlier crash is overwritten here rather than accumulating.
        //
        // 0o600 because the session names every directory the user works in, and
        // Application Support is world readable by default.
        let temporaryPath = path + ".tmp"
        guard FileManager.default.createFile(
            atPath: temporaryPath,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { return false }

        guard rename(temporaryPath, path) == 0 else {
            // The temporary is removed on failure so a stale one cannot be mistaken
            // for a session later, and so a full disk does not keep two copies.
            unlink(temporaryPath)
            return false
        }
        return true
    }

    /// Drops panes whose working directory no longer exists and repairs focus, so a
    /// stale session degrades into a smaller workspace instead of a window nobody
    /// can use. Returns what it changed.
    ///
    /// - Parameter directoryExists: asked once per recorded directory. A closure
    ///   rather than a `FileManager` call inside, because a pane's directory can be
    ///   on a network mount or an unmounted volume where the caller wants its own
    ///   answer, and a caller restoring another machine's session has to be able to
    ///   say no to everything.
    ///
    /// - Parameter resolveAnchor: the path a surviving pane's file tree keys its
    ///   open directories under, asked once per pane that came back. A closure for
    ///   a second reason on top of the first: resolving an anchor walks up looking
    ///   for a repository root, which is `AnchorResolver`'s job in `ProjectAnchor`,
    ///   and this package depends on nothing. Answering with the pane's working
    ///   directory is the identity version and is what a test wants; the app hands
    ///   in the resolver it already uses to point the sidebar, so the key pruned
    ///   against here is the key the surface writes.
    ///
    /// The returned snapshot is always launchable, including when every pane is gone:
    /// an empty workspace, not nil. The caller then opens a pane at its default
    /// directory, which is what it already does on a first launch.
    public static func reconciled(
        _ snapshot: SessionSnapshot,
        directoryExists: (String) -> Bool,
        resolveAnchor: (PaneState) -> String?
    ) -> (snapshot: SessionSnapshot, droppedPanes: [PaneID]) {
        // The ids a tab actually shows. A `PaneState` for a pane no tree holds is a
        // leftover from an earlier save, and reporting it as dropped would name a
        // pane the caller was never going to create.
        let shown = Set(snapshot.workspace.tabs.flatMap { $0.tree.paneIDs })

        var dropped: [PaneID] = []
        var panes: [PaneState] = []
        for pane in snapshot.panes {
            if let directory = pane.workingDirectory, !directoryExists(directory) {
                if shown.contains(pane.id) { dropped.append(pane.id) }
                continue
            }
            var repaired = pane
            // A pin whose directory vanished clears instead of taking the pane with
            // it. The pin is a preference about a pane, not the pane's reason to
            // exist, and `AnchorResolver` already treats a stale pin as data to
            // repair rather than a failure.
            if let pinned = pane.pinnedDirectory, !directoryExists(pinned) {
                repaired.pinnedDirectory = nil
            }
            panes.append(repaired)
        }

        var tabs: [Tab] = []
        for tab in snapshot.workspace.tabs {
            guard let repaired = repair(tab, dropping: dropped) else { continue }
            tabs.append(repaired)
        }

        // An index out of range makes `focusedTab` nil, and every mutator returns
        // false on a nil focused tab, so the window would come back with tabs no key
        // could reach. Clamped rather than reset to 0, so losing the first tab does
        // not also move the user to the other end of the tab bar.
        let index = tabs.isEmpty
            ? 0
            : min(max(snapshot.workspace.focusedTabIndex, 0), tabs.count - 1)

        let live = Set(tabs.flatMap { $0.tree.paneIDs })

        // A `createdBy` naming a pane that did not come back is dropped, and the
        // child becomes a root. Not re-parented to the grandparent, which would
        // silently widen whoever's scope inherited it, and not left pointing at a
        // ghost, which would make `list` name a pane that does not exist. The parent
        // can be gone because its directory vanished above, because the file named a
        // pane no tree held, or because it was closed before the session was written.
        let restorable = panes.filter { live.contains($0.id) }.map { pane -> PaneState in
            guard let parent = pane.createdBy, !live.contains(parent) else { return pane }
            var rerooted = pane
            rerooted.createdBy = nil
            return rerooted
        }

        // Every anchor a surviving pane resolves to. An entry keyed under none of
        // them names a repository nothing in the restored window points at, and
        // keeping it would let the file outgrow the workspace.
        //
        // **Resolved, not raw**, and the difference is the whole reason this takes
        // a closure. A pane whose shell sits in `/repo/Sources/Foo` keys its open
        // directories under `/repo`, because the file tree is anchored at the
        // repository root the walk finds. Pruning against the working directory
        // would find no pane claiming `/repo` and throw away the expansions of the
        // pane that is looking at it, on every launch, while every test built from
        // a fixture whose working directory *is* its anchor passed.
        //
        // Resolved after the pins are repaired, above, so a pane whose pin vanished
        // is keyed at the anchor it will actually come back at rather than the one
        // the stale pin named.
        let survivingAnchors = Set(restorable.compactMap(resolveAnchor))
        let prunedExpansions = snapshot.fileTreeExpansions.map { expansions in
            expansions.filter { survivingAnchors.contains($0.key) }
        }

        return (
            snapshot: SessionSnapshot(
                schemaVersion: snapshot.schemaVersion,
                workspace: Workspace(tabs: tabs, focusedTabIndex: index),
                panes: restorable,
                windowFrame: snapshot.windowFrame,
                // Carried across by hand like every other field here, and the one
                // that was not: a sidebar dragged wide came back at its default
                // because this rebuilt the snapshot without it while the file on
                // disk was correct the whole time.
                sidebar: snapshot.sidebar,
                fileTreeExpansions: prunedExpansions
            ),
            droppedPanes: dropped
        )
    }

    /// One tab with the dropped panes taken out, or nil when it has none left.
    private static func repair(_ tab: Tab, dropping dropped: [PaneID]) -> Tab? {
        var tree = tab.tree
        for id in dropped where tree.contains(id) {
            guard let remaining = tree.closing(id) else { return nil }
            tree = remaining
        }

        var repaired = tab
        repaired.tree = tree
        if !tree.contains(repaired.focusedPane) {
            // The first pane in visual order, not the sibling that took the space.
            // Several panes can be gone at once here, and top-left is the one answer
            // that does not depend on the order the file happened to list them in.
            guard let first = tree.paneIDs.first else { return nil }
            repaired.focusedPane = first
        }
        // Zoom survives only on the pane that still has focus, which is the
        // invariant every ``Workspace`` mutator keeps. Clearing on inequality rather
        // than checking `contains` covers the dangling id and the zoom-on-an-unfocused
        // pane case in one line.
        if repaired.zoomedPane != repaired.focusedPane {
            repaired.zoomedPane = nil
        }
        return repaired
    }

    /// Creates `path` and every missing directory above it, and reports whether the
    /// directory is there afterwards.
    ///
    /// `mkdir(2)` rather than `FileManager.createDirectory`, which throws for a case
    /// that is not a failure: two saves in a row, where the second finds the
    /// directory already made. EEXIST is treated as success for that reason, and a
    /// component that exists as a regular file fails on the next `mkdir` with
    /// ENOTDIR, which is the honest answer.
    ///
    /// 0o700 to match the 0o600 on the file: nothing but baia reads this directory,
    /// and its one entry names directories the owner works in.
    ///
    /// `public`: ``ControlTransport`` calls this to create the same directory for
    /// the control socket, rather than keeping its own copy of the walk.
    public static func createDirectory(atPath path: String) -> Bool {
        // A relative path would have "/" prepended to its first component below and
        // silently create a directory at the root. No caller can get here with one,
        // since `URL(filePath:)` resolves against the working directory, but this
        // runs as the app quits and a wrong answer there is a lost session.
        guard path.hasPrefix("/") else { return false }

        var built = ""
        for component in path.split(separator: "/") {
            built += "/" + component
            if mkdir(built, 0o700) != 0, errno != EEXIST { return false }
        }
        return true
    }
}
