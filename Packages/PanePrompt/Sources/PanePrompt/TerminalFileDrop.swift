import Foundation

/// Builds one prompt insertion from local file URLs. Filesystem eligibility is
/// the caller's responsibility. No payload is returned for a partial drop.
public enum TerminalFileDrop {
    /// `nil` means a URL is not a plain, local, absolute file URL. Path refusals
    /// use the same reasons and quoting rules as sidebar prompt insertion.
    public static func resolve(fileURLs: [URL]) -> PromptPath.Resolution? {
        guard !fileURLs.isEmpty else { return .refuse(.emptyPath) }

        var payload: [UInt8] = []
        for url in fileURLs {
            guard url.isFileURL,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
                  components.host == nil || components.host == ""
                    || components.host?.lowercased() == "localhost",
                  components.user == nil, components.password == nil,
                  components.port == nil, components.query == nil,
                  components.fragment == nil,
                  components.path.hasPrefix("/"),
                  let decodedPath = components.percentEncodedPath.removingPercentEncoding,
                  decodedPath.utf8.elementsEqual(components.path.utf8)
            else { return nil }

            // Require one unambiguous URL decoding before quoting a filesystem path.
            // Drop the initial slash because PromptPath joins the root and path.
            switch PromptPath.resolve(
                repositoryRelativePath: Array(components.path.utf8.dropFirst()),
                repositoryRoot: "/",
                workingDirectory: nil
            ) {
            case let .send(bytes): payload.append(contentsOf: bytes)
            case let .refuse(reason): return .refuse(reason)
            }
        }
        return .send(payload)
    }
}
