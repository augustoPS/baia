import Foundation

/// A path shortened for a line that has no room for all of it.
///
/// The window subtitle is the caller: it names the focused pane's working
/// directory, which under `$TMPDIR` is 76 characters of machine-generated noise
/// with the two words the owner cares about at the end. The titlebar shows it
/// whole, so the useful part is pushed off the eye's path by a prefix nobody
/// reads twice.
///
/// **The same rule the shell prompt follows**, in `claude-dotfiles`
/// `shell/prompt.zsh`, so the line above the terminal and the line inside it
/// shorten a path the same way. Two rules would be two answers for one
/// directory, one of them always the odd one out.
public enum DisplayPath {
    /// The last two components, with `../` standing for anything above them.
    ///
    /// `../` appears only when dropping actually saves something. A path whose
    /// only parent is `~` or `/` keeps it: `~/Projects/baia` and `/usr/local` are
    /// the same width either way, and the collapsed spelling costs the tilde and
    /// the root for nothing.
    ///
    /// Purely textual, with no filesystem access and no symlink resolution. The
    /// caller has already decided which spelling of the directory it means, and a
    /// display rule that quietly resolved one would show a path the owner cannot
    /// find in their own prompt.
    public static func shortened(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        // Trailing slashes first, or the last component is "" and every path ends
        // up shortened to its parent.
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }

        let name = (trimmed as NSString).lastPathComponent
        let parent = (trimmed as NSString).deletingLastPathComponent

        // "/" and a bare component both have nothing above them worth drawing.
        guard !parent.isEmpty, parent != trimmed, name != trimmed else { return trimmed }

        let above = (parent as NSString).deletingLastPathComponent
        let keepsParentWhole = above.isEmpty || above == parent || above == "~" || above == "/"
        let shownParent = keepsParentWhole ? parent : "../" + (parent as NSString).lastPathComponent
        return shownParent.hasSuffix("/") ? shownParent + name : shownParent + "/" + name
    }
}
