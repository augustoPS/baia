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
        #expect(SettingsWriter.keyOrder.count == Set(SettingsWriter.keyOrder).count)
    }

    // MARK: - Patching

    private func members(_ document: JSONValue, _ edits: [SettingsEdit]) -> [String: JSONValue] {
        guard case let .object(members)? = SettingsWriter.patch(document, edits: edits) else {
            Issue.record("patch did not produce an object")
            return [:]
        }
        return members
    }

    @Test func patchingWritesOnlyTheEditedKey() {
        // The whole contract. A one-field edit touches one member and nothing
        // beside it, which is what keeps an edit made outside the window alive.
        let original = JSONValue.object([
            "fontSize": .number(11),
            "backgroundHex": .string("#abcdef"),
            "projectRoots": .array([.string("~/keep")]),
        ])
        let patched = members(original, [.fontSize(15)])
        #expect(patched["fontSize"] == .number(15))
        #expect(patched["backgroundHex"] == .string("#abcdef"))
        #expect(patched["projectRoots"] == .array([.string("~/keep")]))
        #expect(patched.count == 3)
    }

    @Test func patchingKeepsAKeyTheDecoderDoesNotKnow() {
        let original = JSONValue.object(["somethingTheOwnerAdded": .string("keep me")])
        #expect(members(original, [.themeName("Midnight")])["somethingTheOwnerAdded"] == .string("keep me"))
    }

    @Test func patchingRefusesANonObjectDocument() {
        // Starting from an empty object here is what destroyed a mangled file's
        // contents in the audit's S4 fixture. Nil is the refusal the store turns
        // into a structured failure.
        #expect(SettingsWriter.patch(.string("not a document"), edits: [.fontSize(14)]) == nil)
        #expect(SettingsWriter.patch(.array([]), edits: [.fontSize(14)]) == nil)
    }

    @Test func anUnsetFontFamilyIsWrittenAsNullRatherThanOmitted() {
        // The decoder reads null as unset, and the default file says null. Omitting
        // the key would decode the same and leave the owner without the spelling.
        #expect(members(.object([:]), [.fontFamily(nil)])["fontFamily"] == .null)
    }

    @Test func projectRootsBelowHomeAreWrittenWithATilde() {
        // `Settings.projectRoots` holds expanded paths because the decoder expands
        // them, so an undo that writes the running value back has to abbreviate
        // it again or the file stops moving between machines.
        let home = NSHomeDirectory()
        let patched = members(.object([:]), [.projectRoots([home + "/Projects", "/opt/src"])])
        #expect(patched["projectRoots"] == .array([.string("~/Projects"), .string("/opt/src")]))
    }

    // MARK: - The full document

    @Test func theFullDocumentNamesEveryKeyTheDecoderReads() {
        guard case let .object(members) = SettingsWriter.document(from: .defaultSettings) else {
            Issue.record("not an object")
            return
        }
        #expect(Set(members.keys) == SettingsDecoder.knownKeys)
    }

    @Test func theFullDocumentDecodesBackToWhatItWasBuiltFrom() {
        var settings = Settings.defaultSettings
        settings.fontFamily = "SF Mono"
        settings.projectRoots = [NSHomeDirectory() + "/src"]
        settings.chromeStyle = .sheer
        settings.controlAllowRun = true
        let text = SettingsWriter.serialize(SettingsWriter.document(from: settings))
        let result = SettingsDecoder.decode(Data(text.utf8))
        #expect(result.settings == settings)
        #expect(result.invalidKeys.isEmpty)
        #expect(result.unknownKeys.isEmpty)
        #expect(text.contains("\"projectRoots\": [\"~/src\"]"))
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
        guard let fontFamily, let fontSize, let themeName else {
            Issue.record("a key is missing from the output")
            return
        }
        #expect(fontFamily.lowerBound < fontSize.lowerBound)
        #expect(fontSize.lowerBound < themeName.lowerBound)
    }

    @Test func theCanonicalOrderIsNotMerelyAlphabetical() {
        // `backgroundHex` sorts before `themeName` but is declared after it, so a
        // serializer that quietly sorted would pass the test above and fail here.
        let text = SettingsWriter.serialize(.object([
            "themeName": .string("Midnight"),
            "backgroundHex": .string("#141414"),
        ]))
        guard let themeName = text.range(of: "\"themeName\""),
              let backgroundHex = text.range(of: "\"backgroundHex\"")
        else {
            Issue.record("a key is missing from the output")
            return
        }
        #expect(themeName.lowerBound < backgroundHex.lowerBound)
    }

    @Test func unknownKeysComeAfterTheKnownOnesAndInAStableOrder() {
        let text = SettingsWriter.serialize(.object([
            "themeName": .string("Midnight"),
            "zzzOwnerKey": .string("z"),
            "aaaOwnerKey": .string("a"),
        ]))
        guard let themeName = text.range(of: "\"themeName\""),
              let aaa = text.range(of: "\"aaaOwnerKey\""),
              let zzz = text.range(of: "\"zzzOwnerKey\"")
        else {
            Issue.record("a key is missing from the output")
            return
        }
        #expect(themeName.lowerBound < aaa.lowerBound)
        #expect(aaa.lowerBound < zzz.lowerBound)
    }

    @Test func theSerializedDocumentEndsWithASingleNewline() {
        let text = SettingsWriter.serialize(.object(["themeName": .string("Midnight")]))
        #expect(text.hasSuffix("}\n"))
        #expect(!text.hasSuffix("}\n\n"))
    }

    @Test func serializingANonObjectYieldsAnEmptyDocumentRatherThanGarbage() {
        #expect(SettingsWriter.serialize(.string("not a document")) == "{}\n")
    }

    @Test func serializingAndReparsingYieldsTheSameDocument() {
        let document = SettingsWriter.document(from: .defaultSettings)
        #expect(JSONValue.parse(Data(SettingsWriter.serialize(document).utf8)) == document)
    }
}
