import Testing

@testable import PanePrompt

/// What a sidebar row sends when it is clicked.
///
/// The whole rule lives here rather than in the app target, because every one of
/// these answers is decidable without a window, and the app target has no test
/// target to hold them. The surfaces read the row under the mouse and hand the
/// result to the pane; they decide nothing.
@Suite struct PromptPathTests {
    private func send(
        _ path: String,
        root: String = "/repo",
        cwd: String? = "/repo"
    ) -> String? {
        guard case let .send(text) = PromptPath.resolve(
            repositoryRelativePath: path,
            repositoryRoot: root,
            workingDirectory: cwd
        ) else { return nil }
        return text
    }

    private func refusal(
        _ path: String,
        root: String = "/repo",
        cwd: String? = "/repo"
    ) -> PromptPath.Refusal? {
        guard case let .refuse(reason) = PromptPath.resolve(
            repositoryRelativePath: path,
            repositoryRoot: root,
            workingDirectory: cwd
        ) else { return nil }
        return reason
    }

    // MARK: - The ordinary path

    @Test func sendsAPlainPathBareWithOneTrailingSpace() {
        #expect(send("src/main.swift") == "src/main.swift ")
    }

    /// The trailing space is what makes three clicks an argument list rather than
    /// one concatenated path, which is the case this feature exists for: an agent
    /// says it touched three files and the owner clicks them into a `git add`.
    @Test func threeSendsConcatenateIntoThreeArguments() {
        let line = ["a.txt", "b.txt", "c.txt"].compactMap { send($0) }.joined()
        #expect(line == "a.txt b.txt c.txt ")
    }

    /// A newline would run whatever is on the prompt line, which is a command the
    /// owner never read. Nothing this function returns may contain one, and the
    /// refusal below is what enforces it rather than a trimming step.
    @Test func neverEndsWithANewline() {
        #expect(send("a.txt")?.hasSuffix("\n") == false)
    }

    // MARK: - Quoting

    @Test func quotesAPathHoldingASpace() {
        #expect(send("a b.txt") == "'a b.txt' ")
    }

    @Test func closesAndReopensTheQuoteAroundAnEmbeddedSingleQuote() {
        #expect(send("quo'te.txt") == "'quo'\\''te.txt' ")
    }

    @Test func quotesAPathHoldingADoubleQuote() {
        #expect(send("quo\"te.txt") == "'quo\"te.txt' ")
    }

    /// zsh reads a leading `~` as a user expansion, so a file really called
    /// `~notes` in the working directory would be sent as a home directory that
    /// does not exist. Quoting is what stops the expansion, which is why `~` is
    /// outside the safe set rather than inside it.
    @Test func quotesATildeSoItIsNotReadAsAUserExpansion() {
        #expect(send("~notes") == "'~notes' ")
    }

    /// zsh has `EQUALS` on by default, so a leading `=` expands to the path of a
    /// command. Same answer as the tilde and for the same reason.
    @Test func quotesAnEqualsSoItIsNotReadAsACommandLookup() {
        #expect(send("=x") == "'=x' ")
    }

    @Test func quotesTheGlobCharactersRatherThanEscapingThemOneByOne() {
        #expect(send("a*b?.txt") == "'a*b?.txt' ")
        #expect(send("$HOME.txt") == "'$HOME.txt' ")
        #expect(send("back\\slash.txt") == "'back\\slash.txt' ")
    }

    @Test func sendsANonAsciiNameAsItsOwnBytes() {
        #expect(send("café.txt") == "'café.txt' ")
    }

    // MARK: - A leading dash

    /// The one case quoting cannot answer. `'-rf'` is still an option to whatever
    /// command reads it, so the fix is a path that cannot be read as a flag at
    /// all.
    @Test func prefixesARelativePathThatWouldReadAsAnOption() {
        #expect(send("-rf") == "./-rf ")
    }

    @Test func leavesADashInsideAPathAlone() {
        #expect(send("src/some-file.txt") == "src/some-file.txt ")
        #expect(send("sub/-odd.txt") == "sub/-odd.txt ")
    }

    @Test func needsNoPrefixForAnAbsolutePathBecauseItStartsWithASlash() {
        #expect(send("-rf", root: "/repo", cwd: "/elsewhere") == "/repo/-rf ")
    }

    // MARK: - Relative or absolute

    @Test func sendsAPathUnderTheWorkingDirectoryRelativeToIt() {
        #expect(send("src/main.swift", root: "/repo", cwd: "/repo/src") == "main.swift ")
    }

    /// Never `../`. A path that climbs is harder to read than the absolute one it
    /// replaces, and the owner is not typing from where the file is.
    @Test func sendsAPathAboveTheWorkingDirectoryAbsolute() {
        #expect(send("a.txt", root: "/repo", cwd: "/repo/src") == "/repo/a.txt ")
    }

    @Test func sendsAbsoluteWhenThereIsNoWorkingDirectory() {
        #expect(send("a.txt", root: "/repo", cwd: nil) == "/repo/a.txt ")
    }

    @Test func sendsAbsoluteWhenTheWorkingDirectoryIsOutsideTheRepository() {
        #expect(send("a.txt", root: "/repo", cwd: "/tmp") == "/repo/a.txt ")
    }

