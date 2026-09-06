import CoreServices
import Foundation

/// Recursive filesystem invalidation for one canonical worktree root.
///
/// This adapter owns no repository reads, polling, coalescing, or read retry.
/// It only translates relevant FSEvents into a root-scoped invalidation and
/// repairs its own stream attachment. A linked worktree's `.git` is a file, so
/// the stream also follows its resolved per-worktree Git directory and common
/// refs.
nonisolated final class RepositoryEvents: @unchecked Sendable {
    /// Working-tree writes vs gitdir/refs/rescan. The app attacher maps this
    /// onto the observer's invalidation reason. Kept local so this file still
    /// compiles as the standalone events fixture.
    enum Invalidation: Sendable, Equatable {
        case workingTree
        case metadata

        func merged(with other: Invalidation) -> Invalidation {
            if self == .metadata || other == .metadata { return .metadata }
            return .workingTree
        }
    }

    typealias Invalidate = @Sendable (URL, Invalidation) -> Void

    enum StartError: Error {
        case streamCreationFailed
        case streamStartFailed
    }

    private let engine: RepositoryEventsEngine

    /// Resolves Git metadata paths and starts FSEvents synchronously. The
    /// observer integration must construct adapters away from the main thread.
    init(root: URL, invalidate: @escaping Invalidate) throws {
        engine = try RepositoryEventsEngine(root: root, invalidate: invalidate)
    }

    /// Closes the delivery gate immediately and schedules serialized stream
    /// cleanup. A batch already crossing the delivery boundary may finish;
    /// queued and future batches are suppressed. Safe to call repeatedly and
    /// from app teardown.
    func stop() {
        engine.stop()
    }

    deinit {
        engine.stop()
    }

    /// Dropped histories and root identity changes require the observer core to
    /// rescan rather than interpreting the batch as a complete delta.
    static func requiresRescan(_ flags: FSEventStreamEventFlags) -> Bool {
        let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped
            | kFSEventStreamEventFlagRootChanged)
        return flags & rescanFlags != 0
    }
}

