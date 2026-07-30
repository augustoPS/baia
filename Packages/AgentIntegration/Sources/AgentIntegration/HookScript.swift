import Foundation

/// The hook baia installs, and the exact bytes it writes to disk.
public enum HookScript {
    /// The script as it lives in the repository, with no managed header.
    ///
    /// A real `.sh` file rather than a Swift string literal, so it stays
    /// shellcheckable and syntax-highlighted and can be exercised by piping a
    /// payload into it. `.embedInCode` carries it into the binary, because
    /// `install-hooks` writes it outside the app bundle.
    public static var body: String {
        String(decoding: PackageResources.baia_agent_state_sh, as: UTF8.self)
    }

    /// What lands on disk: the shebang, then the managed header, then the script.
    ///
    /// **The header goes after the shebang and not before it.** A `#!` that is not
    /// the first two bytes of a file is not a shebang, and the kernel would refuse
    /// to execute what it introduced.
    public static func installable(version: Int = ManagedHeader.currentVersion) -> String {
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.hasPrefix("#!") == true else {
            // No shebang to preserve, so the header simply leads.
            return ManagedHeader.emit(version: version) + "\n" + body
        }
        let shebang = lines.removeFirst()
        return shebang + "\n" + ManagedHeader.emit(version: version) + "\n" + lines.joined(separator: "\n")
    }
}