    /// A prefix match is not enough. `/repo/srcinct` starts with `/repo/src` and
    /// is not under it, and a relative path built from the leftover bytes would
    /// name a file in the wrong directory.
    @Test func requiresAComponentBoundaryRatherThanAPrefixMatch() {
        #expect(send("srcinct/a.txt", root: "/repo", cwd: "/repo/src") == "/repo/srcinct/a.txt ")
    }

    @Test func toleratesATrailingSlashOnEitherDirectory() {
        #expect(send("src/main.swift", root: "/repo/", cwd: "/repo/src/") == "main.swift ")
    }

    @Test func quotesAnAbsolutePathWhoseRepositoryDirectoryHoldsASpace() {
        #expect(send("a.txt", root: "/my repo", cwd: nil) == "'/my repo/a.txt' ")
    }

    // MARK: - The refusal

    /// `sendText` writes raw bytes to the pty, and those reach zsh's line editor
    /// before its parser: `\u{1b}` opens an escape sequence and `\u{01}` is
    /// beginning-of-line. Quoting protects the parser and does nothing for the
    /// editor, so a control scalar cannot be sent under any quoting at all.
    @Test func refusesEveryControlScalar() {
        #expect(refusal("x\ty.txt") == .controlScalar)
        #expect(refusal("x\ny.txt") == .controlScalar)
        #expect(refusal("x\r\ny.txt") == .controlScalar)
        #expect(refusal("x\u{1b}[D.txt") == .controlScalar)
        #expect(refusal("x\u{01}y.txt") == .controlScalar)
        #expect(refusal("x\u{7f}y.txt") == .controlScalar)
        #expect(refusal("x\u{9b}y.txt") == .controlScalar)
    }

    /// Checked on the rendered path rather than on the input, so a control byte in
    /// the repository root is caught by the same test. A repository can be cloned
    /// into any directory the owner was handed the name of, and an absolute
    /// rendering carries the root's bytes.
    @Test func refusesAControlScalarReachingItThroughTheRepositoryRoot() {
        #expect(refusal("a.txt", root: "/re\u{1b}po", cwd: nil) == .controlScalar)
    }

    /// The working directory is the one input that cannot poison the result, and
    /// checking it would refuse a click that is perfectly safe. Its bytes never
    /// reach the pane: a rendering is either absolute, which is the root plus the
    /// path, or relative, which is the remainder *below* the working directory. So
    /// a pane sitting in a directory with an escape byte in its name still sends a
    /// clean `a.txt` for the file beside it.
    @Test func sendsFromAWorkingDirectoryWhoseOwnNameHoldsAControlScalar() {
        #expect(send("src/a.txt", root: "/re\u{1b}po", cwd: "/re\u{1b}po/src") == "a.txt ")
    }

    /// A format character is foreign rather than hostile. A zero-width joiner
    /// separates no records and drives no line editor, and refusing it would
    /// reject ordinary text from writing systems that use it.
    @Test func sendsAFormatCharacterRatherThanRefusingIt() {
        #expect(send("a\u{200d}b.txt") == "'a\u{200d}b.txt' ")
    }

    @Test func refusesAnEmptyPathRatherThanSendingABareSpace() {
        #expect(refusal("") == .emptyPath)
    }

    // MARK: - Properties

    private static let hostile = [
        "a.txt", "a b.txt", "quo'te.txt", "quo\"te.txt", "~x", "=x", "-rf", "",
        "café.txt", "x\ty.txt", "x\ny.txt", "x\u{1b}[D", "x\u{01}", "a*b", "$X",
        "back\\slash", "a\u{200d}b", "deep/nest/ed/path.txt", ".hidden", "--",
    ]

    private static let directories = ["/repo", "/repo/src", "/my repo", "/"]

    private static var everyCombination: [PromptPath.Resolution] {
        hostile.flatMap { path in
            directories.flatMap { root in
                (directories.map { Optional($0) } + [nil]).map { cwd in
                    PromptPath.resolve(
                        repositoryRelativePath: path,
                        repositoryRoot: root,
                        workingDirectory: cwd
                    )
                }
            }
        }
    }

    /// The invariant the refusal exists to hold. Anything that reaches a pty must
    /// be free of the scalars a line editor acts on, whatever the input was.
    @Test func nothingSentEverCarriesAControlScalar() {
        for resolution in Self.everyCombination {
            guard case let .send(text) = resolution else { continue }
            #expect(text.unicodeScalars.allSatisfy { $0.properties.generalCategory != .control })
        }
    }

    @Test func everythingSentEndsInExactlyOneSpace() {
        for resolution in Self.everyCombination {
            guard case let .send(text) = resolution else { continue }
            #expect(text.hasSuffix(" "))
            #expect(text.hasSuffix("  ") == false)
            #expect(text.count > 1)
        }
    }

    /// A quoted result has to be closed. An unbalanced quote leaves the shell
    /// waiting for the rest of a string, which is a prompt the owner then has to
    /// rescue rather than a path they can use.
    @Test func aQuotedResultIsBalanced() {
        for resolution in Self.everyCombination {
            guard case let .send(text) = resolution else { continue }
            let argument = String(text.dropLast())
            guard argument.contains("'") else { continue }
            #expect(argument.hasPrefix("'") || argument.hasPrefix("./'"))
            #expect(argument.hasSuffix("'"))
            // Every interior quote belongs to a `'\''` run, so removing those
            // leaves exactly the two that open and close the argument.
            let remaining = argument.replacingOccurrences(of: "'\\''", with: "")
            #expect(remaining.filter { $0 == "'" }.count == 2)
        }
    }
}
