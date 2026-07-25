import Foundation

/// One top-level menu and its items.
public struct MenuDescriptor: Sendable, Equatable {
    /// Which AppKit slot the menu occupies.
    ///
    /// AppKit treats four menus specially: the first one takes its title from
    /// the bundle and ignores the one given here, and `windowsMenu`,
    /// `servicesMenu` and `helpMenu` have to be assigned on `NSApplication` or
    /// the system does not populate them. Window tabs and the Help search field
    /// then appear in whichever menu AppKit guessed, or nowhere. Carrying the
    /// slot as data keeps that assignment out of a title comparison in the app
    /// target.
    public enum Role: Sendable, Equatable {
        case app
        case standard
        case windows

        /// No menu declares this yet. The Services menu holds no items of baia's
        /// own, so it is a role with an empty item list rather than something
        /// this layout can describe by listing commands.
        case services

        case help
    }

    public var title: String
    public var role: Role
    public var items: [MenuItemDescriptor]

    public init(title: String, role: Role, items: [MenuItemDescriptor]) {
        self.title = title
        self.role = role
        self.items = items
    }
}
