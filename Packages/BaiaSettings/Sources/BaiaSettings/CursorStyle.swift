import Foundation

/// The cursor shape a pane draws.
///
/// The raw values are ghostty's own `cursor-style` spellings, because
/// ``Settings/terminalOverrides`` sends `rawValue` straight into the terminal
/// config. Renaming a case therefore changes the config text baia writes, and a
/// key ghostty cannot parse is dropped with no diagnostic, so the setting looks
/// applied and does nothing. `CursorStyleTests` pins the three spellings for
/// that reason.
///
/// ghostty also accepts `block_hollow`, which is deliberately absent: an unfilled
/// block reads as an unfocused pane, and baia uses unfocused chrome for that.
public enum CursorStyle: String, Sendable, Equatable, CaseIterable {
    case block
    case bar
    case underline
}
