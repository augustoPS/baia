import Foundation

/// The ghostty `command` values the changes card hands to a split pane: a
/// diff, then a shell.
///
/// Pure string composition, in this package rather than the app target for
/// the reason the app target keeps no logic: the first draft lived beside
/// the card view where nothing could test it, and quoting that reaches a
/// shell through a config file is exactly the code that must not be
/// untestable. Nothing here runs git or touches a repository; the strings
/// are display-side values like everything else this package builds, and
/// the caller supplies the two git facts (untracked, unborn HEAD) as plain
/// flags so this package stays free of the git packages.
///
/// **The shape is the split-command probe's, verbatim**
/// (`Diagnostics/split-command/README.md`): ghostty runs the value through
/// a wrapper that already supplies `exec -l`, so the value must not lead
/// with its own `exec`, and the whole thing is a login zsh running the diff
/// and then becoming an ordinary shell, because ghostty closes a pane whose
/// command exits. git's own pager does the paging; there is nothing to pipe
/// to. `;` rather than `&&` before the trailing exec, so the shell survives
/// even a diff that errors.
///
/// A path containing a newline still composes and round-trips here; refusing
/// it is `ControlWire.refusalForCommand`'s job at the config boundary, and a
/// builder that silently dropped or mangled such a path would hide the very
/// value the refusal exists to catch.
public enum DiffSplitCommand {
    /// The command for one changed file.
    ///
    /// - Tracked files diff against `HEAD`, staged and unstaged combined,
    ///   because that is the comparison the row's own counts are built from
    ///   (`GitCommand.changeStats` records the ruling): a bare `git diff`
    ///   would open empty for a file that is staged and otherwise clean.
    /// - `headExists` false (a repository with no commits yet) drops the
    ///   `HEAD` argument: there is nothing to compare against, so the
    ///   index-versus-worktree diff is the whole story and `git diff HEAD`
    ///   would only print an error.
    /// - An untracked file has no `HEAD` or index side at all, so it diffs
    ///   against `/dev/null` with `--no-index`, which is the one spelling
    ///   that shows the file's content as an addition rather than nothing.
    public static func file(path: String, isUntracked: Bool, headExists: Bool) -> String {
        let pathspec = singleQuoted(prefixGuarded(path))
        let inner = isUntracked
            ? "git diff --no-index -- /dev/null \(pathspec)"
            : "git diff \(headExists ? "HEAD " : "")-- \(pathspec)"
        return wrapped(inner)
    }

    /// The whole repository's diff, against `HEAD` when there is one, for
    /// ``file(path:isUntracked:headExists:)``'s reason.
    public static func fullDiff(headExists: Bool) -> String {
        wrapped(headExists ? "git diff HEAD" : "git diff")
    }

    /// `'/bin/zsh' -lc '<inner>; exec "$SHELL" -l'`, the README's endorsed
    /// shape. The trailing exec is what keeps the pane once the diff's pager
    /// quits.
    private static func wrapped(_ inner: String) -> String {
        "'/bin/zsh' -lc \(singleQuoted(inner + #"; exec "$SHELL" -l"#))"
    }

    /// POSIX single-quoting: close, escaped quote, reopen. The value travels
    /// through a config file rather than a typed line, so these quotes reach
    /// the shell unchanged; delivering them intact is the probe's whole
    /// point.
    private static func singleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// A relative path led with `./`, so a filename starting with `:` cannot
    /// read as pathspec magic. `--` ends git's options but not its pathspec
    /// syntax: `:(glob)…` after `--` is still magic, and a repository can
    /// hold a file named to exploit exactly that. Porcelain paths are always
    /// root-relative; an absolute path (which no caller produces today)
    /// passes through, since prefixing it would corrupt it.
    private static func prefixGuarded(_ path: String) -> String {
        path.hasPrefix("/") ? path : "./" + path
    }
}
