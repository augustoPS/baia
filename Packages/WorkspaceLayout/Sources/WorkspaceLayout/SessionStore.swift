import Darwin
import Foundation

/// Reads and writes the session file, retaining enough health to protect rejected
/// bytes from every later automatic save.
///
/// Errors are translated into typed outcomes at this boundary. Callers never need
/// to catch Foundation errors to decide whether restoring or saving is safe.
public enum SessionRejection: Sendable, Equatable {
    case unreadable
    case malformed
    case unsupportedSchema(Int)
}

public enum SessionLoadResult: Sendable, Equatable {
    case absent
    case loaded(SessionSnapshot)
    case rejected(SessionRejection)
}

public enum SessionSaveResult: Sendable, Equatable {
    case saved
    case blocked(SessionRejection)
    case failed

    /// The first write after a version 1 file was migrated could not copy those
    /// bytes to any sibling in ``SessionStore/migrationBackupURL(attempt:)``'s
    /// series, so nothing was overwritten.
    ///
    /// Distinct from ``failed``, which means the write itself did not land. Here
    /// the write was never attempted: a migrated session that cannot preserve the
    /// document it came from does not get to replace it, for the reason
    /// ``SessionStore/recover(replacingWith:backupURL:)`` refuses the same way.
    case migrationBackupFailed
}

public enum SessionRecoveryResult: Sendable, Equatable {
    case recovered(URL)
    case backupFailed
    case saveFailed(URL)
    case notRejected
}

public final class SessionStore: @unchecked Sendable {
    private struct SchemaHeader: Decodable {
        let schemaVersion: Int
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var inspectedRejection: SessionRejection?
    private var hasInspected = false

    /// The version 1 bytes read at inspection, held until the first version 2 write
    /// backs them up.
    ///
    /// Migration happens in memory, so nothing on disk changes at load: the file is
    /// only rewritten when the app next saves, and that save is the step a
    /// downgrade could not survive. Holding the exact bytes here rather than
    /// re-reading them at save time is what makes the backup a copy of what was
    /// actually migrated, not of whatever an external writer left in the meantime.
    private var pendingV1Backup: Data?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// ~/Library/Application Support/baia/session.json
    ///
    /// `urls(for:in:)` rather than `url(for:in:appropriateFor:create:)`, which
    /// throws and creates the directory as a side effect of being asked where it
    /// is. Creating it belongs to `save`, the only writer, so a launch that only
    /// reads never leaves an empty directory behind.
    /// - Parameter directoryName: the folder under Application Support. `baia`
    ///   for the installed copy and `baia-dev` for the build under test, so the
    ///   two can run at once without one's window list overwriting the other's.
    ///   The app reads it from `BAIASupportDirectory` in its own Info.plist; the
    ///   default is here so a package test never has to know that.
    public static func defaultFileURL(directoryName: String = "baia") -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
                .appending(path: "Library/Application Support")
        return support
            .appending(path: directoryName, directoryHint: .isDirectory)
            .appending(path: "session.json")
    }

    /// Reads the file and retains rejection health so no later save can overwrite
    /// bytes this build did not understand.
    public func inspect() -> SessionLoadResult {
        lock.lock()
        defer { lock.unlock() }
        return inspectLocked()
    }

