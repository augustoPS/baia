import PaneControl
import Testing

@testable import PaneCLI

/// The exit statuses, which are the CLI's real return type.
///
/// A caller invoking the socket programs against ``ControlErrorCode``. A caller
/// invoking this tool programs against the number the process exits with, and has
/// nothing else: the message is prose for a human and stderr is not a protocol.
/// So the mapping has to be total, injective, and stable.
@Suite struct ExitStatusTests {
    /// Assembled from `allCases` rather than written out, so a tenth
    /// ``ControlErrorCode`` fails here the moment it is added. The switch in
    /// ``ExitStatus/status(for:)`` has no `default:`, so the compiler catches a
    /// missing case; this catches a case given a number that is already taken,
    /// which the compiler cannot see.
    @Test func everyWireErrorCodeHasAStatusOfItsOwn() {
        let statuses = ControlErrorCode.allCases.map(ExitStatus.status(for:))
        #expect(statuses.count == ControlErrorCode.allCases.count)
        #expect(Set(statuses).count == statuses.count, "two error codes share an exit status")
    }

    /// Ten and up, so "baia answered no" is never mistaken for "the CLI could not
    /// even ask". A script that branched on a wire code and got status 2 would go
    /// looking at the registry instead of at its own environment.
    @Test func noWireStatusCollidesWithAStatusTheCLIDecidesOnItsOwn() {
        let local: Set<Int32> = [
            ExitStatus.ok, ExitStatus.usage, ExitStatus.environment, ExitStatus.transport,
        ]
        #expect(local.count == 4, "the four local statuses are not four distinct numbers")
        for code in ControlErrorCode.allCases {
            let status = ExitStatus.status(for: code)
            #expect(status >= 10, "\(code.rawValue) is below the wire range")
            #expect(!local.contains(status), "\(code.rawValue) reuses a local status")
        }
    }

    /// Pinned against a literal table, for the same reason
    /// `ControlVerbTests.theWireSpellingOfEveryVerbIsPinned` pins the verbs: a
    /// script in somebody's dotfiles branches on `$? -eq 14`, and renumbering is
    /// a break that compiles everywhere and shows up only in their shell.
    @Test func theNumberForEveryWireErrorCodeIsPinned() {
        let expected: [ControlErrorCode: Int32] = [
            .badVersion: 10,
            .badFrame: 11,
            .unknownVerb: 12,
            .badToken: 13,
            .unauthorized: 14,
            .disabled: 15,
            .notFound: 16,
            .refused: 17,
            .internal: 18,
        ]
        // From `allCases`, so a code added without a row fails rather than
        // going unchecked.
        for code in ControlErrorCode.allCases {
            #expect(expected[code] == ExitStatus.status(for: code), "\(code.rawValue) moved")
        }
        #expect(expected.count == ControlErrorCode.allCases.count)
    }

    @Test func theFourLocalStatusesAreTheFourTheSpecNames() {
        #expect(ExitStatus.ok == 0)
        #expect(ExitStatus.usage == 1)
        #expect(ExitStatus.environment == 2)
        #expect(ExitStatus.transport == 3)
    }

    /// The `--help` table is generated from the same two things the process exits
    /// with, so it cannot describe a mapping the binary does not have.
    @Test func theDocumentedMappingCoversEveryCodeAndAgreesWithTheSwitch() {
        let rows = ExitStatus.documentedMapping
        #expect(rows.count == ControlErrorCode.allCases.count)
        for code in ControlErrorCode.allCases {
            guard let row = rows.first(where: { $0.name == code.rawValue }) else {
                Issue.record("\(code.rawValue) has no row in the documented mapping")
                continue
            }
            #expect(row.status == ExitStatus.status(for: code))
            #expect(!row.blurb.isEmpty)
        }
    }
}
