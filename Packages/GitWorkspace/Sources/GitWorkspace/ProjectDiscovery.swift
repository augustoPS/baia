import Foundation

/// Finds the projects under a set of roots.
///
/// Reaches `FileManager.default` inside the method bodies rather than storing
/// one, so this stays a plain `Sendable` instead of an `@unchecked` one. The
/// tests drive behaviour through `roots`, `maxDepth`, and `ignoredNames` against
/// real directory trees.
public struct ProjectDiscovery: Sendable {
    /// Directory names never walked into.
    ///
    /// Every entry is either a dependency store or a build output, and each one
    /// costs a walk that is orders of magnitude larger than the tree it hides:
    /// `node_modules` in one Astro site holds more directories than the whole
    /// rest of the workspace. `.git`, `.claude`, and `.worktrees` are listed even
    /// though hidden directories are skipped by name anyway, because the set is
    /// public and a caller passing its own should not have to rediscover them.
    public static let defaultIgnoredNames: Set<String> = [
        "node_modules",
        ".build",
        "DerivedData",
        ".git",
        ".claude",
        ".worktrees",
        "photos",
        "dist",
        ".next",
        ".astro",
        "Pods",
        ".venv",
        "__pycache__",
        ".swiftpm",
    ]

    private let roots: [URL]
    private let maxDepth: Int
    private let ignoredNames: Set<String>

    /// - Parameter maxDepth: how many levels below a root are examined. 1 looks
    ///   only at a root's own children, which finds `baia` and misses
    ///   `website/shop`. Nesting on this machine goes two deep in two places
    ///   (`website/*` and `skills/*`), so 2 is the shallowest useful value and a
    ///   larger one costs a walk of every project's source tree.
    public init(roots: [URL], maxDepth: Int, ignoredNames: Set<String>) {
        self.roots = roots
        self.maxDepth = maxDepth
        self.ignoredNames = ignoredNames
    }

    /// Walks the roots for repositories, then asks each repository for its
    /// worktrees.
    ///
    /// The closure is the whole reason the walk can stay cheap. Worktrees are
    /// full file copies living inside the repository (both
    /// `.worktrees/<branch>-MMDD-HHMM` and `.claude/worktrees/agent-<hex>` are in
    /// use here), so finding them by walking triples the tree and reports the same
    /// files twice. An admin vitest run once counted three times its real tests
    /// that way. git already knows their paths, so the walk finds repositories and
    /// git names their worktrees.
    public func discover(worktrees: (URL) -> [Worktree]) -> [Project] {
        var projects: [Project] = []
        var claimed: Set<String> = []

        for root in roots {
            let rootPath = Self.resolvedPath(root)

            // A root that is itself a repository is emitted rather than walked.
            // Pointing baia's own directory at this otherwise finds Packages and
            // Sources and never baia, which reads as discovery being broken
            // rather than as a misconfigured root.
            if Self.holdsGitEntry(rootPath) {
                append(
                    repository: root,
                    rootPath: rootPath,
                    worktrees: worktrees,
                    into: &projects,
                    claimed: &claimed
                )
                continue
            }

            for child in subdirectories(of: root) {
                let childPath = Self.normalized(child.path(percentEncoded: false))
                if Self.holdsGitEntry(childPath) {
                    append(
                        repository: child,
                        rootPath: rootPath,
                        worktrees: worktrees,
                        into: &projects,
                        claimed: &claimed
                    )
                    continue
                }

                let nested = repositories(under: child, remainingDepth: maxDepth - 1)
                for repository in nested {
                    append(
                        repository: repository,
                        rootPath: rootPath,
                        worktrees: worktrees,
                        into: &projects,
                        claimed: &claimed
                    )
                }

                // Whether a plain directory is a project cannot be decided
                // before the walk beneath it finishes, which is why this runs
                // after the loop. `lifetracker` holds no repository and is a
                // project the palette must offer; `website` holds four and is
                // not, because an entry for it would open the container while
                // looking like one of the sites.
                if nested.isEmpty {
                    append(
                        directory: child,
                        rootPath: rootPath,
                        into: &projects,
                        claimed: &claimed
                    )
                }
            }
        }
        return projects
    }

    /// Repository roots below `directory`, at most `remainingDepth` levels down.
    ///
    /// A repository is never descended into. Its own subdirectories are its
    /// contents, and a vendored checkout inside it belongs to it rather than
    /// standing beside it in the palette. Siblings keep being walked, which is
    /// the whole point: `website` is not a repository while all four sites under
    /// it are, so stopping the walk at the first hit would find one site and
    /// abandon the rest.
    private func repositories(under directory: URL, remainingDepth: Int) -> [URL] {
        guard remainingDepth >= 1 else { return [] }
        var found: [URL] = []
        for child in subdirectories(of: directory) {
            let path = Self.normalized(child.path(percentEncoded: false))
            if Self.holdsGitEntry(path) {
                found.append(child)
                continue
            }
            found.append(contentsOf: repositories(under: child, remainingDepth: remainingDepth - 1))
        }
        return found
    }

