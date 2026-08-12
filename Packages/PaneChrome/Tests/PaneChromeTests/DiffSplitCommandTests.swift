import Testing

@testable import PaneChrome

/// The changes card's command builders, checked the way the value is
/// actually consumed: not by comparing against hand-written expected strings
/// (which would encode the same quoting mistake twice) but by undoing the
/// quoting with the rules the receiving shells apply and asserting the
/// original path comes back whole.
@Suite struct DiffSplitCommandTests {
    /// One level of POSIX word-splitting, the part of it these values can
    /// contain: unquoted whitespace splits, `'…'` is literal, `\` escapes the
    /// next character outside quotes, an unquoted `;` ends a word and is
    /// dropped. This is what bash does to the value ghostty hands it and what
    /// zsh then does to its `-lc` argument, minus the expansions neither ever
    /// reaches inside single quotes.
    private func words(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var hasWord = false
        var inSingleQuotes = false
        var escaped = false
        for character in line {
            if inSingleQuotes {
                if character == "'" { inSingleQuotes = false } else { current.append(character) }
            } else if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "'" {
                inSingleQuotes = true
                hasWord = true
            } else if character == " " || character == "\t" || character == ";" {
                if hasWord || !current.isEmpty { words.append(current) }
                current = ""
                hasWord = false
            } else {
                current.append(character)
                hasWord = true
            }
        }
        if hasWord || !current.isEmpty { words.append(current) }
        return words
    }

    /// The value split as bash splits it: `/bin/zsh`, `-lc`, and the one
    /// command string zsh receives.
    private func zshCommand(of value: String) -> String? {
        let outer = words(value)
        guard outer.count == 3, outer[0] == "/bin/zsh", outer[1] == "-lc" else { return nil }
        return outer[2]
    }

    // MARK: - The wrap

    /// The probe's two load-bearing facts: ghostty already supplies
    /// `exec -l`, so the value must not lead with its own exec, and a pane
    /// whose command exits closes, so the command must end by becoming a
    /// shell.
    @Test func theValueWearsTheProbesShapeExactly() throws {
        let value = DiffSplitCommand.fullDiff(headExists: true)
        #expect(value.hasPrefix("'/bin/zsh' -lc "))
        let command = try #require(zshCommand(of: value))
        #expect(command == #"git diff HEAD; exec "$SHELL" -l"#)
    }

    // MARK: - Quoting

    /// The hostile filename: a quote to break out of the pathspec and a
    /// command substitution waiting on the other side. Both levels of
    /// unquoting must hand back the literal name, expansions never reached.
    @Test func aQuoteAndASubstitutionInThePathStayLiteral() throws {
        let value = DiffSplitCommand.file(
            path: "a'b$(rm x).txt", isUntracked: false, headExists: true
        )
        let inner = words(try #require(zshCommand(of: value)))
        #expect(Array(inner.prefix(4)) == ["git", "diff", "HEAD", "--"])
        #expect(inner[4] == "./a'b$(rm x).txt")
        #expect(inner.contains("exec"))
    }

    /// A newline in the path composes and round-trips rather than being
    /// dropped or mangled. The value as a whole then carries a newline, which
    /// `ControlWire.refusalForCommand` refuses at the config boundary; the
    /// builder's job is only to keep the evidence intact for it.
    @Test func aNewlineInThePathRoundTripsAndSurfacesInTheValue() throws {
        let value = DiffSplitCommand.file(
            path: "a\nb.txt", isUntracked: false, headExists: true
        )
        #expect(value.contains("\n"))
        let inner = words(try #require(zshCommand(of: value)))
        #expect(inner[4] == "./a\nb.txt")
    }

    // MARK: - Which diff a row gets

    /// A tracked file diffs against `HEAD`, staged and unstaged combined,
    /// the same comparison the row's counts come from. A bare `git diff`
    /// here is the reviewed bug: staged-but-clean files opened an empty
    /// pager and dropped silently to a shell.
    @Test func aTrackedFileDiffsAgainstHead() throws {
        let value = DiffSplitCommand.file(
            path: "Sources/App.swift", isUntracked: false, headExists: true
        )
        let inner = try #require(zshCommand(of: value))
        #expect(inner.hasPrefix("git diff HEAD -- "))
    }

    /// An untracked file has no `HEAD` side to diff against, so it shows as
    /// an addition against `/dev/null`, unborn or not.
    @Test func anUntrackedFileDiffsAgainstDevNull() throws {
        for headExists in [true, false] {
            let value = DiffSplitCommand.file(
                path: "new.txt", isUntracked: true, headExists: headExists
            )
            let inner = words(try #require(zshCommand(of: value)))
            #expect(Array(inner.prefix(5)) == ["git", "diff", "--no-index", "--", "/dev/null"])
            #expect(inner[5] == "./new.txt")
        }
    }

    /// A repository with no commits has no `HEAD`; the tracked diff drops
    /// the argument (index versus worktree is then the whole story) instead
    /// of printing git's unborn-ref error.
    @Test func anUnbornHeadDropsTheHeadArgument() throws {
        let file = DiffSplitCommand.file(
            path: "x.txt", isUntracked: false, headExists: false
        )
        #expect(try #require(zshCommand(of: file)).hasPrefix("git diff -- "))
        let full = DiffSplitCommand.fullDiff(headExists: false)
        #expect(try #require(zshCommand(of: full)).hasPrefix("git diff; "))
    }

    // MARK: - Pathspec magic

    /// `--` ends options but not pathspec syntax: a filename starting with
    /// `:` would still read as magic. The `./` prefix is what closes that
    /// door, and it must survive the round trip.
    @Test func aColonLedFilenameCannotReadAsPathspecMagic() throws {
        let value = DiffSplitCommand.file(
            path: ":(glob)evil", isUntracked: false, headExists: true
        )
        let inner = words(try #require(zshCommand(of: value)))
        #expect(inner[4] == "./:(glob)evil")
    }
}
