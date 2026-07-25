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

    public init(isEnabled: Bool, isChecked: Bool?) {
        self.isEnabled = isEnabled
        self.isChecked = isChecked
    }
}
