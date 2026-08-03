import Foundation

/// How one menu item should appear right now.
public struct MenuItemState: Sendable, Equatable {
    public var isEnabled: Bool

    /// Nil when the item is not a checkable item at all, which is a different
    /// thing from unchecked. Collapsing the two to `false` would make the app
    /// target write `.off` onto every plain item, and `NSMenuItem.state` is
    /// already `.off`, so the bug would be invisible until a checkable item was
    /// added and forgotten.
    public var isChecked: Bool?

    /// Why the item is disabled, phrased as what is missing: `needs 2 panes`.
    ///
    /// Nil whenever ``isEnabled`` is true, and nil is also the honest answer for
    /// a command disabled by something the owner cannot act on. The menu ignores
    /// this and greys the item out; the command palette draws it, because a
    /// palette has nowhere to show a disabled row's tooltip and an absent verb
    /// reads exactly like a mistyped one.
    ///
    /// Phrased as the requirement rather than the failure (`needs 2 panes`, not
    /// `only one pane`), so the reader is told what to do rather than what went
    /// wrong.
    public var unavailableReason: String?

    public init(isEnabled: Bool, isChecked: Bool?, unavailableReason: String? = nil) {
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        // An enabled item has nothing to explain, and letting a reason ride along
        // with one would put a requirement on screen beside a verb that already
        // meets it.
        self.unavailableReason = isEnabled ? nil : unavailableReason
    }
}
