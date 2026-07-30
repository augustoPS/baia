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

    // MARK: - Serializing

    @Test func theDocumentIsSerializedInTheCanonicalOrder() {
        let text = SettingsWriter.serialize(.object([
            "themeName": .string("Midnight"),
            "fontSize": .number(14),
            "fontFamily": .null,
        ]))
        let fontFamily = text.range(of: "\"fontFamily\"")
        let fontSize = text.range(of: "\"fontSize\"")
        let themeName = text.range(of: "\"themeName\"")
        #expect(fontFamily != nil)
        #expect(fontSize != nil)
        #expect(themeName != nil)
        guard let fontFamily, let fontSize, let themeName else { return }
        // The order `keyOrder` declares: fontFamily, fontSize, themeName. Sorted
        // would put fontFamily, fontSize, themeName too, so the assertion is
        // deliberately made against a document whose declared order differs from
        // alphabetical further down.
        #expect(fontFamily.lowerBound < fontSize.lowerBound)
        #expect(fontSize.lowerBound < themeName.lowerBound)
    }

    @Test func thecanonicalOrderIsNotMerelyAlphabetical() {
        // `backgroundHex` sorts before `themeName` but is declared after it, so a
        // serializer that quietly sorted would pass the test above and fail here.
        let text = SettingsWriter.serialize(.object([
            "themeName": .string("Midnight"),
            "backgroundHex": .string("#141414"),
        ]))
        let themeName = text.range(of: "\"themeName\"")
        let backgroundHex = text.range(of: "\"backgroundHex\"")
        #expect(themeName != nil)
        #expect(backgroundHex != nil)
        guard let themeName, let backgroundHex else { return }
        #expect(themeName.lowerBound < backgroundHex.lowerBound)
    }

    @Test func aKeyTheDecoderDoesNotKnowIsKeptRatherThanDropped() {
        // The decoder already reports an unread key on stderr. Deleting the
        // owner's text on top of having told them about it is worse than carrying
        // it, and carrying it costs nothing.
        let text = SettingsWriter.serialize(.object([
            "themeName": .string("Midnight"),
            "somethingTheOwnerAdded": .string("keep me"),
        ]))
        #expect(text.contains("\"somethingTheOwnerAdded\": \"keep me\""))
    }

    @Test func unknownKeysComeAfterTheKnownOnesAndInAStableOrder() {
        // Sorted rather than in dictionary order, so two writes of the same
        // document produce the same bytes and the file does not churn under
        // version control.
        let text = SettingsWriter.serialize(.object([
            "themeName": .string("Midnight"),
            "zzzOwnerKey": .string("z"),
            "aaaOwnerKey": .string("a"),
        ]))
        let themeName = text.range(of: "\"themeName\"")
        let aaa = text.range(of: "\"aaaOwnerKey\"")
        let zzz = text.range(of: "\"zzzOwnerKey\"")
        #expect(themeName != nil)
        #expect(aaa != nil)
        #expect(zzz != nil)
        guard let themeName, let aaa, let zzz else { return }
        #expect(themeName.lowerBound < aaa.lowerBound)
        #expect(aaa.lowerBound < zzz.lowerBound)
    }

    @Test func theSerializedDocumentEndsWithASingleNewline() {
        // Matching `defaultFileContents`, and keeping the file well formed for any
        // line-oriented tool the owner points at it.
        let text = SettingsWriter.serialize(.object(["themeName": .string("Midnight")]))
        #expect(text.hasSuffix("}\n"))
        #expect(!text.hasSuffix("}\n\n"))
    }

    @Test func serializingANonObjectYieldsAnEmptyDocumentRatherThanGarbage() {
        #expect(SettingsWriter.serialize(.string("not a document")) == "{}\n")
    }

    @Test func serializingAndReparsingYieldsTheSameDocument() {
        let document = SettingsWriter.patch(.object([:]), with: .defaultSettings)
        #expect(JSONValue.parse(Data(SettingsWriter.serialize(document).utf8)) == document)
    }

    // MARK: - The round trip

    /// `defaultSettings` with `key` moved to some other valid value.
    ///
    /// Parameterised over the key name rather than over a closure, because a
    /// `@Test(arguments:)` case has to be `Sendable` and a mutating closure is
    /// not. The switch is exhaustive over ``SettingsWriter/appearanceKeys`` and a
    /// test below proves it.
    private static func moved(_ key: String) -> Settings? {
        var settings = Settings.defaultSettings
        switch key {
        case "themeName": settings.themeName = "Midnight"
        case "backgroundHex": settings.backgroundHex = "#0A0B0C"
        case "backgroundOpacity": settings.backgroundOpacity = 0.42
        case "backgroundBlur": settings.backgroundBlur = false
        case "windowPadding": settings.windowPadding = 17
        case "windowPaddingBalance": settings.windowPaddingBalance = false
        case "transparentTitlebar": settings.transparentTitlebar = false
        case "fontFamily": settings.fontFamily = "SF Mono"
        case "fontSize": settings.fontSize = 13.5
        case "cursorStyle": settings.cursorStyle = .bar
        case "focusAccent": settings.focusAccent = .bone
        case "attentionStyle": settings.attentionStyle = .quiet
        case "attentionAccent": settings.attentionAccent = .accent
        case "alertBehavior": settings.alertBehavior = .derive
        default: return nil
        }
        return settings
    }

    @Test(arguments: SettingsWriter.appearanceKeys.sorted())
    func everyAppearanceKeySurvivesPatchSerializeAndDecode(key: String) {
        // The spec's acceptance criterion. Whatever the writer drops or rewrites
        // is the difference between the settings that were accepted and the ones
        // that take effect, and a whole-struct comparison of the defaults would
        // pass while one key silently reverted, because the other twenty-three
        // carry it.
        guard let settings = Self.moved(key) else {
            Issue.record("no mutation defined for \(key)")
            return
        }
        #expect(settings != .defaultSettings, "\(key) did not change anything")

        let text = SettingsWriter.serialize(SettingsWriter.patch(.object([:]), with: settings))
        let result = SettingsDecoder.decode(Data(text.utf8))

        #expect(result.settings == settings, "\(key) did not survive the round trip")
        #expect(result.invalidKeys.isEmpty, "\(key) produced an invalid value")
        #expect(result.unknownKeys.isEmpty, "\(key) produced an unknown key")
        #expect(!result.documentIsUnreadable, "\(key) produced an unreadable document")
    }

    @Test func everyAppearanceKeyHasAMutationToTestWith() {
        // The parameterised test proves each key it is handed survives. It cannot
        // see a key `moved` forgot, which would fall to `default` and be recorded
        // rather than silently skipped, but only if something iterates the full
        // set. This is that something.
        for key in SettingsWriter.appearanceKeys {
            #expect(Self.moved(key) != nil, "no mutation defined for \(key)")
        }
    }
}
