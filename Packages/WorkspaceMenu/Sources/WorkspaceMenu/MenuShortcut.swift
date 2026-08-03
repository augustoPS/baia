import Foundation

/// One key equivalent: what AppKit installs on the item, and what ghostty has to
/// be told to let go of.
public struct MenuShortcut: Sendable, Equatable {
    public var key: MenuKey
    public var modifiers: MenuModifiers

    public init(key: MenuKey, modifiers: MenuModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// The shortcut as a menu draws it, `⌃⌘=`.
    ///
    /// Upper-cased for a letter, because that is what a menu shows: ⌘D rather
    /// than ⌘d. The shift glyph is not implied by the case, it comes from the
    /// modifiers, so ⇧ appears only when the shortcut really carries it.
    public var displayText: String {
        modifiers.displayText + key.displayText
    }

    /// Every ghostty trigger string this shortcut corresponds to. More than one
    /// only for a digit, which ghostty's defaults bind twice.
    public var ghosttyTriggers: [String] {
        let prefix = modifiers.ghosttyPrefix
        // Joined conditionally rather than with a fixed `prefix + "+"`. A
        // shortcut with no modifiers would otherwise come out as "+enter", which
        // ghostty rejects while the unbind line still looks plausible in a diff.
        return key.ghosttyNames.map { prefix.isEmpty ? $0 : prefix + "+" + $0 }
    }
}
