import Darwin
import Foundation

/// The one-time confirmation that command execution over the control channel
/// may be switched on, recorded per installation.
///
/// Kept under Baia's own Application Support directory rather than in
/// `config.json`, and the separation is the point: `controlAllowRun` in the
/// file says what the owner wants, this says the owner has read what it means
/// on this Mac. Setting the key by hand in the file enables nothing until the
/// confirmation exists, and a fresh installation, which has an empty support
/// directory, asks again.
///
/// The Release and Debug builds each own a support directory, so each is its
/// own installation here as well.
public struct CommandExecutionAcknowledgement: Sendable {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/<directoryName>/command-execution.ack`,
    /// beside `session.json` and `control.sock`.
    public static func defaultFileURL(directoryName: String) -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
                .appending(path: "Library/Application Support")
        return support
            .appending(path: directoryName, directoryHint: .isDirectory)
            .appending(path: "command-execution.ack")
    }

    /// The marker the file has to open with. Anything else at the path, an
    /// empty file included, is not an acknowledgement.
    private static let marker = "acknowledged"

    /// Whether this installation has confirmed command execution.
    public var isAcknowledged: Bool {
        guard let data = FileManager.default.contents(atPath: fileURL.path(percentEncoded: false)),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        return text.hasPrefix(Self.marker)
    }

    /// Records the confirmation, answering whether it landed.
    ///
    /// `O_TRUNC` rather than `O_EXCL`: confirming twice is harmless and the
    /// later stamp is the truer one.
    @discardableResult
    public func record(at date: Date = Date()) -> Bool {
        let directory = fileURL.deletingLastPathComponent()
        guard mkdir(directory.path(percentEncoded: false), 0o700) == 0 || errno == EEXIST else { return false }
        let descriptor = open(fileURL.path(percentEncoded: false), O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let stamp = ISO8601DateFormatter().string(from: date)
        let bytes = Array("\(Self.marker) \(stamp)\n".utf8)
        return bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, base + written, buffer.count - written)
                if count > 0 {
                    written += count
                    continue
                }
                guard count < 0, errno == EINTR else { return false }
            }
            return true
        }
    }

    /// Forgets the confirmation, answering whether there is now none.
    public func revoke() -> Bool {
        let path = fileURL.path(percentEncoded: false)
        return unlink(path) == 0 || errno == ENOENT
    }
}
