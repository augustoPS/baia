import PaneControl
import Testing

@testable import PaneCLI

/// `--help` is the only documentation the tool ships with, and it is generated
/// from the same declarations the binary runs on. These check that the generation
/// still covers everything, because a table that silently lost a row is worse
/// than no table: it reads as complete.
@Suite struct HelpTests {
    /// The acceptance criterion from the plan: the help states what the process
    /// exits with, for every code there is.
    @Test func helpDocumentsTheExitStatusForEveryWireErrorCode() {
        let text = Help.text
        #expect(text.contains("EXIT STATUS"))
        for code in ControlErrorCode.allCases {
            let status = ExitStatus.status(for: code)
            #expect(text.contains(code.rawValue), "\(code.rawValue) is not in the help")
            #expect(text.contains(String(status)), "status \(status) is not in the help")
        }
    }

    /// The four the CLI decides on its own, with the sentence that tells a reader
    /// which side of the socket the failure was on.
    @Test func helpDocumentsTheFourStatusesTheCLIDecidesOnItsOwn() {
        let text = Help.text
        #expect(text.contains("the request was answered ok"))
        #expect(text.contains("Nothing was sent."))
        #expect(text.contains("not a pane of a baia with a channel"))
        #expect(text.contains("the socket refused, died, or answered unreadably"))
    }

    /// Every verb is listed. Walked from `allCases`, so a verb added to the
    /// package and wired into the parser still cannot ship undocumented.
    @Test func helpListsEveryVerbTheParserAccepts() {
        let text = Help.text
        for verb in ControlVerb.allCases {
            #expect(text.contains(verb.rawValue), "\(verb.rawValue) is not in the help")
        }
    }

    /// `move` is spelled out rather than left to the walk above, which only asks
    /// that the word appear somewhere and would be satisfied by "move the divider"
    /// on the `resize` line. The one verb that names two panes has to show both.
    @Test func helpShowsBothEndsOfAMove() {
        #expect(Help.text.contains("move <PANE> --beside <PANE>"))
    }

    /// The scope rule in one paragraph, because a `list` showing one entry is the
    /// thing readers report as a bug.
    @Test func helpStatesTheScopeRule() {
        let text = Help.text
        #expect(text.contains("SCOPE"))
        #expect(text.contains("list showing one entry is a pane that created nothing"))
    }

    /// The three environment variables, and which of them is a credential. A
    /// reader who thinks `BAIA_PANE` is a secret will guard the wrong value.
    @Test func helpNamesTheThreeEnvironmentVariablesAndWhatEachOneIs() {
        let text = Help.text
        #expect(text.contains("BAIA_SOCK"))
        #expect(text.contains("BAIA_TOKEN"))
        #expect(text.contains("BAIA_PANE"))
        #expect(text.contains("Never on disk, never in argv"))
        #expect(text.contains("Not a credential"))
    }

    /// Every event kind is named, walked from `allCases`, so a kind added to the
    /// package cannot ship as something `--kinds` takes and nothing documents.
    @Test func helpNamesSubscribeAndItsKinds() {
        let text = Help.text
        #expect(text.contains("subscribe"))
        #expect(text.contains("--kinds"))
        for kind in ControlEventKind.allCases {
            #expect(text.contains(kind.rawValue), "\(kind.rawValue) is not in the help")
        }
    }

    /// The version line carries the protocol version, which is the number a
    /// `badVersion` failure is about. Read from ``ControlWire`` rather than
    /// written out, so a bumped protocol cannot ship with a stale line.
    @Test func theVersionLineCarriesTheProtocolVersionItWasBuiltWith() {
        #expect(Help.version.contains("v\(ControlWire.version)"))
    }
}
