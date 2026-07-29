import Foundation

/// Turns a path a sidebar row is showing into the exact bytes to put on a pane's
/// prompt, or refuses to.
///
/// **The caller decides nothing.** It reads the row under the mouse, calls
/// ``resolve(repositoryRelativePath:repositoryRoot:workingDirectory:)``, and hands
/// a `.send` payload to the pane unchanged. Every rule about quoting, about what
/// is relative, and about what may not be sent at all lives here, where a test can
/// reach it without a window.
///
/// **Nothing here ever emits a newline.** A newline executes whatever is on the
/// prompt line, so a click would run a command the owner never read. That is not
/// enforced by trimming one off the end: a newline is a control scalar, and a path
/// carrying any control scalar is refused outright.
public enum PromptPath {
    public enum Refusal: Sendable, Equatable {
        /// The rendered path carries a scalar a line editor would act on.
        case controlScalar
        /// There is no path to send.
        case emptyPath
    }

    public enum Resolution: Sendable, Equatable {
        /// Exactly the bytes to write to the pty, trailing space included.
        case send(String)
        case refuse(Refusal)
    }

    /// What clicking a row sends, given the path it shows, the repository that
    /// path is relative to, and the working directory of the pane it is going to.
    ///
    /// The working directory is optional because a pane that has never resolved
    /// one is ordinary rather than exceptional, and an absolute path is the right
    /// answer for it.
    public static func resolve(
        repositoryRelativePath path: String,
        repositoryRoot root: String,
        workingDirectory: String?
    ) -> Resolution {
        guard !path.isEmpty else { return .refuse(.emptyPath) }

        // Lexical, with no `FileManager` anywhere near it. A deleted file still
        // has a path worth sending, since `git checkout -- <path>` is exactly what
        // the owner is reaching for, and a filesystem call per click would buy an
        // answer that changes nothing about what to send.
        let absolute = joined(root, path)
        let rendered = relative(absolute, to: workingDirectory) ?? absolute
        guard !rendered.isEmpty else { return .refuse(.emptyPath) }

        // Checked on the rendered path rather than on the argument, so a control
        // scalar arriving through the root or the working directory is caught by
        // the same test. A repository can be cloned into any directory the owner
        // was given the name of.
        guard rendered.unicodeScalars.allSatisfy({ !isControl($0) }) else {
            return .refuse(.controlScalar)
        }

        return .send(quoted(guardedAgainstOptionSyntax(rendered)) + " ")
    }

    /// `root` and `path` joined, tolerating a trailing slash on the root.
    private static func joined(_ root: String, _ path: String) -> String {
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        return base + "/" + path
    }

    /// `absolute` as a path relative to `directory`, or nil when it is not under
    /// it.
    ///
    /// **A component boundary rather than a prefix.** `/repo/srcinct` starts with
    /// the characters of `/repo/src` and is not inside it, and a relative path
    /// built from the leftover bytes would name a file in a directory the owner
    /// never clicked.
    ///
    /// Never climbs. A path above the working directory comes back nil and is sent
    /// absolute, because `../../src/main.swift` is harder to read than the
    /// absolute path it replaces and the owner is not typing from where the file
    /// is.
    private static func relative(_ absolute: String, to directory: String?) -> String? {
        guard let directory else { return nil }
        let base = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        guard absolute.hasPrefix(base + "/") else { return nil }
        return String(absolute.dropFirst(base.count + 1))
    }

    /// A relative path that would read as an option, prefixed so it cannot.
    ///
    /// The one case quoting does not answer: `'-rf'` is still an option to
    /// whatever command reads the line, because quoting is the shell's business
    /// and options are the command's. An absolute path needs nothing, since it
    /// opens with a slash.
    private static func guardedAgainstOptionSyntax(_ path: String) -> String {
        guard !path.hasPrefix("/"), path.hasPrefix("-") else { return path }
        return "./" + path
    }

    /// The path as one shell word.
    ///
    /// Single quotes rather than a backslash per character, because one pair
    /// disables globbing, `$`, backticks, brace expansion, `~` and `=` at once,
    /// and a per-character escape is a list that has to stay complete forever. The
    /// only character single quotes cannot carry is a single quote, which closes
    /// the string, escapes one, and reopens.
    private static func quoted(_ path: String) -> String {
        guard !path.unicodeScalars.allSatisfy(isSafe) else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The characters that need no quoting, and deliberately fewer than a shell
    /// tolerates.
    ///
    /// Two exclusions are load-bearing rather than caution. `~` is a user
    /// expansion when it leads a word, so a file called `~notes` in the working
    /// directory would be sent as somebody's home directory. `=` is a command
    /// lookup under zsh's `EQUALS` option, which is on by default. Both are
    /// dangerous only in the leading position and both are kept out of the set
    /// entirely, so either one anywhere in a path quotes the whole thing.
    private static func isSafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A" ... "Z", "a" ... "z", "0" ... "9": true
        case ".", "_", "-", "/", "@", "+", ":": true
        default: false
        }
    }

    /// The control category and nothing wider.
    ///
    /// It covers the C0 block, DEL and C1, which is every scalar zsh's line editor
    /// reads as a command rather than as text: `\u{1b}` opens an escape sequence
    /// and `\u{01}` is beginning-of-line. A format character like a zero-width
    /// joiner drives nothing and is ordinary text in several writing systems, so
    /// refusing it would reject names that are foreign rather than hostile.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
    }
}
