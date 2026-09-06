import Foundation

/// The plain-text operational snapshot copied by the Diagnostics command.
public struct CommandDiagnostics: Sendable, Equatable {
    public let marketingVersion: String
    public let buildVersion: String
    public let bundleIdentifier: String
    public let gitRevision: String?
    public let paneCount: Int
    public let tabCount: Int
    public let configurationPath: String
    public let sessionPath: String
    public let supportDirectoryName: String

    public init(
        marketingVersion: String,
        buildVersion: String,
        bundleIdentifier: String,
        gitRevision: String?,
        paneCount: Int,
        tabCount: Int,
        configurationPath: String,
        sessionPath: String,
        supportDirectoryName: String
    ) {
        self.marketingVersion = marketingVersion
        self.buildVersion = buildVersion
        self.bundleIdentifier = bundleIdentifier
        self.gitRevision = gitRevision
        self.paneCount = paneCount
        self.tabCount = tabCount
        self.configurationPath = configurationPath
        self.sessionPath = sessionPath
        self.supportDirectoryName = supportDirectoryName
    }

    public var text: String {
        """
        Baia: \(marketingVersion) (\(buildVersion))
        Bundle: \(bundleIdentifier)
        Revision: \(gitRevision ?? "unknown")
        Panes: \(paneCount)
        Tabs: \(tabCount)
        Configuration: \(configurationPath)
        Session: \(sessionPath)
        Support directory: \(supportDirectoryName)
        """
    }
}
