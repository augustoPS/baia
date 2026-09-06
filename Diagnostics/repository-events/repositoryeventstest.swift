import CoreServices
import Foundation

nonisolated final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [UInt64] = []
    private var reasons: [RepositoryEvents.Invalidation] = []
    private(set) var expectedRoot: URL
    private var wrongRoots: [URL] = []

    init(expectedRoot: URL) {
        self.expectedRoot = expectedRoot
    }

    func record(_ root: URL, _ reason: RepositoryEvents.Invalidation) {
        lock.lock()
        if root != expectedRoot { wrongRoots.append(root) }
        times.append(DispatchTime.now().uptimeNanoseconds)
        reasons.append(reason)
        lock.unlock()
    }

    func snapshot() -> (times: [UInt64], reasons: [RepositoryEvents.Invalidation], wrongRoots: [URL]) {
        lock.lock()
        defer { lock.unlock() }
        return (times, reasons, wrongRoots)
    }
}

enum FixtureError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): message
        }
    }
}

@main
@MainActor
enum RepositoryEventsFixture {
    private static let fileManager = FileManager.default
    private static var latenciesMS: [Double] = []

    static func main() throws {
        let scratchRoot = fileManager.temporaryDirectory
            .appending(path: "baia-repository-events-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratchRoot) }

        let main = scratchRoot.appending(path: "main", directoryHint: .isDirectory)
        let linked = scratchRoot.appending(path: "linked", directoryHint: .isDirectory)
        try git(["init", main.path])
        try git(["-C", main.path, "config", "user.email", "fixture@example.invalid"])
        try git(["-C", main.path, "config", "user.name", "Repository Events Fixture"])
        try Data("base\n".utf8).write(to: main.appending(path: "tracked.txt"))
        try git(["-C", main.path, "add", "tracked.txt"])
        try git(["-C", main.path, "commit", "-m", "base"])
        try git(["-C", main.path, "worktree", "add", "-b", "linked-fixture", linked.path, "HEAD"])

        let linkedGitDir = try resolvedGitDirectory(for: linked)
        let commonGitDir = try commonGitDirectory(for: linkedGitDir)
        let linkedIndex = linkedGitDir.appending(path: "index")
        let linkedIndexBytes = try Data(contentsOf: linkedIndex)
        let mainIndex = main.appending(path: ".git/index")
        let mainIndexBytes = try Data(contentsOf: mainIndex)
        let canonicalLinked = linked.standardizedFileURL.resolvingSymlinksInPath()
        let recorder = EventRecorder(expectedRoot: canonicalLinked)
        let watcher = try RepositoryEvents(root: linked) { root, reason in
            recorder.record(root, reason)
        }

        try expectEvent("nested create", recorder: recorder, reason: .workingTree) {
            let nested = linked.appending(path: "a/b", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data("one\n".utf8).write(to: nested.appending(path: "one.txt"))
        }
        try expectEvent("nested rename", recorder: recorder, reason: .workingTree) {
            try fileManager.moveItem(
                at: linked.appending(path: "a/b/one.txt"),
                to: linked.appending(path: "a/b/two.txt")
            )
        }
        try expectEvent("nested delete", recorder: recorder, reason: .workingTree) {
            try fileManager.removeItem(at: linked.appending(path: "a"))
        }

        try Data("changed\n".utf8).write(to: linked.appending(path: "tracked.txt"))
        settle(recorder)
        try expectEvent("linked worktree index", recorder: recorder, reason: .metadata) {
            try linkedIndexBytes.write(to: linkedIndex, options: .atomic)
        }

        let head = linkedGitDir.appending(path: "HEAD")
        let headBytes = try Data(contentsOf: head)
        try expectEvent("linked worktree HEAD", recorder: recorder, reason: .metadata) {
            try headBytes.write(to: head, options: .atomic)
        }

        try expectEvent("common refs", recorder: recorder, reason: .metadata) {
            let sourceRef = try currentRef(in: commonGitDir)
            let refBytes = try Data(contentsOf: sourceRef)
            try refBytes.write(
                to: commonGitDir.appending(path: "refs/heads/event-fixture"),
                options: .atomic
            )
        }

        settle(recorder)
        let beforeMainIndex = recorder.snapshot().times.count
        try mainIndexBytes.write(to: mainIndex, options: .atomic)
        Thread.sleep(forTimeInterval: 0.6)
        let afterMainIndex = recorder.snapshot().times.count
        try require(
            afterMainIndex == beforeMainIndex,
            "linked watcher invalidated for the main worktree index"
        )
        print("ok    main worktree index stays outside linked invalidation")

        let gitFileBytes = try Data(contentsOf: linked.appending(path: ".git"))
        let parked = scratchRoot.appending(path: "linked-parked", directoryHint: .isDirectory)
        try expectEvent("watched root deletion", recorder: recorder, reason: .metadata) {
            try fileManager.moveItem(at: linked, to: parked)
        }
        settle(recorder)
        try expectEvent("watched root recreation", recorder: recorder) {
            try fileManager.createDirectory(at: linked, withIntermediateDirectories: true)
            try gitFileBytes.write(to: linked.appending(path: ".git"))
        }
        settle(recorder)
        try expectEvent("event after watcher reattachment", recorder: recorder, reason: .workingTree) {
            try Data("reattached\n".utf8).write(to: linked.appending(path: "reattached.txt"))
        }

        let rescanFlags: [FSEventStreamEventFlags] = [
            FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
            FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped),
            FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped),
            FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped),
            FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged),
        ]
        for flags in rescanFlags {
            try require(
                RepositoryEvents.requiresRescan(flags),
                "event flag \(flags) did not require rescan"
            )
        }
        print("ok    dropped and root-change flags require rescan")

        watcher.stop()
        watcher.stop()
        settle(recorder)
        let beforeStopMutation = recorder.snapshot().times.count
        try Data("stopped\n".utf8).write(to: linked.appending(path: "after-stop.txt"))
        Thread.sleep(forTimeInterval: 0.6)
        let stoppedSnapshot = recorder.snapshot()
        try require(
            stoppedSnapshot.times.count == beforeStopMutation,
            "callback arrived after stop"
        )
        try require(stoppedSnapshot.wrongRoots.isEmpty, "callback carried a noncanonical root")
        print("ok    stop is idempotent and suppresses later callbacks")

        let releaseRecorder = EventRecorder(expectedRoot: canonicalLinked)
        var releasedWatcher: RepositoryEvents? = try RepositoryEvents(root: linked) { root, reason in
            releaseRecorder.record(root, reason)
        }
        try require(releasedWatcher != nil, "release watcher did not start")
        settle(releaseRecorder)
        releasedWatcher = nil
        settle(releaseRecorder)
        let beforeReleaseMutation = releaseRecorder.snapshot().times.count
        try Data("released\n".utf8).write(to: linked.appending(path: "after-release.txt"))
        Thread.sleep(forTimeInterval: 0.6)
        try require(
            releaseRecorder.snapshot().times.count == beforeReleaseMutation,
            "callback arrived after watcher release"
        )
        print("ok    release tears down delivery and suppresses later callbacks")

        let ordered = latenciesMS.sorted()
        let median = ordered[ordered.count / 2]
        print(String(
            format: "PASS repository events: %d measured arms, min %.1f ms, median %.1f ms, max %.1f ms",
            ordered.count,
            ordered.first!,
            median,
            ordered.last!
        ))
    }

    private static func expectEvent(
        _ name: String,
        recorder: EventRecorder,
        reason expectedReason: RepositoryEvents.Invalidation? = nil,
        operation: () throws -> Void
    ) throws {
        trace("waiting for \(name)")
        settle(recorder)
        let before = recorder.snapshot().times.count
        let started = DispatchTime.now().uptimeNanoseconds
        try operation()
        let deadline = started + 5_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let snap = recorder.snapshot()
            if snap.times.count > before {
                let latency = Double(snap.times[before] - started) / 1_000_000
                if let expectedReason {
                    let got = snap.reasons[before]
                    try require(
                        got == expectedReason,
                        "\(name) invalidated as \(got), expected \(expectedReason)"
                    )
                }
                latenciesMS.append(latency)
                print(String(format: "ok    %@ invalidated in %.1f ms", name, latency))
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw FixtureError.failed("\(name) produced no invalidation within the fixture's 5 s bound")
    }

    private static func settle(_ recorder: EventRecorder) {
        var count = recorder.snapshot().times.count
        var quietSince = DispatchTime.now().uptimeNanoseconds
        let deadline = quietSince + 2_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            let next = recorder.snapshot().times.count
            if next != count {
                count = next
                quietSince = DispatchTime.now().uptimeNanoseconds
            }
            if DispatchTime.now().uptimeNanoseconds - quietSince >= 150_000_000 { return }
        }
    }

    private static func resolvedGitDirectory(for root: URL) throws -> URL {
        let dotGit = root.appending(path: ".git")
        let text = try String(contentsOf: dotGit, encoding: .utf8)
        guard text.hasPrefix("gitdir:") else {
            throw FixtureError.failed("linked worktree .git is not a gitdir file")
        }
        let spelling = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(
            filePath: spelling,
            relativeTo: URL(
                filePath: dotGit.deletingLastPathComponent().path,
                directoryHint: .isDirectory
            )
        )
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func commonGitDirectory(for gitDirectory: URL) throws -> URL {
        let spelling = try String(
            contentsOf: gitDirectory.appending(path: "commondir"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(
            filePath: spelling,
            relativeTo: URL(filePath: gitDirectory.path, directoryHint: .isDirectory)
        )
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private static func currentRef(in commonGitDirectory: URL) throws -> URL {
        let head = try String(
            contentsOf: commonGitDirectory.appending(path: "HEAD"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.hasPrefix("ref: ") else {
            throw FixtureError.failed("main worktree HEAD is detached")
        }
        return commonGitDirectory.appending(path: String(head.dropFirst("ref: ".count)))
    }

    private static func git(_ arguments: [String]) throws {
        trace("git \(arguments.joined(separator: " "))")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError.failed(
                "git \(arguments.joined(separator: " ")) exited \(process.terminationStatus)"
            )
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw FixtureError.failed(message) }
    }

    private static func trace(_ message: String) {
        FileHandle.standardError.write(Data("fixture: \(message)\n".utf8))
    }
}