/// `stream`, `targets`, and the scheduling flags are confined to `queue`.
/// `deliveryCancelled` is the sole cross-queue mutable value and is protected
/// by `deliveryLock`, keeping `@unchecked Sendable` explicit and local.
private nonisolated final class RepositoryEventsEngine: @unchecked Sendable {
    private static let attachmentRetryDelay = DispatchTimeInterval.milliseconds(250)
    private static let callback: FSEventStreamCallback = {
        _, info, count, paths, flags, _ in
        guard let info else { return }
        Unmanaged<RepositoryEventsEngine>.fromOpaque(info).takeUnretainedValue().receive(
            paths: paths,
            flags: flags,
            count: count
        )
    }

    private struct Targets {
        let root: String
        let dotGit: String
        let dotGitIsDirectory: Bool
        let gitDirectory: String?
        let commonDirectory: String?
        let watchPaths: [String]

        func concerns(_ path: String) -> Bool {
            invalidation(for: path, flags: 0) != nil
        }

        func invalidation(
            for path: String,
            flags: FSEventStreamEventFlags
        ) -> RepositoryEvents.Invalidation? {
            if RepositoryEvents.requiresRescan(flags) { return .metadata }

            if let gitDirectory {
                if path == gitDirectory { return .metadata }
                if path == Self.child("HEAD", of: gitDirectory) { return .metadata }
                if path == Self.child("index", of: gitDirectory) { return .metadata }
            }

            if let commonDirectory {
                let refs = Self.child("refs", of: commonDirectory)
                if path == refs || Self.isInside(path, directory: refs) { return .metadata }
                if path == Self.child("packed-refs", of: commonDirectory) { return .metadata }
            }

            if path == root { return .workingTree }
            guard Self.isInside(path, directory: root) else { return nil }
            if dotGitIsDirectory, (path == dotGit || Self.isInside(path, directory: dotGit)) {
                return nil
            }
            return .workingTree
        }

        func canChangeAttachment(_ path: String, flags: FSEventStreamEventFlags) -> Bool {
            if RepositoryEvents.requiresRescan(flags) { return true }
            if path == root || path == dotGit { return true }
            if let gitDirectory, path == gitDirectory { return true }
            if let commonDirectory, path == commonDirectory { return true }
            return false
        }

        private static func child(_ name: String, of directory: String) -> String {
            URL(filePath: directory, directoryHint: .isDirectory)
                .appending(path: name)
                .standardizedFileURL.path
        }

        private static func isInside(_ path: String, directory: String) -> Bool {
            path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
        }
    }

    private let root: URL
    private let invalidate: RepositoryEvents.Invalidate
    private let queue = DispatchQueue(label: "pasqualotto.baia.repository-events")
    private let deliveryLock = NSLock()
    private var stream: FSEventStreamRef?
    private var targets: Targets?
    private var stopped = false
    private var reconfigureScheduled = false
    private var retryWorkItem: DispatchWorkItem?
    private var deliveryCancelled = false

    init(root: URL, invalidate: @escaping RepositoryEvents.Invalidate) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.invalidate = invalidate
        try queue.sync { try startStream() }
    }

    func stop() {
        deliveryLock.lock()
        let shouldScheduleCleanup = !deliveryCancelled
        deliveryCancelled = true
        deliveryLock.unlock()
        guard shouldScheduleCleanup else { return }

        // This closure owns the engine until the stream has been stopped and
        // invalidated, even when RepositoryEvents itself is being released.
        queue.async { [self] in stopOnQueue() }
    }

    fileprivate func receive(
        paths: UnsafeMutableRawPointer,
        flags: UnsafePointer<FSEventStreamEventFlags>,
        count: Int
    ) {
        guard deliveryIsActive(), !stopped, let targets else { return }
        let pathPointers = paths.bindMemory(to: UnsafePointer<CChar>?.self, capacity: count)
        var reason: RepositoryEvents.Invalidation?
        var shouldReconfigure = false

        for index in 0 ..< count {
            let eventFlags = flags[index]
            if eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
                continue
            }
            guard let pointer = pathPointers[index] else { continue }
            let path = Self.canonicalEventPath(String(cString: pointer))
            if let eventReason = targets.invalidation(for: path, flags: eventFlags) {
                reason = reason?.merged(with: eventReason) ?? eventReason
            }
            if targets.canChangeAttachment(path, flags: eventFlags) {
                shouldReconfigure = true
            }
        }

        if let reason, deliveryIsActive() { invalidate(root, reason) }
        if shouldReconfigure { scheduleReconfigure() }
    }

    private func startStream() throws {
        let since = FSEventsGetCurrentEventId()
        let newTargets = resolveTargets()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagFileEvents
        )
        guard let newStream = FSEventStreamCreate(
            nil,
            Self.callback,
            &context,
            newTargets.watchPaths as CFArray,
            since,
            0.05,
            createFlags
        ) else {
            throw RepositoryEvents.StartError.streamCreationFailed
        }

        FSEventStreamSetDispatchQueue(newStream, queue)
        guard FSEventStreamStart(newStream) else {
            FSEventStreamInvalidate(newStream)
            throw RepositoryEvents.StartError.streamStartFailed
        }
        targets = newTargets
        stream = newStream
    }

    private func scheduleReconfigure() {
        guard !reconfigureScheduled, !stopped else { return }
        reconfigureScheduled = true
        queue.async { [weak self] in
            guard let self else { return }
            reconfigureScheduled = false
            guard !stopped else { return }
            tearDownStream()
            do {
                try startStream()
            } catch {
                // A failed attachment cannot make repository state trustworthy.
                // Repository reads remain owned by the observer core, while
                // this adapter retries only its failed filesystem attachment.
                if deliveryIsActive() { invalidate(root, .metadata) }
                scheduleAttachmentRetry()
            }
        }
    }

    private func scheduleAttachmentRetry() {
        guard !stopped, retryWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            retryWorkItem = nil
            guard !stopped else { return }
            do {
                try startStream()
            } catch {
                if deliveryIsActive() { invalidate(root, .metadata) }
                scheduleAttachmentRetry()
            }
        }
        retryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.attachmentRetryDelay, execute: workItem)
    }

    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        reconfigureScheduled = false
        retryWorkItem?.cancel()
        retryWorkItem = nil
        tearDownStream()
    }

    private func deliveryIsActive() -> Bool {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        return !deliveryCancelled
    }

    private func tearDownStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        self.stream = nil
        targets = nil
    }

    /// FSEvents can use a filesystem alias for a path after the item has been
    /// removed (for example `/private/var` instead of `/var`). Resolve the
    /// nearest surviving ancestor, then restore the missing path components so
    /// relevance checks continue to use the watched root's canonical spelling.
    private static func canonicalEventPath(_ spelling: String) -> String {
        var candidate = URL(filePath: spelling).standardizedFileURL
        var missingComponents: [String] = []

        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            missingComponents.append(candidate.lastPathComponent)
            candidate = parent
        }

        candidate = candidate.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            candidate.append(path: component)
        }
        return candidate.standardizedFileURL.path
    }

    private func resolveTargets() -> Targets {
        let rootPath = root.path
        let dotGitURL = root.appending(path: ".git")
        let dotGitPath = dotGitURL.standardizedFileURL.path
        var isDirectory = ObjCBool(false)
        let dotGitExists = FileManager.default.fileExists(atPath: dotGitPath, isDirectory: &isDirectory)

        let gitDirectoryURL: URL?
        if dotGitExists, isDirectory.boolValue {
            gitDirectoryURL = dotGitURL.standardizedFileURL.resolvingSymlinksInPath()
        } else if dotGitExists,
                  let text = try? String(contentsOf: dotGitURL, encoding: .utf8),
                  let spelling = Self.gitDirectorySpelling(in: text)
        {
            gitDirectoryURL = URL(
                filePath: spelling,
                relativeTo: URL(
                    filePath: dotGitURL.deletingLastPathComponent().path,
                    directoryHint: .isDirectory
                )
            ).standardizedFileURL.resolvingSymlinksInPath()
        } else {
            gitDirectoryURL = nil
        }

        let commonDirectoryURL = gitDirectoryURL.map(Self.commonDirectory(for:))
        let desired = [root, gitDirectoryURL, commonDirectoryURL].compactMap { $0 }
        let watchPaths = Array(Set(desired.map {
            Self.nearestExistingDirectory(to: $0).path
        })).sorted()
        return Targets(
            root: rootPath,
            dotGit: dotGitPath,
            dotGitIsDirectory: dotGitExists && isDirectory.boolValue,
            gitDirectory: gitDirectoryURL?.path,
            commonDirectory: commonDirectoryURL?.path,
            watchPaths: watchPaths
        )
    }

    private static func gitDirectorySpelling(in dotGit: String) -> String? {
        guard let firstLine = dotGit.split(whereSeparator: \Character.isNewline).first else { return nil }
        let pieces = firstLine.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2,
              pieces[0].trimmingCharacters(in: .whitespaces) == "gitdir"
        else {
            return nil
        }
        let spelling = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return spelling.isEmpty ? nil : spelling
    }

    private static func commonDirectory(for gitDirectory: URL) -> URL {
        let marker = gitDirectory.appending(path: "commondir")
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else {
            return gitDirectory
        }
        let spelling = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spelling.isEmpty else { return gitDirectory }
        return URL(
            filePath: spelling,
            relativeTo: URL(filePath: gitDirectory.path, directoryHint: .isDirectory)
        )
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private static func nearestExistingDirectory(to desired: URL) -> URL {
        var candidate = desired.standardizedFileURL
        var isDirectory = ObjCBool(false)
        while !FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
            || !isDirectory.boolValue
        {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return candidate }
            candidate = parent
        }
        return candidate.resolvingSymlinksInPath()
    }
}
