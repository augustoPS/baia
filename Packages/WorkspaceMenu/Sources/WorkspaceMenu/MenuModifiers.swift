import Foundation

/// The modifiers a shortcut carries.
///
/// An `OptionSet` over an `Int` rather than a mirror of
/// `NSEvent.ModifierFlags`, because this package must not import AppKit. The app
/// target translates ``rawValue`` bit by bit at the boundary.
public struct MenuModifiers: OptionSet, Sendable, Equatable {
    public static let command = MenuModifiers(rawValue: 1 << 0)
    public static let control = MenuModifiers(rawValue: 1 << 1)
    public static let option = MenuModifiers(rawValue: 1 << 2)
    public static let shift = MenuModifiers(rawValue: 1 << 3)

    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Always `super+ctrl+alt+shift` in that fixed order, with no trailing
    /// separator.
    ///
    /// The order is not cosmetic. Ghostty compares the whole trigger string
    /// literally, so `alt+super+w` is a different trigger from `super+alt+w` and
    /// matches none of its defaults. A reordered prefix produces an unbind line
    /// that parses cleanly and takes nothing away.
    ///
    /// Empty for a shortcut with no modifiers, which is why
    /// ``MenuShortcut/ghosttyTriggers`` joins conditionally instead of always
    /// appending a `+`.
    public var ghosttyPrefix: String {
        var parts: [String] = []
        if contains(.command) { parts.append("super") }
        if contains(.control) { parts.append("ctrl") }
        if contains(.option) { parts.append("alt") }
        if contains(.shift) { parts.append("shift") }
        return parts.joined(separator: "+")
    }
}