    private func inspectLocked() -> SessionLoadResult {
        let path = fileURL.path(percentEncoded: false)
        let result: SessionLoadResult
        guard let data = try? Data(contentsOf: fileURL) else {
            var metadata = stat()
            if lstat(path, &metadata) == 0 || errno != ENOENT {
                result = .rejected(.unreadable)
            } else {
                result = .absent
            }
            recordLocked(result)
            return result
        }
        guard let header = try? JSONDecoder().decode(SchemaHeader.self, from: data) else {
            result = .rejected(.malformed)
            recordLocked(result)
            return result
        }

        // A version this build does not know is refused whole. A file from a newer
        // baia may hold a tree shape or a ratio convention this one would decode
        // into a plausible but wrong workspace, and a wrong workspace is worse than
        // a fresh one: it would be saved back over the good file on quit.
        //
        // Version 1 is the one older shape this build reads, because it can
        // reconstruct it exactly: v1 recorded a flat tab list and one frame, which
        // is what the app itself produced when every window was joined into a
        // single tab group. Migrating it is not a guess. Anything below 1, or above
        // what this build writes, still refuses whole.
        switch header.schemaVersion {
        case SessionSnapshot.currentSchemaVersion:
            guard let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data) else {
                result = .rejected(.malformed)
                recordLocked(result)
                return result
            }
            result = .loaded(snapshot)
        case SessionSnapshot.oldestReadableSchemaVersion:
            guard let old = try? JSONDecoder().decode(SessionSnapshotV1.self, from: data) else {
                result = .rejected(.malformed)
                recordLocked(result)
                return result
            }
            result = .loaded(SessionSnapshot.migrating(old))
        default:
            result = .rejected(.unsupportedSchema(header.schemaVersion))
        }
        recordLocked(result)
        // After `recordLocked`, which clears this for every other outcome. A
        // re-inspection that now finds a version 2 file must not leave the old
        // bytes armed for a backup nothing is going to overwrite.
        if header.schemaVersion == SessionSnapshot.oldestReadableSchemaVersion,
           case .loaded = result {
            pendingV1Backup = data
        }
        return result
    }

    /// Where the version 1 document is copied before the first version 2 write
    /// replaces it: `session.json.v1-backup` first, then `session.json.v1-backup-2`,
    /// `-3` and so on when the name before it already holds different bytes.
    ///
    /// Numbered rather than fixed, because the cycle the backup exists for produces
    /// a second migration of the same file. The owner runs an older build; it refuses
    /// the version 2 document and, through R01's recovery, writes a fresh version 1
    /// one; the next launch of this build migrates *those* bytes, which are not the
    /// bytes the first backup holds. A fixed name refused every save from then on,
    /// and the alert never named the file in the way. Each sibling is created
    /// exclusively and read back, so an earlier backup is never overwritten and a
    /// copy is never taken on trust. ``verifiedMigrationBackupURL`` says which
    /// sibling the current document's bytes ended up in.
    public func migrationBackupURL(attempt: Int = 1) -> URL {
        fileURL.appendingPathExtension(attempt <= 1 ? "v1-backup" : "v1-backup-\(attempt)")
    }

    /// The sibling holding a verified copy of the version 1 bytes this store
    /// migrated, or nil until the first version 2 write has made one.
    public private(set) var verifiedMigrationBackupURL: URL?

    /// How many numbered siblings are tried before the write is refused. Twenty
    /// downgrade cycles of one file is far past anything an owner does by hand, and a
    /// bound keeps a directory full of foreign files from turning into a scan.
    static let migrationBackupAttempts = 20

    /// Compatibility for callers interested only in a usable snapshot. Calling it
    /// still arms rejected-file protection.
    public func load() -> SessionSnapshot? {
        guard case let .loaded(snapshot) = inspect() else { return nil }
        return snapshot
    }

    /// Writes the session, and reports whether it landed.
    ///
    /// Writes a sibling temporary file, then atomically renames it over the target.
    /// A process crash during replacement leaves the complete old or new file at
    /// the path. `rename(2)` keeps replacement on the same filesystem and avoids
    /// `FileManager.replaceItemAt` staging a separate temporary directory.
    ///
    /// Session durability (W06):
    /// - The app rearms a one-second trailing timer after each workspace change.
    ///   Continuous changes or a delayed main run loop can postpone the save longer.
    ///   Abrupt termination can lose every change since the last successful save.
    /// - Atomic replacement prevents readers seeing a partially written session.
    ///   It does not make pending layout changes durable before the save runs.
    /// - Power-loss durability is not guaranteed: neither the file nor its parent
    ///   directory is synced before success is reported.
    public func save(_ snapshot: SessionSnapshot) -> Bool {
        saveResult(snapshot) == .saved
    }

    /// Writes only when the source was absent or valid. An uninspected store reads
    /// first, so protection does not depend on every caller remembering a preflight.
    public func saveResult(_ snapshot: SessionSnapshot) -> SessionSaveResult {
        lock.lock()
        defer { lock.unlock() }
        if !hasInspected { _ = inspectLocked() }
        if let inspectedRejection { return .blocked(inspectedRejection) }
        // The version 1 document is preserved before the write that replaces it,
        // not after: this is the only moment those bytes still exist at the target,
        // and a migration that cannot preserve what it came from does not get to
        // overwrite it. Verified by reading the copy back, the same discipline
        // `recover` uses, because an unverified backup is a claim rather than a
        // copy.
        if let pending = pendingV1Backup {
            guard backUpMigratedSourceLocked(pending) else { return .migrationBackupFailed }
        }
        guard write(snapshot) else { return .failed }
        recordLocked(.loaded(snapshot))
        return .saved
    }

    /// Copies the version 1 bytes aside, and reports whether they are safe.
    ///
    /// Each name in the series is tried in turn. A name that can be created
    /// exclusively takes the bytes and is read back before it counts. A name that
    /// exists and already holds this exact document is an earlier attempt that did
    /// preserve it, which is success. A name that exists and holds anything else is
    /// an earlier backup of other bytes, or a file this store did not write, and is
    /// never written through: the next number is tried. A name that does not exist
    /// and still could not be created means the directory refused the write, and a
    /// longer name would not change that.
    private func backUpMigratedSourceLocked(_ source: Data) -> Bool {
        let directory = fileURL.deletingLastPathComponent().path(percentEncoded: false)
        guard Self.createDirectory(atPath: directory) else { return false }
        for attempt in 1 ... Self.migrationBackupAttempts {
            let backup = migrationBackupURL(attempt: attempt)
            if Self.createExclusiveFile(at: backup, contents: source) {
                // Read back rather than trusted: an unverified backup is a claim,
                // not a copy, and the write that follows is the one a downgrade
                // cannot undo.
                guard (try? Data(contentsOf: backup)) == source else { return false }
                verifiedMigrationBackupURL = backup
                pendingV1Backup = nil
                return true
            }
            var information = stat()
            guard lstat(backup.path(percentEncoded: false), &information) == 0 else { return false }
            if (try? Data(contentsOf: backup)) == source {
                verifiedMigrationBackupURL = backup
                pendingV1Backup = nil
                return true
            }
        }
        return false
    }

    /// Makes a byte-for-byte backup of a rejected source before replacing it.
    /// `backupURL` must not exist; recovery never overwrites an earlier backup.
    public func recover(
        replacingWith snapshot: SessionSnapshot,
        backupURL: URL? = nil
    ) -> SessionRecoveryResult {
        lock.lock()
        defer { lock.unlock() }
        guard inspectedRejection != nil else { return .notRejected }
        guard let source = try? Data(contentsOf: fileURL) else { return .backupFailed }
        let backup = backupURL ?? nextRecoveryBackupURLLocked()
        let backupDirectory = backup.deletingLastPathComponent().path(percentEncoded: false)
        guard Self.createDirectory(atPath: backupDirectory),
              Self.createExclusiveFile(at: backup, contents: source),
              (try? Data(contentsOf: backup)) == source
        else { return .backupFailed }

        // An external writer may have changed the source while its backup was
        // being created. Refuse replacement unless the backup still matches the
        // exact bytes currently at the target.
        guard (try? Data(contentsOf: fileURL)) == source else { return .backupFailed }

        guard write(snapshot) else { return .saveFailed(backup) }
        recordLocked(.loaded(snapshot))
        return .recovered(backup)
    }

    /// The first unused sibling name, stable enough to show in recovery UI and
    /// exclusive at creation time so two attempts cannot replace one another.
    public func nextRecoveryBackupURL() -> URL {
        lock.lock()
        defer { lock.unlock() }
        return nextRecoveryBackupURLLocked()
    }

    private func nextRecoveryBackupURLLocked() -> URL {
        let base = fileURL.appendingPathExtension("rejected-backup")
        if !FileManager.default.fileExists(atPath: base.path(percentEncoded: false)) { return base }
        for number in 2...10_000 {
            let candidate = fileURL.appendingPathExtension("rejected-backup.\(number)")
            if !FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }
        return fileURL.appendingPathExtension("rejected-backup.exhausted")
    }

    private func recordLocked(_ result: SessionLoadResult) {
        hasInspected = true
        if case let .rejected(reason) = result {
            inspectedRejection = reason
        } else {
            inspectedRejection = nil
        }
        // Cleared here so every path through inspection resets it, and re-armed by
        // the one caller that read version 1 bytes. A stale arming would make a
        // later save refuse over a document that is no longer at the target.
        pendingV1Backup = nil
    }

    private func write(_ snapshot: SessionSnapshot) -> Bool {
        let path = fileURL.path(percentEncoded: false)
        let directory = fileURL.deletingLastPathComponent().path(percentEncoded: false)
        guard Self.createDirectory(atPath: directory) else { return false }
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }

        // 0o600 because the session names every directory the user works in, and
        // Application Support is world readable by default.
        // A unique, exclusively-created sibling cannot alias a caller-selected
        // recovery backup, including on a case-insensitive filesystem or through
        // a symlinked parent directory.
        let temporaryPath = path + ".tmp." + UUID().uuidString
        guard Self.createExclusiveFile(at: URL(filePath: temporaryPath), contents: data)
        else { return false }

        guard rename(temporaryPath, path) == 0 else {
            // The temporary is removed on failure so a stale one cannot be mistaken
            // for a session later, and so a full disk does not keep two copies.
            unlink(temporaryPath)
            return false
        }
        return true
    }

    private static func createExclusiveFile(at url: URL, contents: Data) -> Bool {
        let path = url.path(percentEncoded: false)
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return false }
        var succeeded = true
        contents.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count <= 0 {
                    succeeded = false
                    break
                }
                offset += count
            }
        }
        if Darwin.close(descriptor) != 0 { succeeded = false }
        if !succeeded { unlink(path) }
        return succeeded
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
    /// no groups, not nil. The caller then opens a pane at its default directory,
    /// which is what it already does on a first launch.
    public static func reconciled(
        _ snapshot: SessionSnapshot,
        directoryExists: (String) -> Bool,
        resolveAnchor: (PaneState) -> String?
    ) -> (snapshot: SessionSnapshot, droppedPanes: [PaneID]) {
        // The ids a tab actually shows. A `PaneState` for a pane no group holds is
        // a leftover from an earlier save, and reporting it as dropped would name a
        // pane the caller was never going to create.
        let shown = Set(snapshot.shownPaneIDs)

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

        // Each group keeps the tabs that still have panes, and a group that has
        // none left goes with them. A window showing nothing is not a window the
        // owner can use, and leaving it would restore an empty frame beside the
        // real ones.
        var groups: [WindowGroup] = []
        for group in snapshot.groups {
            var tabs: [Tab] = []
            for tab in group.tabs {
                guard let repaired = repair(tab, dropping: dropped) else { continue }
                tabs.append(repaired)
            }
            guard let first = tabs.first else { continue }
            var kept = group
            kept.tabs = tabs
            // A selection naming a tab that was dropped falls back to the first tab
            // of that group, which is the leftmost one in its own tab bar. Not the
            // tab that slid into its slot, because several can be gone at once and
            // the leftmost is the one answer that does not depend on the order the
            // file happened to list them in.
            if !tabs.contains(where: { $0.id == kept.selectedTab }) {
                kept.selectedTab = first.id
            }
            groups.append(kept)
        }

        // An active group that was dropped falls back to the first surviving one,
        // for the reason the tab selection does: the keyboard has to land in a
        // window that exists. Nil when nothing survived, which is a launchable
        // answer and what `active` already resolves through.
        let active = groups.contains { $0.id == snapshot.activeGroup }
            ? snapshot.activeGroup
            : groups.first?.id

        let live = Set(groups.flatMap { $0.paneIDs })

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
        // them names a repository nothing in the restored windows points at, and
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
                groups: groups,
                activeGroup: active,
                panes: restorable,
                // The sidebar now rides on each group and is carried by the `var
                // kept = group` copy above, which is what keeps the field that was
                // once dropped here from being droppable at all: a sidebar dragged
                // wide came back at its default because this rebuilt the snapshot
                // without it while the file on disk was correct the whole time.
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
