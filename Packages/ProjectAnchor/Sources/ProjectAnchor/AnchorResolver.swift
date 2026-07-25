import Foundation

/// Turns a working directory and an optional pin into an ``Anchor``.
public struct AnchorResolver: Sendable {
    /// What the resolver decided, plus whether the pin it was handed should be
    /// discarded. The caller owns pin storage, so it needs telling.
    public struct Resolution: Equatable, Sendable {
        public let anchor: Anchor?
        /// True when a pin was supplied but is no longer a usable directory.
        public let pinIsStale: Bool

        public init(anchor: Anchor?, pinIsStale: Bool) {
            self.anchor = anchor
            self.pinIsStale = pinIsStale
        }
    }

    private let locator: GitRepositoryLocator

    public init(locator: GitRepositoryLocator = .init()) {
        self.locator = locator
    }

    public func resolve(workingDirectory: URL?, pin: URL?) -> Resolution {
        guard let pin else {
            return Resolution(anchor: automatic(workingDirectory), pinIsStale: false)
        }
        guard isDirectory(pin) else {
            return Resolution(anchor: automatic(workingDirectory), pinIsStale: true)
        }
        // A pin is the anchor verbatim, not a starting point for a walk. It
        // reports as a repository only when it is one itself.
        let kind: Anchor.Kind = locator.isRepositoryRoot(pin) ? .repository : .plain
        return Resolution(
            anchor: Anchor(url: pin, kind: kind, source: .pinned),
            pinIsStale: false
        )
    }

    /// Repository root when there is one, otherwise the working directory. Never
    /// nil for a non-nil input, so a future file tree always has a root.
    private func automatic(_ workingDirectory: URL?) -> Anchor? {
        guard let workingDirectory else { return nil }
        if let root = locator.repositoryRoot(containing: workingDirectory) {
            return Anchor(url: root, kind: .repository, source: .automatic)
        }
        return Anchor(url: workingDirectory, kind: .plain, source: .automatic)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false),
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }
}
