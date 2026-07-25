import Foundation
import Testing

@testable import WorkspaceMenu

@Suite struct MenuCommandTests {
    @Test func theCommandTagRoundTripsForEveryCommand() {
        // Also the duplicate-tag test. init(tag:) takes the first match in
        // allCases, so two commands sharing an integer resolve to the earlier one
        // and the later one fails this round trip. A hand-written second switch
        // would have let the duplicate through in both directions.
        for command in MenuCommand.allCases {
            #expect(MenuCommand(tag: command.tag) == command)
        }
    }

    @Test func noCommandClaimsTheZeroTagAnUntaggedItemCarries() {
        // NSMenuItem.tag is 0 for every item and separator nobody tagged, so a
        // command at 0 would make validation resolve a separator to a real
        // command.
        #expect(MenuCommand(tag: 0) == nil)
        #expect(!MenuCommand.allCases.contains { $0.tag == 0 })
    }

    @Test func anUnclaimedTagResolvesToNoCommand() {
        #expect(MenuCommand(tag: 999) == nil)
    }

    @Test func rawValuesAreDistinctFromEachOther() {
        // The raw value is a command's written name for a diagnostics dump and a
        // later config file. Two cases cannot collide while the compiler derives
        // them, but a hand-written raw value could, and this is where that shows.
        let names = MenuCommand.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
    }
}
