import Foundation
import Testing

@testable import BaiaSettings

@Suite struct SettingsEditTests {
    @Test func theKeyListIsTheDecodersKeyList() {
        // `SettingsKey` is the one list everything else is derived from or pinned
        // against, and this is the pin against the decoder's own declaration.
        #expect(Set(SettingsKey.allCases.map(\.rawValue)) == SettingsDecoder.knownKeys)
    }

    @Test func onlyTheRetiredTitlebarKeyIsInert() {
        #expect(SettingsKey.allCases.filter { !$0.isActive } == [.transparentTitlebar])
    }

    // MARK: - Every key round-trips

    /// `defaultSettings` with `key` moved to some other valid value.
    private static func moved(_ key: SettingsKey) -> SettingsEdit {
        switch key {
        case .fontFamily: .fontFamily("SF Mono")
        case .fontSize: .fontSize(13.5)
        case .themeName: .themeName("Midnight")
        case .backgroundHex: .backgroundHex("#0a0b0c")
        case .backgroundOpacity: .backgroundOpacity(0.6)
        case .backgroundBlur: .backgroundBlur(false)
        case .windowPadding: .windowPadding(17)
        case .windowPaddingBalance: .windowPaddingBalance(false)
        case .transparentTitlebar: .transparentTitlebar(false)
        case .optionAsAlt: .optionAsAlt(false)
        case .cursorStyle: .cursorStyle(.bar)
        case .projectRoots: .projectRoots([NSHomeDirectory() + "/src", "/opt/work"])
        case .discoveryMaxDepth: .discoveryMaxDepth(5)
        case .notificationsEnabled: .notificationsEnabled(false)
        case .gitPollSeconds: .gitPollSeconds(9)
        case .activityPollSeconds: .activityPollSeconds(4)
        case .restoreSession: .restoreSession(false)
        case .focusAccent: .focusAccent(.bone)
        case .attentionStyle: .attentionStyle(.quiet)
        case .attentionAccent: .attentionAccent(.accent)
        case .alertBehavior: .alertBehavior(.derive)
        case .chromeStyle: .chromeStyle(.solid)
        case .sidebar: .sidebar(.files)
        case .controlChannelEnabled: .controlChannelEnabled(false)
        case .controlAllowRun: .controlAllowRun(true)
        case .controlAllowRead: .controlAllowRead(false)
        }
    }

    @Test(arguments: SettingsKey.allCases)
    func everyKeySurvivesEditPatchSerializeAndDecode(key: SettingsKey) {
        // Whatever the writer drops or rewrites is the difference between the
        // value that was accepted and the one that takes effect. A whole-struct
        // comparison of the defaults would pass while one key silently reverted,
        // because the other twenty-five carry it.
        let edit = Self.moved(key)
        #expect(edit.key == key)

        var expected = Settings.defaultSettings
        edit.apply(to: &expected)
        #expect(expected != .defaultSettings, "\(key) did not change anything")

        guard case let .success(valid) = edit.validated() else {
            Issue.record("\(key) did not validate")
            return
        }
        guard let document = SettingsWriter.patch(SettingsWriter.document(from: .defaultSettings), edits: [valid]) else {
            Issue.record("\(key) could not be patched")
            return
        }
        let result = SettingsDecoder.decode(Data(SettingsWriter.serialize(document).utf8))
        #expect(result.settings == expected, "\(key) did not survive the round trip")
        #expect(result.invalidKeys.isEmpty, "\(key) produced an invalid value")
        #expect(result.unknownKeys.isEmpty, "\(key) produced an unknown key")
        #expect(!result.documentIsUnreadable)

        // And back again: the running value reads out as the edit that made it,
        // which is what undo writes.
        var again = Settings.defaultSettings
        SettingsEdit.value(of: key, in: result.settings).apply(to: &again)
        #expect(again == expected, "\(key) did not read back as itself")
    }

    // MARK: - Validation

    @Test func aHexIsNormalizedToSixLowercaseDigits() {
        #expect(SettingsEdit.backgroundHex("#ABC").validated() == .success(.backgroundHex("#aabbcc")))
        #expect(SettingsEdit.backgroundHex(" #14D4F0 ").validated() == .success(.backgroundHex("#14d4f0")))
        #expect(SettingsEdit.backgroundHex("#141414").validated() == .success(.backgroundHex("#141414")))
    }

