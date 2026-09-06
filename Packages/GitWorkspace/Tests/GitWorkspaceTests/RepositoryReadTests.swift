import Foundation
import Testing

@testable import GitWorkspace

/// The typed reads `GitCommand` offers the observer, against real repositories.
///
/// The untyped wrappers answer nil or `[]` for every failure. These keep the
/// failure, which is what lets an empty repository be stored as empty and a
/// missing one be reported as gone.
@Suite final class RepositoryReadTests {
    let fixture: DirectoryFixture
    let git = GitCommand()

    init() throws {
        fixture = try DirectoryFixture()
    }

    @discardableResult
    private func run(_ arguments: [String], in path: String) -> String? {
        git.output(
            of: [
                "-c", "user.name=baia",
                "-c", "user.email=baia@example.invalid",
                "-c", "commit.gpgsign=false",
                "-c", "init.defaultBranch=main",
            ] + arguments,
            in: fixture.root.appending(path: path)
        )
    }

    private func repository(_ path: String) throws -> URL {
        let root = try fixture.directory(path)
        run(["init", "--quiet"], in: path)
        try fixture.file("\(path)/c.txt", contents: "base\n")
        run(["add", "-A"], in: path)
        run(["commit", "--quiet", "--no-verify", "-m", "base"], in: path)
        return root
    }

    @Test func aStatusReadCarriesTheStatusAndTheChanges() throws {
        let root = try repository("proj")
        try fixture.file("proj/dirty.txt", contents: "x\n")

        let read = try git.readStatus(ofRepositoryRoot: root, cancellation: SubprocessCancellation()).get()

        #expect(read.status.head == .branch("main"))
        #expect(read.status.untracked == 1)
        #expect(read.changes.map(\.path) == ["dirty.txt"])
    }

    @Test func aDirectoryThatIsNotARepositoryIsNotARepository() throws {
        let plain = try fixture.directory("notes")

        #expect(git.readStatus(ofRepositoryRoot: plain, cancellation: SubprocessCancellation()) == .failure(.notARepository))
        #expect(git.readTree(ofRepositoryRoot: plain, cancellation: SubprocessCancellation()) == .failure(.notARepository))
    }

    @Test func aMissingDirectoryIsNotARepositoryEither() {
        let gone = fixture.root.appending(path: "gone")

        #expect(git.readStatus(ofRepositoryRoot: gone, cancellation: SubprocessCancellation()) == .failure(.notARepository))
    }

    /// The distinction the untyped `files` could not make.
    @Test func anEmptyRepositoryReadsAsAnEmptyTreeNotAFailure() throws {
        let empty = try fixture.directory("empty")
        run(["init", "--quiet"], in: "empty")

        #expect(git.readTree(ofRepositoryRoot: empty, cancellation: SubprocessCancellation()) == .success([]))
    }

    @Test func aPopulatedRepositoryReadsItsTree() throws {
        let root = try repository("proj")
        try fixture.file("proj/Sources/app.swift", contents: "")

        let tree = try git.readTree(ofRepositoryRoot: root, cancellation: SubprocessCancellation()).get()

        #expect(tree.map(\.name).sorted() == ["Sources", "c.txt"])
    }

    @Test func aLocalOnlyRepositoryHasNoRecordedDefaultBranch() throws {
        let root = try repository("proj")

        #expect(git.readDefaultBranch(ofRepositoryRoot: root, cancellation: SubprocessCancellation()) == .success(nil))
    }

    /// Typed reads take the captured physical identity. Passing the alias
    /// spelling after it is deleted is a missing directory; the process URL
    /// still names the repository.
    @Test func aDeletedAliasStillReadsThroughTheCapturedProcessURL() throws {
        let physical = try repository("proj")
        try fixture.file("proj/physical-only.txt", contents: "p\n")
        run(["add", "-A"], in: "proj")
        run(["commit", "--quiet", "--no-verify", "-m", "physical"], in: "proj")
        let link = fixture.root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: physical)
        let viaLink = RepositoryRoot(link)

        try FileManager.default.removeItem(at: link)

        let status = try git.readStatus(ofRepositoryRoot: viaLink.processURL, cancellation: SubprocessCancellation()).get()
        let tree = try git.readTree(ofRepositoryRoot: viaLink.processURL, cancellation: SubprocessCancellation()).get()
        #expect(status.status.head == .branch("main"))
        #expect(tree.map(\.name).contains("physical-only.txt"))
        #expect(git.readStatus(ofRepositoryRoot: viaLink.url, cancellation: SubprocessCancellation()) == .failure(.notARepository))
        #expect(viaLink.path == link.path(percentEncoded: false))
    }

    /// Retargeting the alias at another repository must not change what the
    /// captured process URL reads. That is the poisoning case: `git -C` on the
    /// live spelling would answer for the new repository.
    @Test func aRetargetedAliasStillReadsTheOriginalRepositoryThroughTheProcessURL() throws {
        let original = try repository("original")
        try fixture.file("original/from-original.txt", contents: "a\n")
        run(["add", "-A"], in: "original")
        run(["commit", "--quiet", "--no-verify", "-m", "original"], in: "original")
        let other = try repository("other")
        try fixture.file("other/from-other.txt", contents: "b\n")
        run(["add", "-A"], in: "other")
        run(["commit", "--quiet", "--no-verify", "-m", "other"], in: "other")
        let link = fixture.root.appending(path: "moving")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let viaLink = RepositoryRoot(link)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)

        let tree = try git.readTree(ofRepositoryRoot: viaLink.processURL, cancellation: SubprocessCancellation()).get()
        let poisoned = try git.readTree(ofRepositoryRoot: viaLink.url, cancellation: SubprocessCancellation()).get()
        #expect(tree.map(\.name).contains("from-original.txt"))
        #expect(!tree.map(\.name).contains("from-other.txt"))
        #expect(poisoned.map(\.name).contains("from-other.txt"))
        #expect(viaLink.path == link.path(percentEncoded: false))
    }

    @Test func aCancelledReadIsCancelled() throws {
        let root = try repository("proj")
        let cancellation = SubprocessCancellation()
        cancellation.cancel()

        #expect(git.readStatus(ofRepositoryRoot: root, cancellation: cancellation) == .failure(.cancelled))
    }

    @Test func aTimedOutReadIsTimedOut() throws {
        let root = try repository("proj")
        let slow = GitCommand(limits: SubprocessLimits(deadline: 0, outputLimit: 1 << 20, terminationGrace: 0.05))

        #expect(slow.readTree(ofRepositoryRoot: root, cancellation: SubprocessCancellation()) == .failure(.timedOut))
    }
}
