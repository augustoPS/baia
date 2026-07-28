import Foundation
import Testing

@testable import BaiaSettings

@Suite struct SettingsTests {
    @Test func defaultsReproduceTheOwnersGhosttyConfig() {
        // Every value here is transcribed from vault/projects/ghostty/config.ghostty,
        // the terminal baia has to feel like on a first launch. Nothing in the app
        // would look broken if one of them drifted, which is exactly why it is
        // pinned here rather than left to be noticed by using the app.
        let defaults = Settings.defaultSettings
        #expect(defaults.themeName == "Dark Pastel")
        #expect(defaults.backgroundHex == "#141414")
        #expect(defaults.fontSize == 11.5)
        #expect(defaults.windowPadding == 8)
        #expect(defaults.windowPaddingBalance)
        #expect(defaults.backgroundBlur)
        #expect(defaults.backgroundOpacity == 0.85)
        #expect(defaults.transparentTitlebar)
        #expect(defaults.optionAsAlt)
    }

    @Test func defaultsLeaveTheFontFamilyToGhostty() {
        // The owner's config names no font, so baia must not name one either. A
        // guessed family here would render every pane in a font he never chose and
        // there would be nothing in the config file to explain it.
        #expect(Settings.defaultSettings.fontFamily == nil)
    }

    @Test func defaultProjectRootsAreExpandedRatherThanLeftAsATilde() {
        // A literal `~/Projects` directory exists nowhere, so an unexpanded default
        // would make discovery find no projects at all on a machine with no config
        // file, which is precisely the machine that cannot be debugged from a file.
        #expect(Settings.defaultSettings.projectRoots == [NSHomeDirectory() + "/Projects"])
    }

    @Test func defaultDiscoveryDepthReachesTheNestedProjects() {
        // The workspace nests two levels deep in two places (`website/*`, `skills/*`),
        // so a depth of 1 would miss most of it.
        #expect(Settings.defaultSettings.discoveryMaxDepth >= 2)
    }

    @Test func defaultPollIntervalsAreInsideTheirOwnLimits() {
        // A default outside the range the decoder enforces would mean the shipped
        // config is one the decoder would report as invalid if the owner typed it.
        #expect(Settings.Limits.pollSeconds.contains(Settings.defaultSettings.gitPollSeconds))
        #expect(Settings.Limits.pollSeconds.contains(Settings.defaultSettings.activityPollSeconds))
        #expect(Settings.Limits.fontSize.contains(Settings.defaultSettings.fontSize))
        #expect(Settings.Limits.opacity.contains(Settings.defaultSettings.backgroundOpacity))
        #expect(Settings.Limits.padding.contains(Settings.defaultSettings.windowPadding))
    }

    @Test func theControlChannelIsOnByDefaultAndRunIsNot() {
        // Two different arguments, not one. The channel grants a pane no reach
        // outside itself and its own descendants, so off by default would ship a
        // feature nobody ever sees. `run` is the verb that turns a reach into an
        // execution, so it waits to be asked for by name.
        #expect(Settings.defaultSettings.controlChannelEnabled)
        #expect(!Settings.defaultSettings.controlAllowRun)
    }

    @Test func expandsALeadingTildeAndLeavesAnAbsolutePathAlone() {
        #expect(Settings.expandingTilde("~/Projects/baia") == NSHomeDirectory() + "/Projects/baia")
        #expect(Settings.expandingTilde("/opt/homebrew") == "/opt/homebrew")
    }

    @Test func doesNotExpandEnvironmentVariables() {
        // Deliberate: `$HOME` would work and `$PROJECTS` would not, and the failing
        // case looks like a path that exists rather than like an unexpanded name.
        #expect(Settings.expandingTilde("$HOME/Projects") == "$HOME/Projects")
    }
}
