/// A path exactly as git wrote it, which is bytes and not text.
///
/// **A filename on a Unix filesystem is a byte string with two rules: no NUL and
/// no slash.** Nothing requires it to be UTF-8, and git reports whatever the
/// filesystem holds. macOS is stricter than that at the point of creation, since
/// APFS refuses a name that is not valid UTF-8, but a repository is not created
/// only on macOS: a clone from an ext4 checkout, an NFS or SMB share or an ExFAT
/// volume carries paths into the index and into tree objects that this machine
/// could not have made, and git lists them.
///
/// `String(decoding: bytes, as: UTF8.self)` is where those paths were being lost.
/// It never fails; it substitutes U+FFFD for every byte it cannot read, and the
/// substitution is not reversible. What comes back is a name no filesystem holds,
/// and every byte that is not UTF-8 collapses onto the same one, so two different
/// files render as one. That is why this is a type rather than a `String` handled
/// carefully: the bytes have to be carried, and the only place they can be carried
/// is a value that never decodes them.
///
/// ``display`` is still offered, because a row has to draw something and refusing
/// to draw the file at all is worse than drawing it wrong. It is the lossy
/// spelling and the only lossy one; anything that has to *name* the file, rather
/// than show it, wants ``bytes``.
public struct RepositoryPath: Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    /// The path git reported, byte for byte, relative to the repository root.
    public let bytes: [UInt8]

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = Array(bytes)
    }

    /// A path that is already text. Lossless in this direction: every `String` has
    /// a UTF-8 spelling, and it is the one a filesystem would be given.
    public init(_ string: String) {
        bytes = Array(string.utf8)
    }

    /// So a fixture or an expectation can be written as `"Sources/app.swift"`. The
    /// literal is text, which is what makes it safe: a path a test can type is a
    /// path that has a `String` spelling.
    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// The path as something to draw, with every byte that is not UTF-8 replaced by
    /// U+FFFD.
    ///
    /// Lossy, and deliberately not called `string`: a name that sounds like a
    /// conversion is one a caller will send to a shell.
    public var display: String {
        String(decoding: bytes, as: UTF8.self)
    }

    public var description: String { display }

    public var isEmpty: Bool { bytes.isEmpty }
}
