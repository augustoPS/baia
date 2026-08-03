import Testing

@testable import PanePrompt

/// What a sidebar row sends when it is clicked.
///
/// The whole rule lives here rather than in the app target, because every one of
/// these answers is decidable without a window, and the app target has no test
/// target to hold them. The surfaces read the row under the mouse and hand the
/// result to the pane; they decide nothing.
@Suite struct PromptPathTests {
    /// Every expectation below this line was written against the `String` version
    /// of `resolve` and is unchanged. That is the point of keeping the helper: the
    /// move to bytes is supposed to be invisible to every path that has a `String`
    /// spelling, and 29 assertions saying so is the evidence. The byte-only cases
    /// go through ``sendBytes(_:root:cwd:)`` instead.
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
        guard case let .refuse(reason) = PromptPath.resolve(
            repositoryRelativePath: Array(path.utf8),
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

    /// The whole reason this resolver moved onto bytes.
    ///
    /// `0xE9` alone is Latin-1 `é` and is not valid UTF-8. Through a `String` it
    /// becomes U+FFFD, which is three different bytes naming a file that does not
    /// exist, and every unreadable byte in every filename collapses onto that same
    /// replacement. The bytes have to arrive at the pty exactly as git reported
    /// them or the path is not the path.
    @Test func aPathThatIsNotUTF8SurvivesByteForByte() {
        let latin1 = Array("caf".utf8) + [0xE9] + Array(".txt".utf8)
        let sent = sendBytes(latin1)
        // Quoted, because 0xE9 is not in the safe set, and the quotes are the only
        // bytes added.
        #expect(sent == [0x27] + latin1 + [0x27, 0x20])

        // The lossy spelling is a different byte string, which is the failure this
        // replaces rather than a detail: it is what the old code sent.
        #expect(sent != Array("'\(String(decoding: latin1, as: UTF8.self))' ".utf8))
    }

    /// Two names that differ only in a byte `String` cannot read stay two names.
    ///
    /// Through `String` both become `caf\u{FFFD}.txt` and the sidebar sends one
    /// path for two files, which is the collapse that makes the loss worse than a
    /// wrong glyph.
    @Test func twoPathsThatCollapseUnderStringStayDistinct() {
        let first = Array("caf".utf8) + [0xE9] + Array(".txt".utf8)
        let second = Array("caf".utf8) + [0xFF] + Array(".txt".utf8)
        #expect(sendBytes(first) != sendBytes(second))
    }

    /// A byte at or above 0x80 is not a control scalar and must not be refused.
    ///
    /// The C1 block lives at U+0080...U+009F, which is `0xC2` *followed by* one of
    /// those bytes. A lone 0x80 is neither that pair nor valid UTF-8, and refusing
    /// it would reject a filename for being foreign.
    @Test func aLoneHighByteIsSentAndTheC1PairIsRefused() {
        #expect(sendBytes(Array("a".utf8) + [0x80] + Array("b".utf8)) != nil)
        #expect(sendBytes(Array("a".utf8) + [0x9F] + Array("b".utf8)) != nil)

        guard case let .refuse(reason) = PromptPath.resolve(
            repositoryRelativePath: Array("a".utf8) + [0xC2, 0x85] + Array("b".utf8),
            repositoryRoot: "/repo",
            workingDirectory: "/repo"
        ) else { return #expect(Bool(false), "the C1 pair has to be refused") }
        #expect(reason == .controlScalar)
    }

    /// The exact bytes `Diagnostics/prompt-path-bytes/` expects to see arrive at
    /// the shell, pinned here so the probe and the resolver cannot drift.
    ///
    /// That probe builds a repository holding `src/caf<E9>.txt` as an index entry,
    /// clicks its row, and compares what zsh received against a file the fixture
    /// wrote. The fixture spells the expectation as a literal, which is a second
    /// copy of this rule; this is the first, and a change here that the probe does
    /// not know about fails on the next run rather than silently passing against a
    /// stale expectation. If this test moves, move `fixture.sh` with it.
    @Test func theBytesTheLiveProbeExpectsAreTheOnesThisProduces() {
        let path = Array("src/caf".utf8) + [0xE9] + Array(".txt".utf8)
        let expected = Array("'src/caf".utf8) + [0xE9] + Array(".txt' ".utf8)
        #expect(sendBytes(path, root: "/repo", cwd: "/repo") == expected)
    }

    /// The relative-path boundary is byte-wise, so a non-UTF-8 directory name in
    /// the middle of a path cannot break the component match.
    @Test func aNonUTF8ComponentDoesNotBreakTheRelativeMatch() {
        let path = Array("dir".utf8) + [0xE9] + Array("/file.txt".utf8)
        #expect(sendBytes(path, root: "/repo", cwd: "/repo")
            == [0x27] + path + [0x27, 0x20])
    }
}
