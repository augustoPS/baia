import Foundation

/// Ghostty's default keybind table, transcribed, plus the unbind lines baia
/// derives from it.
///
/// Transcribed from the real output of
/// `/Applications/Ghostty.app/Contents/MacOS/ghostty +list-keybinds --default`
/// on this machine, 93 lines, parsed rather than read off a prose list. Every
/// earlier hand-written list of "free" keys was wrong, because ghostty's names
/// are not the obvious ones: the arrows are `arrow_left` and not `left`, the
/// brackets are `[` and `]` and not `left_bracket`, the comma is `,` and not
/// `comma`, Return is `enter`, and every digit is bound twice, as `super+1` and
/// as `super+digit_1`.
///
/// ``ghosttyVersion`` has to match the `libghostty-spm` pin in
/// `Package.resolved`, because the app enforces the embedded library's table
/// while this one was read out of the standalone app. They agree at 1.3.1. When
/// the pin moves, re-run the command and re-transcribe: a drifted table turns a
/// real conflict into a ``GhosttyPolicy/noConflict`` that no test can catch, and
/// the key then silently does nothing.
public enum GhosttyDefaultKeybinds {
    public static let ghosttyVersion = "1.3.1"

    /// Every trigger ghostty binds by default, at ``ghosttyVersion``.
    public static let triggers: Set<String> = [
        "alt+arrow_left",
        "alt+arrow_right",
        "copy",
        "ctrl+shift+tab",
        "ctrl+tab",
        "escape",
        "paste",
        "shift+arrow_down",
        "shift+arrow_left",
        "shift+arrow_right",
        "shift+arrow_up",
        "shift+end",
        "shift+home",
        "shift+page_down",
        "shift+page_up",
        "super++",
        "super+,",
        "super+-",
        "super+0",
        "super+1",
        "super+2",
        "super+3",
        "super+4",
        "super+5",
        "super+6",
        "super+7",
        "super+8",
        "super+9",
        "super+=",
        "super+[",
        "super+]",
        "super+a",
        "super+alt+arrow_down",
        "super+alt+arrow_left",
        "super+alt+arrow_right",
        "super+alt+arrow_up",
        "super+alt+i",
        "super+alt+shift+j",
        "super+alt+shift+w",
        "super+alt+w",
        "super+arrow_down",
        "super+arrow_left",
        "super+arrow_right",
        "super+arrow_up",
        "super+backspace",
        "super+c",
        "super+ctrl+=",
        "super+ctrl+arrow_down",
        "super+ctrl+arrow_left",
        "super+ctrl+arrow_right",
        "super+ctrl+arrow_up",
        "super+ctrl+f",
        "super+ctrl+shift+j",
        "super+d",
        "super+digit_1",
        "super+digit_2",
        "super+digit_3",
        "super+digit_4",
        "super+digit_5",
        "super+digit_6",
        "super+digit_7",
        "super+digit_8",
        "super+e",
        "super+end",
        "super+enter",
        "super+f",
        "super+g",
        "super+home",
        "super+j",
        "super+k",
        "super+n",
        "super+page_down",
        "super+page_up",
        "super+q",
        "super+shift+,",
        "super+shift+[",
        "super+shift+]",
        "super+shift+arrow_down",
        "super+shift+arrow_up",
        "super+shift+d",
        "super+shift+enter",
        "super+shift+f",
        "super+shift+g",
        "super+shift+j",
        "super+shift+p",
        "super+shift+t",
        "super+shift+v",
        "super+shift+w",
        "super+shift+z",
        "super+t",
        "super+v",
        "super+w",
        "super+z",
    ]

    /// Triggers baia unbinds without owning a menu item for them.
    ///
    /// Ghostty binds these to `next_tab` and `previous_tab`, and those actions
    /// reach the Swift layer as callbacks `TerminalCallbackBridge` drops in its
    /// default branch. So they already do nothing, and worse than nothing: the
    /// surface swallows the key, so a TUI inside the pane that wants ⌃Tab for its
    /// own pane switching never receives it. Unbinding hands the key to the
    /// program running in the terminal, which is where it belongs.
    private static let standingUnbinds = ["ctrl+shift+tab", "ctrl+tab"]

    /// Sorted, unique `<trigger>=unbind` values for every item whose policy is
    /// ``GhosttyPolicy/unbind``, ready for `builder.withCustom("keybind", line)`.
    ///
    /// Sorted so the config the surface receives is stable across runs and a
    /// diff of it names only real changes. Unique because two menus claiming one
    /// key would otherwise emit the line twice, and ghostty accepts the
    /// duplicate silently, which hides the collision the tests exist to find.
    ///
    /// Items with a ``GhosttyPolicy/deferToGhostty(reason:)`` or
    /// ``GhosttyPolicy/noConflict`` policy contribute nothing, so the two cases
    /// stay distinguishable in the descriptor while producing the same config.
    public static func unbindLines(for menus: [MenuDescriptor]) -> [String] {
        var lines = Set(standingUnbinds.map { "\($0)=unbind" })
        for menu in menus {
            for item in menu.items where item.policy == .unbind {
                guard let shortcut = item.shortcut else { continue }
                for trigger in shortcut.ghosttyTriggers {
                    lines.insert("\(trigger)=unbind")
                }
            }
        }
        return lines.sorted()
    }
}
