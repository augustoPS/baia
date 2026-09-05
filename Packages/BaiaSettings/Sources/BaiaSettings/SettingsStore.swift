import Darwin
import Foundation

/// What the config file is, before anything is written to it.
///
/// Five states rather than a Bool, because the two bad shapes want different
/// words in front of the owner and one of them (`unreadable`) is not about the
/// bytes at all. Only ``missing`` and ``valid`` accept an ordinary write.
public enum SettingsDocumentState: Sendable, Equatable {
    /// No file. An ordinary write
    /// creates the standard document and patches it.
    case missing
    /// A JSON object. An ordinary write patches the requested keys and keeps
    /// every other member.
    case valid
    /// A file that exists and cannot be read: permissions, a directory where
    /// the file should be, or a symbolic link whose target is missing. The
    /// dangling link is deliberately not ``missing``: an ordinary write would
    /// either create a file the owner's link does not point at or replace the
    /// link itself, and neither is what a dotfiles link asks for.
    case unreadable
    /// Bytes that are not JSON.
    case malformed
    /// Valid JSON that is not an object: an array, a string, a number.
    case notAnObject
}

/// Why a write did not land, one case per step that can fail.
///
/// Structured rather than a Bool so Settings can say what happened instead of
/// only playing a beep (audit S5). ``message`` is the sentence to show.
public enum SettingsWriteFailure: Error, Equatable, Sendable {
    case validation(SettingsValidationError)
    /// The file exists and could not be read, or is a link to a file that
    /// does not exist. Nothing is written in either case.
    case read
    /// The file is not JSON.
    case malformed
    /// The file is JSON but not an object.
    case notAnObject
    /// `~/.config/baia` could not be created.
    case directory
    /// The stable sibling used to coordinate writers could not be opened or
    /// locked for a reason other than contention.
    case lock
    /// Another cooperating process held the write lock for the bounded wait.
    case busy
    /// A non-cooperating writer changed the document after it was read and
    /// before its replacement. A patch retries from the new bytes before
    /// answering this; a repair answers it at once and keeps the backup it had
    /// already written beside the file, since those bytes are the only copy of
    /// what the owner had before the other writer, even though no receipt can
    /// name it.
    case conflict
    /// Repair only: the backup of the original bytes could not be written, so
    /// nothing else was.
    case backup
    /// The temporary sibling could not be written in full.
    case temporaryWrite
    /// The temporary sibling could not be renamed over the file.
    case rename

    public var message: String {
        switch self {
        case let .validation(error):
            error.message
        case .read:
            "The configuration file could not be read. Check its permissions, and that it is not a link to a missing file."
        case .malformed:
            "The configuration file is not valid JSON, so Baia will not write to it."
        case .notAnObject:
            "The configuration file is valid JSON but not an object, so Baia will not write to it."
        case .directory:
            "The configuration directory could not be created."
        case .lock:
            "The configuration write lock could not be opened."
        case .busy:
            "Another Baia process is saving the configuration. Try again."
        case .conflict:
            "The configuration changed while Baia was saving it. This change was not written; try again."
        case .backup:
            "The backup of the original file could not be written, so nothing was changed."
        case .temporaryWrite:
            "The new configuration could not be written. The disk may be full."
        case .rename:
            "The new configuration could not replace the old file."
        }
    }
}

/// What a repair left behind.
public struct SettingsRepairReceipt: Sendable, Equatable {
    /// Where the original bytes went, untouched.
    public let backupURL: URL
    /// The document that replaced them, decoded.
    public let result: SettingsDecodeResult
}

/// The config file on disk: where it is, what it says, and how it is changed.
public struct SettingsStore: Sendable {
    private let fileURL: URL

    /// Runs after a candidate is staged and before the generation check. Nil
    /// in every production store. Tests use it to put a non-cooperating write
    /// into the one interval this code can observe, instead of racing a large
    /// fixture against the scheduler.
    private let afterStaging: (@Sendable () -> Void)?

    public init(fileURL: URL) {
        self.init(fileURL: fileURL, afterStaging: nil)
    }

    init(fileURL: URL, afterStaging: (@Sendable () -> Void)?) {
        // One physical config gets one lock even when two callers reached it
        // through different symlink spellings. Operations use the same canonical
        // target, so replacing through a symlink never turns the symlink itself
        // into a second, independently locked config file. A link whose target
        // is missing stays unresolved here, and ``readDocument()`` reports it as
        // unreadable rather than missing.
        self.fileURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        self.afterStaging = afterStaging
    }

