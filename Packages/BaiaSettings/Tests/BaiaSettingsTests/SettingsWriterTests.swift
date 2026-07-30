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

    // MARK: - Patching

    /// The members of a patched document, or a recorded failure.
    private func members(
        _ document: JSONValue,
        _ settings: Settings
    ) -> [String: JSONValue] {
        guard case let .object(members) = SettingsWriter.patch(document, with: settings) else {
            Issue.record("patch did not produce an object")
            return [:]
        }
        return members
    }

    @Test func patchingWritesTheAppearanceKeysFromTheSettings() {
        var settings = Settings.defaultSettings
        settings.fontSize = 14
        settings.themeName = "Midnight"
        settings.backgroundHex = "#0A0A0A"
        settings.backgroundOpacity = 0.7
        settings.cursorStyle = .bar

        let patched = members(.object([:]), settings)
        #expect(patched["fontSize"] == .number(14))
        #expect(patched["themeName"] == .string("Midnight"))
        #expect(patched["backgroundHex"] == .string("#0A0A0A"))
        #expect(patched["backgroundOpacity"] == .number(0.7))
        #expect(patched["cursorStyle"] == .string("bar"))
    }

    @Test func anUnsetFontFamilyIsWrittenAsNullRatherThanOmitted() {
        // The decoder reads null as unset, and the default file says null. Omitting
        // the key would decode the same and leave the owner without the spelling,
        // which is the gap `theWrittenDefaultFileNamesEveryKeyTheDecoderReads`
        // exists to catch for the other document.
        var settings = Settings.defaultSettings
        settings.fontFamily = nil
        #expect(members(.object([:]), settings)["fontFamily"] == .null)
    }

    @Test func asetFontFamilyIsWrittenAsItsString() {
        var settings = Settings.defaultSettings
        settings.fontFamily = "SF Mono"
        #expect(members(.object([:]), settings)["fontFamily"] == .string("SF Mono"))
    }

    @Test func patchingLeavesTheOutOfScopeKeysExactlyAsTheyWere() {
        // The window edits appearance and shares the document with everything else.
        // Rewriting a key it does not show is how a setting changes without anyone
        // choosing it.
        let original = JSONValue.object([
            "projectRoots": .array([.string("~/Projects"), .string("~/src")]),
            "discoveryMaxDepth": .number(5),
            "notificationsEnabled": .bool(false),
            "gitPollSeconds": .number(9),
            "activityPollSeconds": .number(4),
            "restoreSession": .bool(false),
            "sidebar": .string("files"),
            "controlChannelEnabled": .bool(false),
            "controlAllowRun": .bool(true),
            "optionAsAlt": .bool(false),
        ])
        let patched = members(original, .defaultSettings)
        #expect(patched["projectRoots"] == .array([.string("~/Projects"), .string("~/src")]))
        #expect(patched["discoveryMaxDepth"] == .number(5))
        #expect(patched["notificationsEnabled"] == .bool(false))
        #expect(patched["gitPollSeconds"] == .number(9))
        #expect(patched["activityPollSeconds"] == .number(4))
        #expect(patched["restoreSession"] == .bool(false))
        #expect(patched["sidebar"] == .string("files"))
        #expect(patched["controlChannelEnabled"] == .bool(false))
        #expect(patched["controlAllowRun"] == .bool(true))
        #expect(patched["optionAsAlt"] == .bool(false))
    }

    @Test func patchingPreservesTheTildeInProjectRoots() {
        // The single reason this is read-modify-write rather than an encoder.
        // `Settings.projectRoots` holds expanded paths because the decoder expands
        // them, so anything built from `Settings` writes an absolute path and
        // breaks a file meant to move between machines. Named separately from the
        // test above because it is the hazard, not an example of it.
        let original = JSONValue.object(["projectRoots": .array([.string("~/Projects")])])
        var settings = Settings.defaultSettings
        settings.projectRoots = ["/Users/someone/Projects"]
        #expect(members(original, settings)["projectRoots"]
            == .array([.string("~/Projects")]))
    }

    @Test func patchingANonObjectDocumentStartsFromEmptyRatherThanDiscardingTheWrite() {
        // A hand-mangled file decodes as unreadable, and accept still has to land
        // the fourteen keys rather than silently doing nothing.
        #expect(members(.string("not a document"), .defaultSettings)["themeName"]
            == .string(Settings.defaultSettings.themeName))
    }

    @Test func patchingTouchesEveryAppearanceKeyAndNoOther() {
        // Pins the two sets against each other from the outside: whatever `patch`
        // writes into an empty document is exactly what it claims to own. A key
        // added to `appearanceKeys` but never assigned would show up here, and so
        // would an assignment for a key not declared.
        #expect(Set(members(.object([:]), .defaultSettings).keys)
            == SettingsWriter.appearanceKeys)
    }
}
