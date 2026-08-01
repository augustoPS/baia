@testable import WorkspaceLayout

/// The identity answer to `SessionStore.reconciled`'s `resolveAnchor`: a pane is
/// anchored at its pin, or at its own working directory when it has none.
///
/// What the real resolver does minus the walk. `ProjectAnchor` climbs from the
/// working directory to the repository root, and this package depends on nothing,
/// so the walk is the caller's to supply and this is the stand-in for every test
/// whose subject is focus repair, dropped panes, or a round trip through the file.
///
/// **A test about the walk must not use this**, which is the point of giving it a
/// name rather than writing the closure inline twenty times: the defect it exists
/// to make visible is a fixture whose working directory happens to equal its
/// anchor, and that is exactly what this is.
///
/// A function rather than a `let` holding a closure, which the compiler refuses at
/// file scope: a global closure is shared mutable state as far as concurrency
/// checking is concerned, and these suites run in parallel.
func anchoredAtItsOwnDirectory(_ pane: PaneState) -> String? {
    pane.pinnedDirectory ?? pane.workingDirectory
}
