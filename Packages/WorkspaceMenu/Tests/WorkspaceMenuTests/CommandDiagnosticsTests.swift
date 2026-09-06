import Testing

@testable import WorkspaceMenu

@Suite struct CommandDiagnosticsTests {
    @Test func theClipboardDumpNamesEveryOperationalPathAndCount() {
        let diagnostics = CommandDiagnostics(
            marketingVersion: "0.3.0",
            buildVersion: "7",
            bundleIdentifier: "pasqualotto.baia.dev",
            gitRevision: "abc123",
            paneCount: 5,
            tabCount: 2,
            configurationPath: "/tmp/config.json",
            sessionPath: "/tmp/session.json",
            supportDirectoryName: "baia-dev"
        )

        #expect(diagnostics.text == """
        Baia: 0.3.0 (7)
        Bundle: pasqualotto.baia.dev
        Revision: abc123
        Panes: 5
        Tabs: 2
        Configuration: /tmp/config.json
        Session: /tmp/session.json
        Support directory: baia-dev
        """)
    }

    @Test func anAbsentBuildRevisionIsReportedHonestly() {
        let diagnostics = CommandDiagnostics(
            marketingVersion: "unknown",
            buildVersion: "unknown",
            bundleIdentifier: "unknown",
            gitRevision: nil,
            paneCount: 0,
            tabCount: 0,
            configurationPath: "/config",
            sessionPath: "/session",
            supportDirectoryName: "baia"
        )

        #expect(diagnostics.text.contains("Revision: unknown"))
    }
}