    /// The immediate subdirectories of `directory`, sorted by name.
    ///
    /// `contentsOfDirectory` is the obvious call and it throws, which this
    /// package has no channel for. The enumerator with
    /// `.skipsSubdirectoryDescendants` is the same shallow listing with an error
    /// handler instead, and returning true from that handler carries the walk
    /// past a directory the owner cannot read rather than abandoning the root
    /// that contains it.
    ///
    /// Sorted because the palette ranks these afterwards and ties fall back to
    /// input order. An unstable order makes two equally ranked projects trade
    /// places between keystrokes, so the selection jumps under the owner's
    /// fingers.
    private func subdirectories(of directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent

            // Hidden directories are never projects. This is what keeps the walk
            // out of `.claude/worktrees` and `.worktrees` even when a caller
            // passes an `ignoredNames` set that forgot them, and the cost is that
            // a repository with a dotted name is undiscoverable. The owner's
            // dotfiles repository is `claude-dotfiles`, not a dotted name, so
            // nothing on this machine pays it.
            if name.hasPrefix(".") { continue }
            if ignoredNames.contains(name) { continue }
            guard Self.isDirectory(url) else { continue }

            // Rebuilt from the parent rather than taken as the enumerator handed
            // it back. `FileManager` returns `/private/var/...` for a directory the
            // caller spelled `/var/...`, and every path in the result then belongs
            // to a different spelling of the tree than the configured root does, so
            // the relative path falls back to the absolute one for every project in
            // the palette.
            found.append(directory.appending(path: name, directoryHint: .isDirectory))
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Emits a repository and then every linked worktree git names for it.
    private func append(
        repository: URL,
        rootPath: String,
        worktrees: (URL) -> [Worktree],
        into projects: inout [Project],
        claimed: inout Set<String>
    ) {
        let name = repository.lastPathComponent
        let repositoryPath = Self.resolvedPath(repository)

        // A repository already claimed takes its worktrees with it. Two
        // overlapping roots (`~/Projects` and `~/Projects/website`) reach the
        // same repository twice, and asking git for the same worktree list again
        // is a process spawn per duplicate.
        guard insert(
            Project(
                url: repository,
                displayName: name,
                kind: .repository,
                relativePath: Self.relativePath(of: repository, underRootPath: rootPath)
            ),
            into: &projects,
            claimed: &claimed
        ) else { return }

        for tree in worktrees(repository) where !tree.isMain {
            // Paths are compared as well as `isMain` trusted. The first stanza of
            // a bare repository's `worktree list` is the bare directory rather
            // than a working tree, so a caller handing back a list that starts
            // elsewhere would otherwise duplicate the repository itself. Compared
            // after resolution, because git reports a worktree's resolved path
            // while the walk carries whatever spelling the root was configured
            // with.
            guard Self.resolvedPath(tree.url) != repositoryPath else { continue }

            insert(
                Project(
                    url: tree.url,
                    // Named after the repository it belongs to. The recorded pain
                    // point is that four concurrent panes carry no identity, and
                    // `agent-4f21` on its own says nothing about which project it
                    // is agentically rewriting.
                    displayName: "\(name)/\(tree.displayName)",
                    kind: .worktree(ofRepositoryNamed: name),
                    relativePath: Self.relativePath(of: tree.url, underRootPath: rootPath)
                ),
                into: &projects,
                claimed: &claimed
            )
        }
    }

    private func append(
        directory: URL,
        rootPath: String,
        into projects: inout [Project],
        claimed: inout Set<String>
    ) {
        insert(
            Project(
                url: directory,
                displayName: directory.lastPathComponent,
                kind: .directory,
                relativePath: Self.relativePath(of: directory, underRootPath: rootPath)
            ),
            into: &projects,
            claimed: &claimed
        )
    }

    /// Appends unless the path was already emitted. False when it was.
    @discardableResult
    private func insert(
        _ project: Project,
        into projects: inout [Project],
        claimed: inout Set<String>
    ) -> Bool {
        // Keyed on the resolved path, so a repository reached through two
        // differently spelled roots is one entry. Two roots where one is a symlink
        // into the other is the shape that produces it.
        guard claimed.insert(Self.resolvedPath(project.url)).inserted else { return false }
        projects.append(project)
        return true
    }

    /// `url`'s path with the root prefix removed.
    ///
    /// Both sides are resolved before the prefix arithmetic. git reports a
    /// worktree's resolved path while the configured root may be spelled through a
    /// symlink, which on macOS is the difference between `/var/folders/...` and
    /// `/private/var/...` for anything under the temporary directory. Comparing the
    /// raw spellings makes every worktree look as though it lives outside the root.
    ///
    /// Falls back to the whole path when the root really is not a prefix, because
    /// `git worktree add` accepts any destination. Blind prefix arithmetic would
    /// hand back a suffix of an unrelated path instead, which is worse than a long
    /// one: the palette would show `Projects/baia` for something living in /tmp.
    ///
    /// A root that is itself the project gets its last component, since the literal
    /// answer is the empty string and an unnamed palette row cannot be selected on
    /// purpose.
    private static func relativePath(of url: URL, underRootPath rootPath: String) -> String {
        let path = resolvedPath(url)
        if path == rootPath {
            return (path as NSString).lastPathComponent
        }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }

    /// A path with symlinks resolved and trailing slashes dropped, which is the
    /// only spelling two paths from different sources can be compared in.
    private static func resolvedPath(_ url: URL) -> String {
        normalized(url.resolvingSymlinksInPath().path(percentEncoded: false))
    }

    /// A repository root holds `.git` as either a directory (a normal clone) or a
    /// regular file (a linked worktree or a submodule, holding a `gitdir:`
    /// pointer). `fileExists` covers both in one call.
    private static func holdsGitEntry(_ directoryPath: String) -> Bool {
        FileManager.default.fileExists(atPath: directoryPath + "/.git")
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false),
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }

    /// Drops trailing slashes so prefix comparisons and equality behave. Leaves
    /// "/" alone.
    private static func normalized(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
