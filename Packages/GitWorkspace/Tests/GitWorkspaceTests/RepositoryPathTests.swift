import Testing

@testable import GitWorkspace

@Suite struct RepositoryPathTests {
    /// `café.txt` in Latin-1, whose fourth byte is not a UTF-8 sequence.
    static let latin1: [UInt8] = Array("caf".utf8) + [0xE9] + Array(".txt".utf8)

    @Test func keepsTheBytesItWasGiven() {
        #expect(RepositoryPath(Self.latin1).bytes == Self.latin1)
    }

    @Test func rendersAnInvalidByteAsAReplacementCharacter() {
        // The lossy spelling is still offered, because a row has to draw something
        // and refusing to draw the file at all is worse than drawing it wrong.
        #expect(RepositoryPath(Self.latin1).display == "caf\u{FFFD}.txt")
    }

    @Test func aStringIsItsUTF8() {
        #expect(RepositoryPath("café.txt").bytes == Array("café.txt".utf8))
        #expect(RepositoryPath("café.txt").display == "café.txt")
    }

    /// The reason this is a type rather than a `String` that everyone promises to be
    /// careful with. Every byte that is not UTF-8 renders as the same replacement
    /// character, so two different files draw the same name, and a value that held
    /// only what is drawn would call them the same file.
    @Test func twoPathsThatDrawAlikeAreStillDifferentPaths() {
        let first = RepositoryPath([0xE9])
        let second = RepositoryPath([0xFF])

        #expect(first.display == second.display)
        #expect(first != second)
    }
}
