import Foundation
import Testing

@testable import BaiaSettings

@Suite struct CursorStyleTests {
    @Test func rawValuesAreGhosttysOwnCursorStyleNames() {
        // The raw value is written into the terminal config verbatim, and ghostty
        // drops a value it cannot parse without a diagnostic. So renaming a case
        // for Swift's sake would leave a cursor setting that reads as applied and
        // does nothing, which no other test in this package could see.
        #expect(CursorStyle.allCases.map(\.rawValue) == ["block", "bar", "underline"])
    }
}
