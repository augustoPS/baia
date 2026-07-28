import Darwin
import Foundation

/// The config file on disk: where it is, what it says, and what it says on a
/// first launch.
public struct SettingsStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/.config/baia/config.json`.
    ///
    /// `XDG_CONFIG_HOME` is deliberately not consulted, even though ghostty
    /// honours it. baia is launched from Finder and from `make run`, and the
    /// variable is set in neither, so honouring it would put the config in one
    /// place for a shell launch and another for a double click, leaving the owner
    /// editing a file the running app is not reading.
    public static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/baia/config.json")
    }

    /// The settings on disk, or the defaults when there is no file.
    ///
    /// A missing file is not a failure: a first launch has none, and the defaults
    /// are then the config. `FileManager.contents(atPath:)` is used rather than
    /// `Data(contentsOf:)` because it answers nil instead of throwing, and there
    /// is no `try` in this project's production code. An unreadable file, one
    /// whose permissions were changed by hand, is nil here too and reports
    /// nothing, which is the one gap in the reporting: the decoder can only blame
    /// keys it was given.
    public func load() -> SettingsDecodeResult {
        let path = fileURL.path(percentEncoded: false)
        guard let data = FileManager.default.contents(atPath: path) else {
            return SettingsDecoder.decode(Data())
        }
        return SettingsDecoder.decode(data)
    }

    /// Writes a fully populated config with every default filled in, so the owner
    /// has something to edit rather than a blank file, and answers whether it
    /// wrote one. Never overwrites an existing file.
    ///
    /// `fontFamily` is written as `null`, which the decoder reads as unset. Every
    /// key the decoder understands is present, so the file is the reference for
    /// the spellings and the owner never has to read this source to find one.
    ///
    /// The exclusion is `O_EXCL` rather than a `fileExists` check followed by a
    /// write. Two launches racing on a first run would both pass the check, and
    /// the loser would truncate the file the winner had already written, which
    /// breaks the promise in the sentence above for the one case where it matters.
    public func writeDefaultIfAbsent() -> Bool {
        guard Self.createDirectories(fileURL.deletingLastPathComponent()) else { return false }

        // 0o600, so a config that gains a token or a remote host later starts
        // private instead of needing someone to remember to tighten it. The mode
        // is masked by the process umask, so it is a ceiling and not a guarantee.
        let descriptor = open(
            fileURL.path(percentEncoded: false),
            O_WRONLY | O_CREAT | O_EXCL,
            0o600
        )
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return Self.writeAll(Array(Self.defaultFileContents.utf8), to: descriptor)
    }

    /// Creates `directory` and every missing parent, answering whether it exists
    /// afterwards.
    ///
    /// `FileManager.createDirectory(at:withIntermediateDirectories:)` is the
    /// obvious call and it throws, which production code here does not. `mkdir`
    /// reports an existing directory as `EEXIST`, which is the same information
    /// the `withIntermediateDirectories` flag hides, and `errno` is only read
    /// after a failure return so it cannot carry a stale value in.
    private static func createDirectories(_ directory: URL) -> Bool {
        var built = ""
        for component in directory.pathComponents {
            built = component == "/" ? "/" : built + (built.hasSuffix("/") ? "" : "/") + component
            guard mkdir(built, 0o700) == 0 || errno == EEXIST else { return false }
        }
        return true
    }

    /// Writes every byte, answering false when it cannot.
    ///
    /// `write` is allowed to accept fewer bytes than it was offered and to fail
    /// with `EINTR` when a signal arrives mid call. Either would leave a config
    /// file that stops halfway through a key, and that file then decodes as
    /// unreadable, which means baia would report an error about a file it wrote
    /// itself and never repair it, since the path now exists.
    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32) -> Bool {
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            var written = 0
            while written < buffer.count {
                let count = write(descriptor, base + written, buffer.count - written)
                if count > 0 {
                    written += count
                    continue
                }
                guard count < 0, errno == EINTR else { return false }
            }
            return true
        }
    }

    /// The first-launch file, holding ``Settings/defaultSettings`` in the
    /// decoder's own key spellings.
    ///
    /// Written out as text rather than assembled from `defaultSettings`, because a
    /// serializer would have to be written and tested for the one document it will
    /// ever produce. The two cannot drift: `SettingsStoreTests` decodes this file
    /// back and expects the defaults with nothing reported, and it also expects the
    /// file to name every key the decoder reads, which a round trip alone cannot
    /// see.
    ///
    /// `projectRoots` keeps the tilde rather than the expanded path. The file is
    /// meant to be copied between machines, and the decoder expands it on read.
    private static let defaultFileContents = """
    {
      "fontFamily": null,
      "fontSize": 11.5,
      "themeName": "Dark Pastel",
      "backgroundHex": "#141414",
      "backgroundOpacity": 0.85,
      "backgroundBlur": true,
      "windowPadding": 8,
      "windowPaddingBalance": true,
      "transparentTitlebar": true,
      "optionAsAlt": true,
      "cursorStyle": "block",
      "projectRoots": ["~/Projects"],
      "discoveryMaxDepth": 3,
      "notificationsEnabled": true,
      "gitPollSeconds": 2,
      "activityPollSeconds": 1,
      "restoreSession": true,
      "focusAccent": "accent",
      "attentionStyle": "loud",
      "attentionAccent": "alert",
      "alertBehavior": "stock",
      "controlChannelEnabled": true,
      "controlAllowRun": false
    }

    """
}