    /// `~/.config/baia/config.json`.
    ///
    /// `XDG_CONFIG_HOME` is deliberately not consulted, even though ghostty
    /// honours it. baia is launched from Finder and from `make run`, and the
    /// variable is set in neither, so honouring it would put the config in one
    /// place for a shell launch and another for a double click, leaving the owner
    /// editing a file the running app is not reading.
    public static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/baia/config.json")
    }

    /// The file's location, for the recovery banner's reveal action.
    public var url: URL { fileURL }

    /// The settings on disk, or the defaults when there is no file.
    ///
    /// A missing file is not a failure: a first launch has none, and the defaults
    /// are then the config. `FileManager.contents(atPath:)` is used rather than
    /// `Data(contentsOf:)` because it answers nil instead of throwing, and there
    /// is no `try` in this project's production code. An unreadable file, one
    /// whose permissions were changed by hand, is nil here too and reports
    /// nothing, which is the one gap in the reporting: the decoder can only blame
    /// keys it was given. ``inspect()`` is where that case gets a name.
    public func load() -> SettingsDecodeResult {
        let path = fileURL.path(percentEncoded: false)
        guard let data = FileManager.default.contents(atPath: path) else {
            return SettingsDecoder.decode(Data())
        }
        return SettingsDecoder.decode(data)
    }

    /// What is at the path right now, as a write would find it.
    public func inspect() -> SettingsDocumentState {
        switch readDocument() {
        case .missing: .missing
        case .unreadable: .unreadable
        case .malformed: .malformed
        case .notAnObject: .notAnObject
        case .object: .valid
        }
    }

    /// Writes a fully populated config with every default filled in, so the owner
    /// has something to edit rather than a blank file, and answers whether it
    /// wrote one. Never overwrites an existing file.
    ///
    /// `fontFamily` is written as `null`, which the decoder reads as unset. Every
    /// key the decoder understands is present, so the file is the reference for
    /// the spellings and the owner never has to read this source to find one.
    ///
    /// The exclusion is `O_EXCL` rather than a `fileExists` check followed by a
    /// write. Two launches racing on a first run would both pass the check, and
    /// the loser would truncate the file the winner had already written, which
    /// breaks the promise in the sentence above for the one case where it matters.
    public func writeDefaultIfAbsent() -> Bool {
        guard Self.createDirectories(fileURL.deletingLastPathComponent()) else { return false }

        // 0o600, so a config that gains a token or a remote host later starts
        // private instead of needing someone to remember to tighten it. The mode
        // is masked by the process umask, so it is a ceiling and not a guarantee.
        let descriptor = open(
            fileURL.path(percentEncoded: false),
            O_WRONLY | O_CREAT | O_EXCL,
            0o600
        )
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return Self.writeAll(Array(Self.defaultFileContents.utf8), to: descriptor)
    }

    /// Patches `edits` into the document on disk and answers what the file now
    /// decodes to.
    ///
    /// The file is read fresh on every call. A value the owner changed by hand
    /// since the last write is carried through untouched, and the one field being
    /// edited is the only member that moves. A missing file starts from the
    /// standard document, so the first write from Settings on a fresh account
    /// leaves the owner the same fully populated file a launch would have.
    ///
    /// A malformed, unreadable or non-object file is refused. Overwriting it
    /// would destroy whatever the owner had in it, and the 2026-09-04 audit
    /// reproduced exactly that loss. ``repair(with:at:)`` is the explicit path.
    ///
    /// The bytes go to a sibling temporary file and are renamed over the target.
    /// `rename` within a directory is atomic, so a reader never sees half a
    /// document and a crash mid-write leaves the previous file intact. The rename
    /// fires `.rename` and `.delete` on the `ConfigurationCenter` watcher, which
    /// re-arms against the path.
    public func patch(_ edits: [SettingsEdit]) -> Result<SettingsDecodeResult, SettingsWriteFailure> {
        patchRecordingPrevious(edits).map(\.result)
    }

    /// The previous value and result come from the same document read.
    func patchRecordingPrevious(_ edits: [SettingsEdit]) -> Result<(previous: Settings, result: SettingsDecodeResult), SettingsWriteFailure> {
        var validated: [SettingsEdit] = []
        for edit in edits {
            switch edit.validated() {
            case let .success(valid): validated.append(valid)
            case let .failure(error): return .failure(.validation(error))
            }
        }

        return withExclusiveWriteLock {
            patchRecordingPrevious(validated: validated)
        }
    }

    /// Runs one validated read/patch/replace transaction while every
    /// cooperating SettingsStore for this physical file is excluded.
    private func patchRecordingPrevious(
        validated: [SettingsEdit]
    ) -> Result<(previous: Settings, result: SettingsDecodeResult), SettingsWriteFailure> {
        for attempt in 1 ... 3 {
            let outcome = patchOnce(validated: validated)
            guard case .failure(.conflict) = outcome, attempt < 3 else { return outcome }
        }
        return .failure(.conflict)
    }

    /// One optimistic attempt. The advisory lock serializes Baia processes;
    /// comparing the exact bytes again protects against editors that do not use
    /// that lock. A caller retries a changed generation from its new contents.
    private func patchOnce(
        validated: [SettingsEdit]
    ) -> Result<(previous: Settings, result: SettingsDecodeResult), SettingsWriteFailure> {
        let document: JSONValue
        let wasMissing: Bool
        let original: Document
        switch readDocument() {
        case .missing:
            wasMissing = true
            original = .missing
            // The literal parses by construction; `SettingsStoreTests` decodes it
            // back to the defaults on every run.
            document = JSONValue.parse(Data(Self.defaultFileContents.utf8)) ?? .object([:])
        case let .object(existing, bytes):
            wasMissing = false
            original = .object(existing, bytes)
            document = existing
        case .unreadable:
            return .failure(.read)
        case .malformed:
            return .failure(.malformed)
        case .notAnObject:
            return .failure(.notAnObject)
        }

        guard case let .object(members) = document else { return .failure(.notAnObject) }
        let changes = validated.filter { edit in
            let original = members[edit.key.rawValue]
            if case let .numberLiteral(text)? = original, case let .number(value) = edit.jsonValue {
                return Double(text) != value
            }
            return original != edit.jsonValue
        }
        guard let patched = SettingsWriter.patch(document, edits: changes) else {
            return .failure(.notAnObject)
        }
        let previous = SettingsDecoder.decode(Data(SettingsWriter.serialize(document).utf8)).settings
        if changes.isEmpty, !wasMissing {
            return .success((previous, SettingsDecoder.decode(Data(SettingsWriter.serialize(document).utf8))))
        }
        let bytes = Array(SettingsWriter.serialize(patched).utf8)
        let staged: URL
        switch stage(bytes) {
        case let .success(url):
            staged = url
        case let .failure(failure):
            return .failure(failure)
        }
        afterStaging?()
        guard documentStillMatches(original) else {
            unlink(staged.path(percentEncoded: false))
            return .failure(.conflict)
        }
        if let failure = replace(with: staged) {
            return .failure(failure)
        }
        return .success((previous, SettingsDecoder.decode(Data(bytes))))
    }

    /// Backs the original bytes up beside the file, then replaces the file with
    /// a document built from `settings`.
    ///
    /// The backup comes first and its failure ends the repair: a repair that
    /// wrote the replacement and then failed to keep the original would be the
    /// silent loss this path exists to prevent. The backup is created `O_EXCL`,
    /// so two repairs in one second cannot share a name, and it keeps the
    /// original's bytes exactly, malformed or not.
    ///
    /// A missing or unreadable file cannot be backed up and is not repaired:
    /// missing needs no repair, since ``patch(_:)`` creates it, and unreadable
    /// is a permissions problem, or a dangling link, that a new document would
    /// not fix.
    ///
    /// A repair refused with ``SettingsWriteFailure/conflict`` has already
    /// written its backup, and leaves it. The receipt is the only thing that
    /// names a backup, and a refused repair has no receipt, so the owner finds
    /// that file by its `config.json.backup-` name beside the config. Deleting
    /// it would discard the one copy of the bytes the other writer replaced.
    public func repair(
        with settings: Settings,
        at date: Date = Date()
    ) -> Result<SettingsRepairReceipt, SettingsWriteFailure> {
        withExclusiveWriteLock {
            repairWhileLocked(with: settings, at: date)
        }
    }

    /// Keeps the bytes being backed up, staged, checked, and replaced inside
    /// the same protocol as an ordinary patch. Repair does not retry a changed
    /// generation: its backup describes the first read, so replacing a newer
    /// document on a later attempt would no longer be that repair.
    private func repairWhileLocked(
        with settings: Settings,
        at date: Date
    ) -> Result<SettingsRepairReceipt, SettingsWriteFailure> {
        let path = fileURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path),
              let original = FileManager.default.contents(atPath: path)
        else {
            return .failure(.read)
        }

        guard let backupURL = writeBackup(Array(original), at: date) else {
            return .failure(.backup)
        }

        let bytes = Array(SettingsWriter.serialize(SettingsWriter.document(from: settings)).utf8)
        let staged: URL
        switch stage(bytes) {
        case let .success(url):
            staged = url
        case let .failure(failure):
            return .failure(failure)
        }
        afterStaging?()
        guard FileManager.default.contents(atPath: path) == original else {
            unlink(staged.path(percentEncoded: false))
            return .failure(.conflict)
        }
        if let failure = replace(with: staged) { return .failure(failure) }
        return .success(SettingsRepairReceipt(
            backupURL: backupURL,
            result: SettingsDecoder.decode(Data(bytes))
        ))
    }

    // MARK: - Reading

    private enum Document {
        case missing
        case unreadable
        case malformed
        case notAnObject
        case object(JSONValue, Data)
    }

    private func readDocument() -> Document {
        let path = fileURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            // `fileExists` follows links. Something at the path that it cannot
            // see through is a link to a file that is not there, and that is
            // unreadable, not missing: a write here would have to choose between
            // creating the target and replacing the link, and refusing is the
            // only choice that leaves the owner's arrangement as it was.
            var information = stat()
            return lstat(path, &information) == 0 ? .unreadable : .missing
        }
        guard let data = FileManager.default.contents(atPath: path) else { return .unreadable }
        guard let parsed = JSONValue.parse(data, preservingNumbers: true) else { return .malformed }
        guard case .object = parsed else { return .notAnObject }
        return .object(parsed, data)
    }

    // MARK: - Writing

    /// Acquires the stable sibling lock without leaving the main actor blocked
    /// indefinitely. Fifty non-blocking attempts at 10 ms cap contention near
    /// 500 ms; a dead process releases its advisory lock when its descriptor
    /// closes.
    private func withExclusiveWriteLock<Value>(
        _ body: () -> Result<Value, SettingsWriteFailure>
    ) -> Result<Value, SettingsWriteFailure> {
        let directory = fileURL.deletingLastPathComponent()
        guard Self.createDirectories(directory) else { return .failure(.directory) }
        // A case-insensitive volume accepts CONFIG.JSON and config.json as the
        // same path while preserving whichever spelling the caller supplied.
        // Folding only the private lock name makes those aliases cooperate; on
        // a case-sensitive volume it merely over-serializes two unusual sibling
        // names and never redirects either config operation.
        let lockName = ".\(fileURL.lastPathComponent.lowercased()).lock"
        let lockURL = directory.appending(path: lockName)
        let descriptor = open(
            lockURL.path(percentEncoded: false),
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else { return .failure(.lock) }
        defer { close(descriptor) }

        var waits = 0
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            guard errno == EWOULDBLOCK else { return .failure(.lock) }
            guard waits < 50 else { return .failure(.busy) }
            waits += 1
            usleep(10_000)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return body()
    }

    /// Writes a complete candidate to an exclusive sibling. A UUID is not the
    /// exclusion mechanism: `O_EXCL` is, so even a collision cannot truncate a
    /// stage another thread or process still owns.
    private func stage(_ bytes: [UInt8]) -> Result<URL, SettingsWriteFailure> {
        let directory = fileURL.deletingLastPathComponent()
        guard Self.createDirectories(directory) else { return .failure(.directory) }

        let temporaryURL = directory.appending(
            path: ".\(fileURL.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp"
        )
        let temporaryPath = temporaryURL.path(percentEncoded: false)

        // 0o600 for the same reason `writeDefaultIfAbsent` asks for it: the file
        // this becomes is the config, and it should not be briefly world-readable
        // on its way there.
        let descriptor = open(
            temporaryPath,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else { return .failure(.temporaryWrite) }

        let wrote = Self.writeAll(bytes, to: descriptor)
        close(descriptor)
        guard wrote else {
            unlink(temporaryPath)
            return .failure(.temporaryWrite)
        }
        return .success(temporaryURL)
    }

    /// Replaces the target with one complete stage and removes the stage on
    /// failure.
    private func replace(with temporaryURL: URL) -> SettingsWriteFailure? {
        let temporaryPath = temporaryURL.path(percentEncoded: false)
        guard rename(temporaryPath, fileURL.path(percentEncoded: false)) == 0 else {
            unlink(temporaryPath)
            return .rename
        }
        return nil
    }

    /// Whether the target still has the exact generation read for this attempt.
    /// Byte equality deliberately includes whitespace and numeric spelling: a
    /// non-cooperating owner edit is a conflict even when it decodes to the same
    /// Settings value.
    private func documentStillMatches(_ original: Document) -> Bool {
        let path = fileURL.path(percentEncoded: false)
        switch original {
        case .missing:
            var information = stat()
            return lstat(path, &information) != 0 && errno == ENOENT
        case let .object(_, bytes):
            return FileManager.default.contents(atPath: path) == bytes
        case .unreadable, .malformed, .notAnObject:
            return false
        }
    }

    /// Writes `bytes` to a new timestamped sibling and answers where, or nil.
    ///
    /// `config.json.backup-2026-09-04T18-01-14Z`, and `-2`, `-3` after it when
    /// that name is taken. The clock is UTC so two machines sharing a synced
    /// config directory name their backups in one calendar.
    private func writeBackup(_ bytes: [UInt8], at date: Date) -> URL? {
        let directory = fileURL.deletingLastPathComponent()
        let stamp = Self.backupTimestamp(date)
        let base = fileURL.lastPathComponent + ".backup-" + stamp
        for attempt in 1 ... 20 {
            let name = attempt == 1 ? base : base + "-\(attempt)"
            let url = directory.appending(path: name)
            let descriptor = open(url.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if descriptor < 0 {
                if errno == EEXIST { continue }
                return nil
            }
            let wrote = Self.writeAll(bytes, to: descriptor)
            close(descriptor)
            guard wrote else {
                unlink(url.path(percentEncoded: false))
                return nil
            }
            return url
        }
        return nil
    }

    /// `2026-09-04T18-01-14Z`: ISO 8601 with the colons replaced, since a colon
    /// in a file name reads as a path separator in Finder.
    static func backupTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    /// Creates `directory` and every missing parent, answering whether it exists
    /// afterwards.
    ///
    /// `FileManager.createDirectory(at:withIntermediateDirectories:)` is the
    /// obvious call and it throws, which production code here does not. `mkdir`
    /// reports an existing directory as `EEXIST`, which is the same information
    /// the `withIntermediateDirectories` flag hides, and `errno` is only read
    /// after a failure return so it cannot carry a stale value in.
    private static func createDirectories(_ directory: URL) -> Bool {
        var built = ""
        for component in directory.pathComponents {
            built = component == "/" ? "/" : built + (built.hasSuffix("/") ? "" : "/") + component
            if mkdir(built, 0o700) == 0 { continue }
            guard errno == EEXIST else { return false }
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: built, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return false }
        }
        return true
    }

    /// Writes every byte, answering false when it cannot.
    ///
    /// `write` is allowed to accept fewer bytes than it was offered and to fail
    /// with `EINTR` when a signal arrives mid call. Either would leave a config
    /// file that stops halfway through a key, and that file then decodes as
    /// unreadable, which means baia would report an error about a file it wrote
    /// itself and never repair it, since the path now exists.
    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32) -> Bool {
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, base + written, buffer.count - written)
                if count > 0 {
                    written += count
                    continue
                }
                guard count < 0, errno == EINTR else { return false }
            }
            return true
        }
    }

    /// The first-launch file, holding ``Settings/defaultSettings`` in the
    /// decoder's own key spellings.
    ///
    /// Written out as text rather than assembled from `defaultSettings`, so the
    /// file the owner learns the spellings from is readable here as text. It
    /// cannot drift: `SettingsStoreTests` decodes this file back and expects the
    /// defaults with nothing reported, and expects its key set to equal
    /// `SettingsDecoder.knownKeys`. It still spells `chromeStyle` as `glass`,
    /// the pre-2026-08-15 name, which the decoder keeps accepting.
    ///
    /// `projectRoots` keeps the tilde rather than the expanded path. The file is
    /// meant to be copied between machines, and the decoder expands it on read.
    static let defaultFileContents = """
    {
      "fontFamily": null,
      "fontSize": 11.5,
      "themeName": "Dark Pastel",
      "backgroundHex": "#141414",
      "backgroundOpacity": 0.42,
      "backgroundBlur": true,
      "windowPadding": 8,
      "windowPaddingBalance": true,
      "transparentTitlebar": true,
      "optionAsAlt": true,
      "cursorStyle": "block",
      "projectRoots": ["~/Projects"],
      "discoveryMaxDepth": 3,
      "notificationsEnabled": true,
      "gitPollSeconds": 2,
      "activityPollSeconds": 1,
      "restoreSession": true,
      "focusAccent": "accent",
      "attentionStyle": "loud",
      "attentionAccent": "alert",
      "alertBehavior": "stock",
      "chromeStyle": "glass",
      "sidebar": "off",
      "controlChannelEnabled": true,
      "controlAllowRun": false,
      "controlAllowRead": true
    }

    """
}