    @Test(arguments: ["not-a-colour", "141414", "#12345", "#1234567", "#ggg", "", "#１２３"])
    func aHexTheDecoderRejectsIsRefused(text: String) {
        // The same grammar `SettingsDecoder.isColourHex` accepts. The last case is
        // full-width digits, which satisfy `isHexDigit` and which ghostty cannot
        // parse, so the two have to agree on refusing them.
        guard case let .failure(error) = SettingsEdit.backgroundHex(text).validated() else {
            Issue.record("\(text) was accepted")
            return
        }
        #expect(error.key == .backgroundHex)
        #expect(!error.message.isEmpty)
        #expect(SettingsDecoder.decode(Data("{\"backgroundHex\": \"\(text)\"}".utf8)).invalidKeys == ["backgroundHex"])
    }

    @Test func numbersOutsideTheDecodersRangeAreRefused() {
        // The bounds are read off `Settings.Limits`, so the UI and the file cannot
        // disagree about what a legal value is.
        let font = Settings.Limits.fontSize
        #expect(SettingsEdit.fontSize(font.lowerBound).validated() == .success(.fontSize(font.lowerBound)))
        #expect(SettingsEdit.fontSize(font.upperBound).validated() == .success(.fontSize(font.upperBound)))
        if case .success = SettingsEdit.fontSize(font.lowerBound - 0.5).validated() { Issue.record("below the floor accepted") }
        if case .success = SettingsEdit.fontSize(font.upperBound + 0.5).validated() { Issue.record("above the ceiling accepted") }
        if case .success = SettingsEdit.fontSize(.nan).validated() { Issue.record("nan accepted") }
        if case .success = SettingsEdit.fontSize(.infinity).validated() { Issue.record("infinity accepted") }

        if case .success = SettingsEdit.backgroundOpacity(1.01).validated() { Issue.record("opacity above 1 accepted") }
        if case .success = SettingsEdit.windowPadding(-1).validated() { Issue.record("negative padding accepted") }
        if case .success = SettingsEdit.windowPadding(129).validated() { Issue.record("padding above 128 accepted") }
        if case .success = SettingsEdit.discoveryMaxDepth(0).validated() { Issue.record("depth 0 accepted") }
        if case .success = SettingsEdit.discoveryMaxDepth(9).validated() { Issue.record("depth 9 accepted") }
        if case .success = SettingsEdit.gitPollSeconds(0.1).validated() { Issue.record("poll below 0.25 accepted") }
        if case .success = SettingsEdit.activityPollSeconds(3601).validated() { Issue.record("poll above 3600 accepted") }
    }

    @Test func anEmptyFontFamilyMeansTheTerminalsOwnFont() {
        // The control shows "System default" for nil, and typing nothing means
        // exactly that. Writing "" would name a font nobody has, which the decoder
        // rejects.
        #expect(SettingsEdit.fontFamily("").validated() == .success(.fontFamily(nil)))
        #expect(SettingsEdit.fontFamily("   ").validated() == .success(.fontFamily(nil)))
        #expect(SettingsEdit.fontFamily(" SF Mono ").validated() == .success(.fontFamily("SF Mono")))
    }

    @Test func anEmptyThemeNameIsRefused() {
        if case .success = SettingsEdit.themeName(" ").validated() { Issue.record("blank theme accepted") }
    }

    @Test func anEmptyProjectRootIsRefused() {
        if case .success = SettingsEdit.projectRoots(["~/Projects", ""]).validated() { Issue.record("empty root accepted") }
        #expect(SettingsEdit.projectRoots([]).validated() == .success(.projectRoots([])))
    }

    @Test func aProjectRootRoundTripsThroughTheTilde() {
        // The display value is the resolved path; the file keeps the portable
        // spelling; the running value is resolved again. All three agree.
        let home = NSHomeDirectory()
        var settings = Settings.defaultSettings
        SettingsEdit.projectRoots(["~/Projects"]).apply(to: &settings)
        #expect(settings.projectRoots == [home + "/Projects"])
        #expect(SettingsEdit.value(of: .projectRoots, in: settings).jsonValue
            == .array([.string("~/Projects")]))
        #expect(SettingsEdit.projectRoots([home + "/Projects"]).jsonValue == .array([.string("~/Projects")]))
        #expect(SettingsEdit.projectRoots(["/opt/src"]).jsonValue == .array([.string("/opt/src")]))
    }
}
