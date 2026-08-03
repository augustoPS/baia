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
///
/// **Bytes rather than `String`, in and out.** A filename on a Unix filesystem is
/// a byte string, git reports whatever the index holds, and `String` cannot carry
/// a byte sequence that is not UTF-8: it substitutes U+FFFD, irreversibly, and
/// every unreadable byte collapses onto the same one. A path that has been through
/// a `String` is a path no command can find, which was the whole symptom this type
/// is on the end of. `GitWorkspace.RepositoryPath` carries the bytes to the caller
/// and this takes them raw.
public enum PromptPath {
    public enum Refusal: Sendable, Equatable {
        /// The rendered path carries a scalar a line editor would act on.
        case controlScalar
        /// There is no path to send.
        case emptyPath
    }

    public enum Resolution: Sendable, Equatable {
        /// Exactly the bytes to write to the pty, trailing space included.
        case send([UInt8])
        case refuse(Refusal)
    }

    /// What clicking a row sends, given the path it shows, the repository that
    /// path is relative to, and the working directory of the pane it is going to.
    ///
    /// The working directory is optional because a pane that has never resolved
    /// one is ordinary rather than exceptional, and an absolute path is the right
    /// answer for it.
    ///
    /// **The path is bytes and the two directories are not, which is deliberate
    /// rather than half a job.** The path can name a file this machine never
    /// created: git lists index and tree entries carried in from an ext4, NFS or
    /// ExFAT checkout, and those names reach the sidebar whether or not a local
    /// checkout of them ever succeeded. The root and the working directory are
    /// different: both are directories that exist on this Mac right now, having
    /// been resolved from a `URL` the kernel or `GitRepositoryLocator` answered
    /// with, and APFS refuses a name that is not valid UTF-8 at the point of
    /// creation. A non-UTF-8 root would need a volume that is not APFS, and it
    /// would arrive here already lossy from `URL`, which is the caller's problem
    /// to notice rather than one this signature can express away.
    public static func resolve(
        repositoryRelativePath path: [UInt8],
        repositoryRoot root: String,
        workingDirectory: String?
    ) -> Resolution {
        guard !path.isEmpty else { return .refuse(.emptyPath) }

        // Lexical, with no `FileManager` anywhere near it. A deleted file still
        // has a path worth sending, since `git checkout -- <path>` is exactly what
        // the owner is reaching for, and a filesystem call per click would buy an
        // answer that changes nothing about what to send. It is also the only
        // thing that *can* happen here now: a path that is not UTF-8 may name a
        // file no local checkout ever produced, so asking the filesystem about it
        // would answer "no" for a row that is still worth sending.
        let absolute = joined(root, path)
        let rendered = relative(absolute, to: workingDirectory) ?? absolute
        guard !rendered.isEmpty else { return .refuse(.emptyPath) }

        // Checked on the rendered path rather than on the argument, so a control
        // scalar arriving through the root or the working directory is caught by
        // the same test. A repository can be cloned into any directory the owner
        // was given the name of.
        guard !carriesControl(rendered) else { return .refuse(.controlScalar) }

        return .send(quoted(guardedAgainstOptionSyntax(rendered)) + [0x20])
    }

