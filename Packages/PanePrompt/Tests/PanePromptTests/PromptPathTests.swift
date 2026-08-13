import Testing

@testable import PanePrompt

/// What a sidebar row sends when it is clicked.
///
/// The whole rule lives here rather than in the app target, because every one of
/// these answers is decidable without a window, and the app target has no test
/// target to hold them. The surfaces read the row under the mouse and hand the
/// result to the pane; they decide nothing.
@Suite struct PromptPathTests {
    /// Every expectation reached through this helper was written against the
    /// `String` version of `resolve` and is unchanged, which is the point of
    /// keeping it: a path with a `String` spelling must send exactly what it sent
    /// before, both across the move to bytes and across the refusal added on top
    /// of it. Paths with no `String` spelling go through ``sendBytes(_:root:cwd:)``
    /// and ``refusalOf(_:root:cwd:)``.
    private func send(
        _ path: String,
        root: String = "/repo",
        cwd: String? = "/repo"
    ) -> String? {
        guard let bytes = sendBytes(Array(path.utf8), root: root, cwd: cwd) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func sendBytes(
        _ path: [UInt8],
        root: String = "/repo",
        cwd: String? = "/repo"
    ) -> [UInt8]? {
        guard case let .send(bytes) = PromptPath.resolve(
            repositoryRelativePath: path,
            repositoryRoot: root,
            workingDirectory: cwd
        ) else { return nil }
        return bytes
    }

    private func refusal(
        _ path: String,
        root: String = "/repo",
        cwd: String? = "/repo"
    ) -> PromptPath.Refusal? {
        refusalOf(Array(path.utf8), root: root, cwd: cwd)
    }

    /// The same, for a path with no `String` spelling. Which refusal it is matters
    /// as much as that there was one: the capsule says the reason, and "not UTF-8"
    /// for a name whose real problem is a tab would send the owner to the wrong
    /// fix.
    private func refusalOf(
        _ path: [UInt8],
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

    /// The caller's precondition, written down as a test because breaking it is
    /// silent: the result is still a correct path, just never the short one.
    ///
    /// Two spellings of one directory share no prefix, so the relative form is
    /// unreachable. macOS makes this easy to hit and hard to see: the kernel
    /// reports a process's directory as `/private/var/...` while Foundation's
    /// `resolvingSymlinksInPath()` *strips* a leading `/private`, so a repository
    /// under `$TMPDIR` reaches the two sides in two spellings. Every click sent an
    /// absolute path on 2026-07-29 for exactly this reason. The fix belongs to the
    /// caller, which now resolves both.
    @Test func cannotRelativizeTwoSpellingsOfOneDirectory() {
        #expect(send(
            "src/a.txt",
            root: "/var/folders/x/repo",
            cwd: "/private/var/folders/x/repo"
        ) == "/var/folders/x/repo/src/a.txt ")
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
                        repositoryRelativePath: Array(path.utf8),
                        repositoryRoot: root,
                        workingDirectory: cwd
                    )
                }
            }
        }
    }

    /// The invariant the refusal exists to hold. Anything that reaches a pty must
    /// be free of the scalars a line editor acts on, whatever the input was.
    ///
    /// Graded on the bytes rather than on decoded scalars, because bytes are what
    /// reaches the pty and a decode would be a second implementation of the rule
    /// under test. `Cc` is U+0000...U+001F and U+007F...U+009F, which in UTF-8 is
    /// every byte below 0x20, `DEL`, and `0xC2` followed by 0x80...0x9F.
    @Test func nothingSentEverCarriesAControlScalar() {
        for resolution in Self.everyCombination {
            guard case let .send(bytes) = resolution else { continue }
            #expect(bytes.allSatisfy { $0 >= 0x20 && $0 != 0x7F })
            #expect(!bytes.indices.contains { index in
                bytes[index] == 0xC2 && index + 1 < bytes.count
                    && (0x80 ... 0x9F).contains(bytes[index + 1])
            })
        }
    }

    @Test func everythingSentEndsInExactlyOneSpace() {
        for resolution in Self.everyCombination {
            guard case let .send(bytes) = resolution else { continue }
            #expect(bytes.last == 0x20)
            #expect(bytes.dropLast().last != 0x20)
            #expect(bytes.count > 1)
        }
    }

    /// A quoted result has to be closed. An unbalanced quote leaves the shell
    /// waiting for the rest of a string, which is a prompt the owner then has to
    /// rescue rather than a path they can use.
    @Test func aQuotedResultIsBalanced() {
        for resolution in Self.everyCombination {
            guard case let .send(bytes) = resolution else { continue }
            // Decoded rather than compared byte-wise, because every input in
            // `hostile` has a `String` spelling and the quoting rule is about
            // characters a shell reads. The non-UTF-8 cases are graded on bytes,
            // in `aPathThatIsNotUTF8SurvivesByteForByte`.
            let argument = String(decoding: bytes.dropLast(), as: UTF8.self)
            guard argument.contains("'") else { continue }
            #expect(argument.hasPrefix("'") || argument.hasPrefix("./'"))
            #expect(argument.hasSuffix("'"))
            // Every interior quote belongs to a `'\''` run, so removing those
            // leaves exactly the two that open and close the argument.
            let remaining = argument.replacingOccurrences(of: "'\\''", with: "")
            #expect(remaining.filter { $0 == "'" }.count == 2)
        }
    }

    // MARK: - Paths that have no String spelling

    /// The decision this resolver exists to make, and it is a refusal.
    ///
    /// `0xE9` alone is Latin-1 `é` and is not valid UTF-8. Measured against a real
    /// pane on 2026-08-03: the bytes reach the pty intact, but zsh's line editor
    /// decodes its input as characters, so the prompt showed `printf '%s' 'src/caf`
    /// and stopped at that byte with the quote still open. Sending is the worse
    /// failure of the two available, because a half-line reads as the app having
    /// lost the click and has to be cleared by hand.
    @Test func aPathThatIsNotUTF8IsRefusedRatherThanLeftHalfOnThePrompt() {
        let latin1 = Array("caf".utf8) + [0xE9] + Array(".txt".utf8)
        #expect(sendBytes(latin1) == nil)
        #expect(refusalOf(latin1) == .notUTF8)
    }

    /// **The discrimination that justifies carrying bytes at all, now that the
    /// answer for an unreadable name is "refuse".**
    ///
    /// U+FFFD is an ordinary character and a file may honestly be named with it.
    /// A resolver taking a `String` sees the same three bytes for that file and
    /// for `caf<E9>.txt`, because the decode already happened, so it must either
    /// send both, which puts a path naming nothing on the prompt, or refuse both,
    /// which rejects a legal file for a fault it does not have. Only the raw bytes
    /// tell them apart, and this asserts both directions of that.
    @Test func aFileHonestlyNamedWithTheReplacementCharacterStillSends() {
        let honest = Array("caf\u{FFFD}.txt".utf8)
        let mangled = Array("caf".utf8) + [0xE9] + Array(".txt".utf8)

        // Same rendering, opposite answers.
        #expect(String(decoding: honest, as: UTF8.self)
            == String(decoding: mangled, as: UTF8.self))
        #expect(sendBytes(honest) == [0x27] + honest + [0x27, 0x20])
        #expect(sendBytes(mangled) == nil)
    }

    /// A lone high byte and the C1 pair are both refused, for different reasons,
    /// and the reason is what the capsule will say.
    ///
    /// `0x80` on its own is not valid UTF-8; `0xC2 0x85` is valid UTF-8 for a C1
    /// control, which a line editor would act on. Two rules, two cases, and a
    /// single refusal that could not tell them apart would be a worse message.
    @Test func aLoneHighByteAndTheC1PairRefuseForDifferentReasons() {
        #expect(refusalOf(Array("a".utf8) + [0x80] + Array("b".utf8)) == .notUTF8)
        #expect(refusalOf(Array("a".utf8) + [0x9F] + Array("b".utf8)) == .notUTF8)
        #expect(refusalOf(Array("a".utf8) + [0xC2, 0x85] + Array("b".utf8)) == .controlScalar)
    }

    /// The control check runs before the UTF-8 one, so a path that fails both is
    /// reported as the more specific of the two.
    ///
    /// A tab is what the owner can act on: rename the file. "Not UTF-8" for a path
    /// whose real problem is a tab would send them looking at encodings.
    @Test func aControlScalarBeatsTheUTF8RefusalWhenAPathCarriesBoth() {
        #expect(refusalOf(Array("a\tb".utf8) + [0xE9]) == .controlScalar)
    }

    /// Every byte at or above 0x80 that forms valid UTF-8 still sends, quoted.
    ///
    /// The refusal is about what the line editor can hold, not about how foreign
    /// the name looks, and `café.txt` properly encoded is ordinary text.
    @Test func aProperlyEncodedNonAsciiNameStillSends() {
        let utf8 = Array("caf\u{e9}.txt".utf8)
        #expect(sendBytes(utf8) == [0x27] + utf8 + [0x27, 0x20])
    }

    /// The relative match is still byte-wise, and a non-UTF-8 component is refused
    /// after that match rather than by breaking it.
    ///
    /// Worth separating because the two failures look alike from outside: a path
    /// that failed to relativize would be sent absolute, and one refused for its
    /// encoding is sent not at all. The first would be a bug in `relative`.
    @Test func aNonUTF8ComponentIsRefusedRatherThanFailingTheRelativeMatch() {
        let path = Array("dir".utf8) + [0xE9] + Array("/file.txt".utf8)
        #expect(refusalOf(path, root: "/repo", cwd: "/repo") == .notUTF8)
        // Absolute rendering, same answer: the refusal does not depend on which
        // branch produced the path.
        #expect(refusalOf(path, root: "/repo", cwd: "/elsewhere") == .notUTF8)
    }

    /// What `Diagnostics/prompt-path-bytes/` asserts on a real pane, pinned here so
    /// the probe and the resolver cannot drift.
    ///
    /// The probe clicks the row and expects the prompt to stay empty and the
    /// capsule to say why. This is the same claim without a window: the row that
    /// probe builds resolves to a refusal, and to this one.
    @Test func theLiveProbesRowResolvesToTheRefusalItExpects() {
        let path = Array("src/caf".utf8) + [0xE9] + Array(".txt".utf8)
        #expect(refusalOf(path, root: "/repo", cwd: "/repo") == .notUTF8)
    }
}
