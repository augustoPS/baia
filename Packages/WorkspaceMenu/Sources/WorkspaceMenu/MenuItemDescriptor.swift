import Foundation

/// One menu item, described rather than built.
public struct MenuItemDescriptor: Sendable, Equatable {
    public var command: MenuCommand
    public var title: String
    public var shortcut: MenuShortcut?
    public var policy: GhosttyPolicy

    /// True when a separator belongs immediately above this item.
    ///
    /// Carried on the item rather than as a `.separator` case in the item list,
    /// so every element of ``MenuDescriptor/items`` has a ``MenuCommand`` and
    /// the "every command appears exactly once" test can iterate the list
    /// without filtering. A separator case would also need a tag AppKit reads as
    /// 0, which ``MenuCommand/init(tag:)`` deliberately rejects.
    public var isSeparatorBefore: Bool

    public init(
        command: MenuCommand,
        title: String,
        shortcut: MenuShortcut?,
        policy: GhosttyPolicy,
        isSeparatorBefore: Bool
    ) {
        self.command = command
        self.title = title
        self.shortcut = shortcut
        self.policy = policy
        self.isSeparatorBefore = isSeparatorBefore
    }
}
