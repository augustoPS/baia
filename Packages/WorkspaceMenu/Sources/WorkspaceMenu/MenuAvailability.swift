import Foundation

/// What the app can currently do, so validating a menu item is a pure function
/// of state instead of a chain of optional reads against live controllers.
///
/// The app target builds one of these when AppKit asks it to validate, which is
/// once per menu open. `AppDelegate.validateMenuItem` reads
/// `pane?.anchorTracker.isPinned ?? false` inline today, and every new rule
/// added there is a branch no test can reach without a window on screen.
///
/// Every field defaults to the value it has with nothing open, so a test names
/// only the fields its rule depends on. That is deliberate rather than
/// convenience: a rule that reads a field the test did not set is evaluated
/// against zero and fails loudly, instead of passing on a plausible-looking
/// default somebody chose for it.
public struct MenuAvailability: Sendable, Equatable {
    public var paneCount: Int
    public var tabCount: Int
    public var isPinned: Bool
    public var hasAnchor: Bool

    /// True when the anchor is a git repository root or a linked worktree, which
    /// is `Anchor.Kind.repository`. Separate from ``hasAnchor`` because a plain
    /// anchor exists and has no git state at all.
    public var anchorIsRepository: Bool

    public var isZoomed: Bool

    /// False until the project list has been read at least once. The palette
    /// with nothing in it is worse than a disabled item, because it looks like
    /// the workspace holds no projects.
    public var paletteAvailable: Bool

    public init(
        paneCount: Int = 0,
        tabCount: Int = 0,
        isPinned: Bool = false,
        hasAnchor: Bool = false,
        anchorIsRepository: Bool = false,
        isZoomed: Bool = false,
        paletteAvailable: Bool = false
    ) {
        self.paneCount = paneCount
        self.tabCount = tabCount
        self.isPinned = isPinned
        self.hasAnchor = hasAnchor
        self.anchorIsRepository = anchorIsRepository
        self.isZoomed = isZoomed
        self.paletteAvailable = paletteAvailable
    }

    /// Nothing open. Reachable in the real app between the last window closing
    /// and `applicationShouldTerminateAfterLastWindowClosed` taking effect, and
    /// it is what the menu bar shows if a window fails to open at all.
    public static let empty = MenuAvailability()
}
