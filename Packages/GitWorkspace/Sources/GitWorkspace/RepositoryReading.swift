import Foundation

/// Why a typed repository read produced no answer.
///
/// One vocabulary for the status, the tree and the default branch, so the
/// observer can decide backoff and health without knowing which subcommand ran.
public enum RepositoryReadFailure: Error, Sendable, Equatable {
    /// git exited 128: the root is not a repository, or is not there.
    case notARepository
    /// The bounded subprocess reached its deadline.
    case timedOut
    /// The read was cancelled by its owner.
    case cancelled
    /// The subprocess produced more than the retained output limit.
    case tooMuchOutput
    /// git ran and its output could not be parsed.
    case unparseable
    /// Any other subprocess failure, carried as the subprocess reported it.
    case unavailable(SubprocessFailure)
}

/// The status and the changed paths, from one invocation.
public struct RepositoryStatusReading: Sendable, Equatable {
    public let status: RepositoryStatus
    public let changes: [RepositoryFileChange]

    public init(status: RepositoryStatus, changes: [RepositoryFileChange]) {
        self.status = status
        self.changes = changes
    }
}

public typealias RepositoryStatusRead = Result<RepositoryStatusReading, RepositoryReadFailure>

/// A successful tree read that found no files is `.success([])`, which is a
/// different fact from any failure and is what lets the observer store it.
public typealias RepositoryTreeRead = Result<[FileTreeNode], RepositoryReadFailure>

/// A successful read whose repository has no recorded default branch is
/// `.success(nil)`.
public typealias RepositoryDefaultBranchRead = Result<String?, RepositoryReadFailure>

/// What ``RepositoryObserver`` needs from a repository, and nothing else.
///
/// `GitCommand` is the production conformance. A test conforms with a scripted
/// reader so the observer's scheduling, generations and publication run for real
/// against reads whose timing the test controls.
///
/// Synchronous and blocking, like every read in this package. The observer calls
/// these from its own queue and never from the main actor. The URL is the
/// captured physical identity (``RepositoryRoot/processURL``), not a live alias
/// spelling: resolving at read time would follow a retargeted symlink into a
/// different repository.
public protocol RepositoryReading: Sendable {
    func readStatus(ofRepositoryRoot root: URL, cancellation: SubprocessCancellation) -> RepositoryStatusRead
    func readTree(ofRepositoryRoot root: URL, cancellation: SubprocessCancellation) -> RepositoryTreeRead
    func readDefaultBranch(ofRepositoryRoot root: URL, cancellation: SubprocessCancellation) -> RepositoryDefaultBranchRead
}

extension GitCommand: RepositoryReading {
    /// The status read as ``read(ofRepositoryRoot:)`` runs it, with every failure
    /// kept rather than folded into nil.
    public func readStatus(
        ofRepositoryRoot root: URL,
        cancellation: SubprocessCancellation
    ) -> RepositoryStatusRead {
        switch Self.failure(of: run(Self.statusArguments, in: root, cancellation: cancellation)) {
        case let .failure(failure):
            return .failure(failure)
        case let .success(output):
            guard var status = GitStatusParser.parse(output) else { return .failure(.unparseable) }
            if let gitDirectory = GitDirectory.url(forRepositoryRoot: root) {
                status.inProgress = InProgressProbe.detect(gitDirectory: gitDirectory)
            }
            return .success(RepositoryStatusReading(status: status, changes: GitStatusParser.changes(output)))
        }
    }

    /// The tree read as ``files(ofRepositoryRoot:)`` runs it. An empty repository
    /// answers `.success([])`; a directory that is not a repository answers
    /// `.failure(.notARepository)`, where the untyped wrapper answered `[]` for
    /// both and left the caller unable to store either.
    public func readTree(
        ofRepositoryRoot root: URL,
        cancellation: SubprocessCancellation
    ) -> RepositoryTreeRead {
        Self.failure(of: run(Self.treeArguments, in: root, cancellation: cancellation)).map { output in
            FileTree.build(paths: FileTree.paths(fromNulSeparated: output))
        }
    }

    /// The default branch as ``defaultBranch(ofRepositoryRoot:)`` reads it.
    public func readDefaultBranch(
        ofRepositoryRoot root: URL,
        cancellation: SubprocessCancellation
    ) -> RepositoryDefaultBranchRead {
        Self.failure(of: run(Self.defaultBranchArguments, in: root, cancellation: cancellation)).map { output in
            DefaultBranchParser.parse(String(decoding: output, as: UTF8.self))
        }
    }

    /// git's own exit code for "not a repository" and for a directory it cannot
    /// enter. Anything else non-zero is a repository that could not answer.
    private static let notARepositoryExit: Int32 = 128

    private static func failure(of outcome: SubprocessOutcome) -> Result<[UInt8], RepositoryReadFailure> {
        switch outcome {
        case let .completed(bytes):
            return .success(bytes)
        case .timedOut:
            return .failure(.timedOut)
        case .cancelled:
            return .failure(.cancelled)
        case .tooMuchOutput:
            return .failure(.tooMuchOutput)
        case let .failed(failure):
            if case let .exit(code) = failure, code == notARepositoryExit {
                return .failure(.notARepository)
            }
            return .failure(.unavailable(failure))
        }
    }
}
