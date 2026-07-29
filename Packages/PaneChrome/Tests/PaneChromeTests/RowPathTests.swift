import Testing

@testable import PaneChrome

/// The ladder from design v3 §3, checked at the widths that document names.
///
/// The budgets come from the column: 260 pt less a 12 pt inset on each side and
/// the 26 pt marker leaves 210 pt, and at the 6.62 pt advance of
/// `monospacedSystemFont(ofSize: 11)` that is 31 characters. The 120 pt minimum
/// leaves 10.
@Suite struct RowPathTests {
    private let deep = "Packages/PaneChrome/Sources/PaneChrome/PaneTheme.swift"

    @Test func keepsAPathThatFits() {
        let fitted = RowPath.fit("docs/scratch.md", budget: 31)
        #expect(fitted.directory == "docs/")
        #expect(fitted.name == "scratch.md")
    }

    /// A file at the repository root has no directory half at all, and the name
    /// must not be handed an empty prefix that the caller would draw as a stray
    /// separator.
    @Test func keepsARootFileWhole() {
        let fitted = RowPath.fit("README.md", budget: 31)
        #expect(fitted.directory == "")
        #expect(fitted.name == "README.md")
    }

    /// 260 pt, the shipping width. The first directory survives because it is the
    /// one that tells two `Sources/` apart.
    @Test func elidesTheMiddleDirectoriesAtTheShippingWidth() {
        #expect(RowPath.fit(deep, budget: 31).text == "Packages/…/PaneTheme.swift")
    }

    /// Given room, the directories nearest the name come back first: they are the
    /// ones that locate the file.
    @Test func restoresTheDeepestDirectoriesFirstWhenThereIsRoom() {
        #expect(RowPath.fit(deep, budget: 40).text == "Packages/…/PaneChrome/PaneTheme.swift")
        #expect(RowPath.fit(deep, budget: 48).text == "Packages/…/Sources/PaneChrome/PaneTheme.swift")
    }

    /// 200 pt. Every directory collapses, and the `…/` stays because "not at the
    /// root" is still worth two characters.
    @Test func collapsesEveryDirectoryWhenTheFirstNoLongerFits() {
        #expect(RowPath.fit(deep, budget: 22).text == "…/PaneTheme.swift")
    }

    /// 160 pt. The directory goes entirely rather than the name losing a glyph.
    @Test func dropsTheDirectoryBeforeTouchingTheName() {
        #expect(RowPath.fit(deep, budget: 16).text == "PaneTheme.swift")
    }

    /// The 120 pt floor, which is the only place the name gives way.
    @Test func middleTruncatesTheStemAtTheFloor() {
        let fitted = RowPath.fit(deep, budget: 10)
        #expect(fitted.directory == "")
        #expect(fitted.name == "Pan….swift")
        #expect(fitted.name.count == 10)
    }

    /// **The extension is what makes two rows two files.** A tail truncation would
    /// draw these as one row twice, which is the argument for eliding the
    /// directory rather than the name in the first place.
    @Test func keepsTheExtensionSoTwoFilesStayTwoRows() {
        let swift = RowPath.fit("Sources/PaneTheme.swift", budget: 12)
        let markdown = RowPath.fit("Sources/PaneTheme.md", budget: 12)
        #expect(swift.name.hasSuffix(".swift"))
        #expect(markdown.name.hasSuffix(".md"))
        #expect(swift.name != markdown.name)
    }

    /// A leading dot is a name, not an extension. Splitting `.gitignore` there
    /// would leave a stem of nothing and hand the whole word to the extension,
    /// which then never truncates.
    @Test func treatsADotfileAsANameRatherThanAnExtension() {
        let fitted = RowPath.fit("Sources/.gitignore", budget: 6)
        #expect(fitted.name.count == 6)
        #expect(fitted.name == ".giti…")
    }

    /// An extension with no room for a stem beside it has to give way too, or the
    /// rule would return something wider than the budget it was handed.
    @Test func truncatesTheWholeNameWhenTheExtensionAloneWouldFillTheBudget() {
        let fitted = RowPath.fit("Sources/Rendering.storyboard", budget: 8)
        #expect(fitted.name.count == 8)
        #expect(fitted.text.count <= 8)
    }

    /// Nothing the caller draws may be wider than what it asked for, at any width
    /// down to zero. The row is clipped by the column, so an overrun would be
    /// invisible here and a lost file name in the app.
    @Test func neverExceedsTheBudget() {
        let paths = [
            deep,
            "README.md",
            "docs/scratch.md",
            "Sources/Workspace/Rendering/GridGeometry.swift",
            "a/b/c/d/e/f/g/h.swift",
            ".gitignore",
            "Sources/no-extension-here",
        ]
        for path in paths {
            for budget in 0 ... 60 {
                let fitted = RowPath.fit(path, budget: budget)
                #expect(
                    fitted.text.count <= budget,
                    "\(path) at \(budget) rendered \(fitted.text.count) characters"
                )
            }
        }
    }

    /// The two halves are what the row draws in two inks, so they have to
    /// reassemble into the rendering rather than being an approximation of it.
    @Test func theTwoHalvesAreTheRendering() {
        let fitted = RowPath.fit(deep, budget: 31)
        #expect(fitted.directory + fitted.name == fitted.text)
    }
}
