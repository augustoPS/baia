import Foundation

/// A key equivalent in the two spellings it has to satisfy at once: the scalar
/// AppKit matches on, and the name ghostty matches on.
///
/// Keeping one string for both is how a silent unbind ships. Ghostty spells the
/// arrows `arrow_left` and friends, not `left`; the brackets `[` and `]`, not
/// `left_bracket`; the comma `,`, not `comma`; and Return `enter`. A trigger
/// name ghostty does not recognise is not an error, it is a `keybind` line that
/// unbinds nothing, and the key then stays swallowed by the surface. The first
/// pass at this table used `super+shift+left_bracket` and read as correct.
public enum MenuKey: Sendable, Equatable {
    case character(Character)
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case returnKey
    case digit(Int)

    /// The scalar AppKit wants in `NSMenuItem.keyEquivalent`.
    ///
    /// The arrows are the private-use scalars 0xF700 to 0xF703 that back
    /// `NSUpArrowFunctionKey` and its siblings, hardcoded rather than referenced
    /// because this package must not import AppKit. That boundary is what keeps
    /// `make test` at about a second with no Metal, no linking, and no signing.
    public var appKitCharacter: String {
        switch self {
        case let .character(character): String(character)
        case .arrowUp: "\u{F700}"
        case .arrowDown: "\u{F701}"
        case .arrowLeft: "\u{F702}"
        case .arrowRight: "\u{F703}"
        // A carriage return, not "\n". AppKit matches Return on 0x0D, and a
        // newline in a key equivalent is accepted and never matches anything.
        case .returnKey: "\r"
        case let .digit(digit): String(digit)
        }
    }

    /// The ghostty trigger name or names for this key.
    ///
    /// A digit binds in *both* forms in ghostty's default table, `super+1` and
    /// `super+digit_1`, both to `goto_tab`. Unbinding one leaves the other live,
    /// so a digit returns two names and the caller emits two lines.
    ///
    /// Characters are lowercased. Ghostty compares the trigger string literally,
    /// so `super+shift+P` matches nothing while `super+shift+p` is the real
    /// default binding: the shift belongs in ``MenuModifiers``, never in the
    /// letter, and lowercasing here means a capitalised letter written by hand
    /// cannot quietly produce a dead unbind line.
    public var ghosttyNames: [String] {
        switch self {
        case let .character(character): [String(character).lowercased()]
        case .arrowUp: ["arrow_up"]
        case .arrowDown: ["arrow_down"]
        case .arrowLeft: ["arrow_left"]
        case .arrowRight: ["arrow_right"]
        case .returnKey: ["enter"]
        case let .digit(digit): ["\(digit)", "digit_\(digit)"]
        }
    }
}