    /// `root` and `path` joined, tolerating a trailing slash on the root.
    private static func joined(_ root: String, _ path: [UInt8]) -> [UInt8] {
        var base = Array(root.utf8)
        if base.last == slash { base.removeLast() }
        return base + [slash] + path
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
    private static func relative(_ absolute: [UInt8], to directory: String?) -> [UInt8]? {
        guard let directory else { return nil }
        var base = Array(directory.utf8)
        if base.last == slash { base.removeLast() }
        base.append(slash)

        // `>=` rather than `>`, so a path that *is* the working directory comes
        // back empty and the caller refuses it. Written strict first, which
        // silently turned that refusal into a send of the directory's own
        // absolute path and left the caller's empty check unreachable. No caller
        // can reach it today, since directory rows never send and neither
        // `ls-files` nor `status` reports a path with a trailing slash, but this
        // is public API and a refusal quietly becoming a send is the one change
        // this type must never make.
        if absolute.count >= base.count, Array(absolute.prefix(base.count)) == base {
            return Array(absolute.dropFirst(base.count))
        }

        // **The byte compare above cannot see two spellings of one directory.**
        // `String.hasPrefix`, which this replaced, compares by canonical
        // equivalence, so a precomposed path matched a decomposed working
        // directory and the short form was sent. Both spellings occur together
        // here routinely: `core.precomposeunicode` is on by default on macOS so
        // git reports NFC, while the pane's working directory comes from the
        // kernel and carries whatever bytes the directory was made with.
        //
        // So the byte answer is tried first and kept when it works, and this is
        // the fallback for the case bytes cannot decide. It only runs when both
        // sides are valid UTF-8, which is exactly when the old behaviour was
        // defined, and it hands back the *bytes of the suffix* rather than a
        // re-encoded string, so a path that is not UTF-8 never reaches it and
        // nothing here can re-introduce a lossy round trip.
        guard let text = String(bytes: absolute, encoding: .utf8),
              let baseText = String(bytes: base, encoding: .utf8),
              text.hasPrefix(baseText)
        else { return nil }
        return Array(text.dropFirst(baseText.count).utf8)
    }

    /// A relative path that would read as an option, prefixed so it cannot.
    ///
    /// The one case quoting does not answer: `'-rf'` is still an option to
    /// whatever command reads the line, because quoting is the shell's business
    /// and options are the command's. An absolute path needs nothing, since it
    /// opens with a slash.
    private static func guardedAgainstOptionSyntax(_ path: [UInt8]) -> [UInt8] {
        guard path.first != slash, path.first == hyphen else { return path }
        return [dot, slash] + path
    }

    /// The path as one shell word.
    ///
    /// Single quotes rather than a backslash per character, because one pair
    /// disables globbing, `$`, backticks, brace expansion, `~` and `=` at once,
    /// and a per-character escape is a list that has to stay complete forever. The
    /// only character single quotes cannot carry is a single quote, which closes
    /// the string, escapes one, and reopens.
    ///
    /// Byte-wise, and it has to be: a quoting pass that walked `Character`s would
    /// have to decode first. Nothing here needs to know where one character ends,
    /// because every byte that matters to a shell is ASCII and a byte of a
    /// multi-byte sequence can never be mistaken for one.
    private static func quoted(_ path: [UInt8]) -> [UInt8] {
        guard !path.allSatisfy(isSafe) else { return path }
        var quoted: [UInt8] = [quote]
        for byte in path {
            // `'\''`: close the string, escape one quote, reopen.
            if byte == quote {
                quoted += [quote, backslash, quote, quote]
            } else {
                quoted.append(byte)
            }
        }
        quoted.append(quote)
        return quoted
    }

    /// The bytes that need no quoting, and deliberately fewer than a shell
    /// tolerates.
    ///
    /// Two exclusions are load-bearing rather than caution. `~` is a user
    /// expansion when it leads a word, so a file called `~notes` in the working
    /// directory would be sent as somebody's home directory. `=` is a command
    /// lookup under zsh's `EQUALS` option, which is on by default. Both are
    /// dangerous only in the leading position and both are kept out of the set
    /// entirely, so either one anywhere in a path quotes the whole thing.
    ///
    /// Every byte at or above 0x80 is unsafe by omission, which is the answer
    /// this set wants for a non-ASCII path: quote the whole word and send it.
    private static func isSafe(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41 ... 0x5A, 0x61 ... 0x7A, 0x30 ... 0x39: true // A-Z a-z 0-9
        case dot, 0x5F, hyphen, slash, 0x40, 0x2B, 0x3A: true // . _ - / @ + :
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
    ///
    /// **Read off the bytes rather than off decoded scalars, and the two agree
    /// exactly.** Unicode's `Cc` category is U+0000...U+001F and U+007F...U+009F
    /// and nothing else, so the byte rule is: any byte below 0x20, `DEL`, or the
    /// two-byte sequence `0xC2 0x80`...`0xC2 0x9F`. A byte at or above 0x80 that
    /// is not part of that pair is either ordinary UTF-8 or not UTF-8 at all, and
    /// neither drives a line editor. Deciding it here rather than by decoding is
    /// what lets a path that is not UTF-8 be judged at all: `String` would have
    /// replaced those bytes with U+FFFD, which is not a control and would have
    /// passed a check the original bytes never faced.
    private static func carriesControl(_ path: [UInt8]) -> Bool {
        for (index, byte) in path.enumerated() {
            if byte < 0x20 || byte == 0x7F { return true }
            if byte == 0xC2, index + 1 < path.count, (0x80 ... 0x9F).contains(path[index + 1]) {
                return true
            }
        }
        return false
    }

    private static let slash: UInt8 = 0x2F
    private static let hyphen: UInt8 = 0x2D
    private static let dot: UInt8 = 0x2E
    private static let quote: UInt8 = 0x27
    private static let backslash: UInt8 = 0x5C
}
