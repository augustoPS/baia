import Foundation
import Testing

@testable import BaiaSettings

@Suite struct SettingsWriterTests {
    @Test func theKeyOrderNamesEveryKeyTheDecoderReadsAndNothingElse() {
        // Compared against `SettingsDecoder.knownKeys` rather than a literal, for
        // the reason `SettingsStoreTests` gives about the default file: a literal
        // names the keys this test's author remembered, and a key missing from
        // both it and the order would keep this green while claiming the opposite.
        #expect(Set(SettingsWriter.keyOrder) == SettingsDecoder.knownKeys)
    }

    @Test func theKeyOrderHasNoDuplicates() {
        // A duplicate would emit the key twice and the second would win on reparse,
        // which the set comparison above cannot see.
        #expect(SettingsWriter.keyOrder.count == Set(SettingsWriter.keyOrder).count)
    }
}
