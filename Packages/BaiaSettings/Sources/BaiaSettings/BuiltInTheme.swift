/// Baia's bundled purple palettes. Values use Ghostty's sRGB hex notation.
public struct BuiltInTheme: Sendable, Equatable {
    public let name: String
    public let background: String
    public let foreground: String
    public let cursorColor: String
    public let cursorText: String
    public let selectionBackground: String
    public let selectionForeground: String
    public let palette: [Int: String]

    public static func named(_ name: String) -> BuiltInTheme? {
        all.first { $0.name == name }
    }

    public static let all: [BuiltInTheme] = [
        BuiltInTheme(
            name: "Midnight", background: "#12101e", foreground: "#e6e0ef",
            cursorColor: "#b8a3ee", cursorText: "#12101e",
            selectionBackground: "#403454", selectionForeground: "#e6e0ef",
            palette: [
                0: "#12101e",
                1: "#e797a9",
                2: "#9ac8b0",
                3: "#e3c28f",
                4: "#9aafe8",
                5: "#b8a3ee",
                6: "#92cbd1",
                7: "#e6e0ef",
                8: "#a9a0bb",
                9: "#eba7b6",
                10: "#a9d0bc",
                11: "#e7cba0",
                12: "#a9bbeb",
                13: "#c3b1f1",
                14: "#a2d3d8",
                15: "#eae5f1",
            ]
        ),
        BuiltInTheme(
            name: "Aubergine", background: "#1b111d", foreground: "#eee3e9",
            cursorColor: "#d4a4d7", cursorText: "#1b111d",
            selectionBackground: "#51354f", selectionForeground: "#eee3e9",
            palette: [
                0: "#1b111d",
                1: "#e79ba6",
                2: "#a6c6a7",
                3: "#e5c294",
                4: "#a8b5e2",
                5: "#d4a4d7",
                6: "#9bcaca",
                7: "#eee3e9",
                8: "#b8a3b2",
                9: "#ebaab3",
                10: "#b3cfb4",
                11: "#e9cba4",
                12: "#b5c0e6",
                13: "#dab2dd",
                14: "#aad2d2",
                15: "#f1e7ec",
            ]
        ),
        BuiltInTheme(
            name: "Iris", background: "#17151d", foreground: "#e8e4ed",
            cursorColor: "#c0b3db", cursorText: "#17151d",
            selectionBackground: "#454052", selectionForeground: "#e8e4ed",
            palette: [
                0: "#17151d",
                1: "#dda0ad",
                2: "#a9c4b1",
                3: "#dbc49d",
                4: "#a6b6da",
                5: "#c0b3db",
                6: "#a0c8cd",
                7: "#e8e4ed",
                8: "#aaa3b8",
                9: "#e2aeb9",
                10: "#b6cdbd",
                11: "#e0cdac",
                12: "#b3c1e0",
                13: "#c9bee0",
                14: "#aed0d4",
                15: "#ebe8f0",
            ]
        ),
        BuiltInTheme(
            name: "Obsidian", background: "#0f0d15", foreground: "#e9e2f2",
            cursorColor: "#c2a0f0", cursorText: "#0f0d15",
            selectionBackground: "#403052", selectionForeground: "#e9e2f2",
            palette: [
                0: "#0f0d15",
                1: "#e996aa",
                2: "#97c9ac",
                3: "#e2c088",
                4: "#9daee8",
                5: "#c2a0f0",
                6: "#8dcbd2",
                7: "#e9e2f2",
                8: "#a99dbb",
                9: "#eca6b7",
                10: "#a7d1b8",
                11: "#e6c99a",
                12: "#acbaeb",
                13: "#cbaef2",
                14: "#9ed3d9",
                15: "#ece6f4",
            ]
        ),
    ]
}
