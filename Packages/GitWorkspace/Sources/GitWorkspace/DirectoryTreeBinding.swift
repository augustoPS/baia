import Foundation

/// One displayed plain directory tree, loaded away from the main actor.
///
/// Changing roots clears `nodes` synchronously, then starts a bounded listing.
/// Every request carries a generation, so a slow result for a root the surface
/// has left is discarded. Repeated refreshes also converge on the newest root:
/// they update one queued operation before entry or retain one pending listing
/// behind an entered syscall.
@MainActor
public final class DirectoryTreeBinding {
    public var onChange: (([FileTreeNode]) -> Void)?

    public private(set) var nodes: [FileTreeNode] = []
    public private(set) var root: URL?

    private let task: LatestFilesystemTask<URL, [FileTreeNode]>
    private var generation: UInt64 = 0
    private var hasRequestedRoot = false

    public init(
        executor: FilesystemExecutor = .shared,
        list: @escaping @Sendable (URL) -> [FileTreeNode] = { DirectoryTree.tree(at: $0) }
    ) {
        task = LatestFilesystemTask(executor: executor, operation: list)
    }

    deinit {
        task.cancelPending()
    }

    /// Re-reads `root`. A different root clears the previous display before
    /// this method returns; nil only clears and cancels pending work.
    public func refresh(_ root: URL?) {
        let root = root.map {
            URL(filePath: $0.path(percentEncoded: false), directoryHint: .isDirectory)
        }
        let path = root?.path(percentEncoded: false)
        let previousPath = self.root?.path(percentEncoded: false)
        let rootChanged = !hasRequestedRoot || path != previousPath

        hasRequestedRoot = true
        self.root = root
        generation &+= 1
        let requestedGeneration = generation
        // A replacement root updates the task's existing queued or pending
        // payload. Only a clear has no replacement and must cancel it.
        if root == nil {
            task.cancelPending()
        }

        if rootChanged {
            nodes = []
            onChange?(nodes)
        }

        // `onChange` is synchronous and may repoint this binding. Do not let
        // the outer call submit after a nested refresh has become authoritative.
        guard generation == requestedGeneration,
              self.root?.path(percentEncoded: false) == path
        else { return }
        guard let root else { return }
        task.submit(root) { [weak self] nodes in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == requestedGeneration,
                          self.root?.path(percentEncoded: false) == path
                    else { return }
                    self.nodes = nodes
                    self.onChange?(nodes)
                }
            }
        }
    }
}
