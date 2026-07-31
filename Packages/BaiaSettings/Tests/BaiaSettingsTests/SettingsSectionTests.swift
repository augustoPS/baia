import Foundation
import Testing

@testable import BaiaSettings

/// The settings window's four sections, and what restoring one of them means.
///
/// In a package rather than beside the view, under the standing rule the app
/// target keeps only what needs AppKit: which fields a section owns and what
/// their defaults are is answerable with no `NSWindow` anywhere near it, and the
/// app target has no test bundle at all.
@Suite struct SettingsSectionTests {
    /// A value that differs from the default in every field any section owns, so
    /// a restore that misses one is visible rather than lucky.
    ///
    /// Built by mutation rather than by a literal, because a literal here would
    /// be a third copy of the field list and would keep compiling while a section
    /// silently stopped covering something.
    private func mutated() -> Settings {
        var settings = Settings.defaultSettings
        settings.themeName = "Solarized Light"
        settings.backgroundHex = "#ffeecc"
        settings.backgroundOpacity = 0.42
        settings.backgroundBlur = !Settings.defaultSettings.backgroundBlur
        settings.fontFamily = "Some Font Nobody Has"
        settings.fontSize = 19.5
        settings.cursorStyle = .underline
        settings.windowPadding = 31
        settings.windowPaddingBalance = !Settings.defaultSettings.windowPaddingBalance
        settings.transparentTitlebar = !Settings.defaultSettings.transparentTitlebar
        settings.focusAccent = .midnight
        settings.attentionStyle = .quiet
        settings.attentionAccent = .accent
        settings.alertBehavior = .derive
        return settings
    }

    @Test func everySectionRestoresItsOwnFieldsToTheDefault() {
        for section in SettingsSection.allCases {
            let restored = mutated().restoring(section)
            for field in section.fields {
                #expect(
                    field.equals(restored, Settings.defaultSettings),
                    "\(section) left \(field.name) off the default"
                )
            }
        }
    }

    /// The half that catches the mistake worth catching. A section that restored
    /// the whole value would pass the test above and would silently undo every
    /// other section's edits.
    @Test func aSectionLeavesEveryOtherSectionAlone() {
        let edited = mutated()
        for section in SettingsSection.allCases {
            let restored = edited.restoring(section)
            for other in SettingsSection.allCases where other != section {
                for field in other.fields {
                    #expect(
                        field.equals(restored, edited),
                        "restoring \(section) moved \(other)'s \(field.name)"
                    )
                }
            }
        }
    }

    /// Restoring all four is the whole window going back to stock, which is the
    /// question the owner opens this for: judging a shipped default needs a way to
    /// reach one.
    @Test func restoringAllFourReachesTheShippedDefault() {
        var settings = mutated()
        for section in SettingsSection.allCases {
            settings = settings.restoring(section)
        }
        #expect(settings == Settings.defaultSettings)
    }

    /// Nothing outside the window's four sections moves, whatever is restored.
    ///
    /// `projectRoots`, the poll intervals and the three control-channel keys are
    /// editable only in the file. A restore reachable from a window must not
    /// silently rewrite a key that window never showed.
    @Test func aRestoreNeverTouchesAFieldTheWindowCannotEdit() {
        var settings = mutated()
        settings.projectRoots = ["/somewhere/else"]
        settings.gitPollSeconds = 11
        settings.controlAllowRun = true
        settings.sidebar = .changes

        var restored = settings
        for section in SettingsSection.allCases {
            restored = restored.restoring(section)
        }

        #expect(restored.projectRoots == ["/somewhere/else"])
        #expect(restored.gitPollSeconds == 11)
        #expect(restored.controlAllowRun)
        #expect(restored.sidebar == .changes)
    }

    /// Drives the `↺` control's enabled state, so a section already at stock says
    /// so rather than offering an action that does nothing. The palette's hint row
    /// is the standing example of why that matters.
    @Test func aSectionKnowsWhetherItIsAlreadyAtTheDefault() {
        for section in SettingsSection.allCases {
            #expect(Settings.defaultSettings.isDefault(section))
            #expect(!mutated().isDefault(section))
            #expect(mutated().restoring(section).isDefault(section))
        }
    }

    /// **The inventory, pinned deliberately.** Two hand-maintained lists is what
    /// killed ⌘Q and ⇧⌘P, and a section list beside a form is exactly that shape:
    /// a control added to `SettingsView` and not to a section would never restore,
    /// with nothing on screen to say so.
    ///
    /// This cannot see the view, so it pins the count and the names instead. Adding
    /// a control means failing this test and updating it on purpose, which is the
    /// cheapest available substitute for deriving both from one value.
    @Test func theWindowsFieldInventoryIsPinned() {
        let names = SettingsSection.allCases.flatMap { section in
            section.fields.map { "\(section.rawValue).\($0.name)" }
        }
        #expect(names == [
            "theme.themeName",
            "theme.backgroundHex",
            "theme.backgroundOpacity",
            "theme.backgroundBlur",
            "text.fontFamily",
            "text.fontSize",
            "text.cursorStyle",
            "window.windowPadding",
            "window.windowPaddingBalance",
            "window.transparentTitlebar",
            "signals.focusAccent",
            "signals.attentionStyle",
            "signals.attentionAccent",
            "signals.alertBehavior",
        ])
    }
}
