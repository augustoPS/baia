import Foundation

/// A repository-relative path fitted to a row that cannot hold all of it.
///
/// The sidebar's changed-file rows draw a path in two inks: the directory faint
/// and the file name in the foreground, because a column of paths under one
/// repository repeats the directory and differs in the name. **What a row loses
/// when it does not fit follows from that**: the directory is context and gives
/// way, the name is the answer to "which file" and does not.
///
/// Design v3 §3. The rule this replaces was `NSLineBreakMode`, which spends the
/// width on both halves at once: head truncation eats into the name at the
/// narrow end, and tail truncation makes `PaneTheme.swift` and `PaneTheme.md`
/// the same row twice.
///
/// Measured in characters rather than points, which is honest only because every
/// string in these rows is `NSFont.monospacedSystemFont(ofSize: 11)` at a 6.62 pt
/// advance. A caller with a proportional font would need a different rule, and
/// there is none in this column.
public enum RowPath {
    /// A path split into the part drawn faint and the part drawn in the
    /// foreground. Concatenated, they are exactly what the row renders.
    public struct Fitted: Equatable, Sendable {
        /// Everything up to and including the last separator, `…/` when the
        /// directories were elided, and empty when there is no room for any of it.
        public let directory: String
        /// The file name, whole unless even it had to give way.
        public let name: String

        public var text: String { directory + name }
    }

    /// The largest rendering of `path` that fits in `budget` characters.
    ///
    /// The ladder, most informative first:
    ///
    /// 1. the whole path
    /// 2. the first directory, `…`, and as many trailing directories as fit
    /// 3. `…/` alone, which still says the file is not at the repository root
    /// 4. the name alone
    /// 5. the name with its stem middle-truncated, keeping the extension
    ///
    /// Step 5 keeps the extension because `PaneTheme.swift` and `PaneTheme.md`
    /// are different files, and a truncation that dropped it would draw one row
    /// twice. A name with no extension, or one whose extension alone would fill
    /// the budget, is middle-truncated whole instead.
    public static func fit(_ path: String, budget: Int) -> Fitted {
        guard budget > 0 else { return Fitted(directory: "", name: "") }
        guard path.count > budget else { return split(path) }

        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let name = components.popLast() else { return Fitted(directory: "", name: "") }
        let directories = components

        // Step 2, greedy from the deepest end: the directories nearest the name
        // are the ones that locate it, and the first is kept because it is the
        // one the reader uses to tell two `Sources/` apart.
        if let first = directories.first {
            for kept in stride(from: directories.count - 1, through: 1, by: -1) {
                let tail = directories.suffix(kept).joined(separator: "/")
                let directory = "\(first)/…/\(tail)/"
                if directory.count + name.count <= budget {
                    return Fitted(directory: directory, name: name)
                }
            }
            let directory = "\(first)/…/"
            if directory.count + name.count <= budget {
                return Fitted(directory: directory, name: name)
            }
        }

        // Step 3. Only worth drawing when there was a directory to lose.
        if !directories.isEmpty, 2 + name.count <= budget {
            return Fitted(directory: "…/", name: name)
        }

        // Step 4.
        if name.count <= budget { return Fitted(directory: "", name: name) }

        // Step 5.
        return Fitted(directory: "", name: truncated(name, budget: budget))
    }

    /// The path unshortened, split at its last separator.
    private static func split(_ path: String) -> Fitted {
        guard let separator = path.lastIndex(of: "/") else {
            return Fitted(directory: "", name: path)
        }
        let after = path.index(after: separator)
        return Fitted(directory: String(path[..<after]), name: String(path[after...]))
    }

    /// A file name shortened to `budget`, keeping its extension.
    ///
    /// The stem gives way from its tail rather than its middle, so what survives
    /// is the front, which is where two names in one directory differ. `PaneTheme`
    /// and `PaneThemePalette` are told apart by their ends, and that is the case a
    /// middle ellipsis would serve; `PaneT…` against `PaneS…` is the case that
    /// happens, and it is the one the eye scans a column for.
    ///
    /// A leading dot is not an extension: `.gitignore` is a name, and splitting it
    /// there would leave a stem of nothing and an "extension" of the whole word,
    /// which then never gives way at all.
    private static func truncated(_ name: String, budget: Int) -> String {
        let dot = name.lastIndex(of: ".")
        let hasExtension = dot.map { $0 != name.startIndex } ?? false
        guard hasExtension, let dot else { return elided(name, budget: budget) }

        let ext = String(name[dot...])
        let stem = String(name[..<dot])
        // One character of stem and the ellipsis are the least this can say. Below
        // that the extension is what has to give, so the whole name is elided.
        guard ext.count + 2 <= budget else { return elided(name, budget: budget) }
        return elided(stem, budget: budget - ext.count) + ext
    }

    /// `text` cut to `budget` characters, the last of them an ellipsis.
    private static func elided(_ text: String, budget: Int) -> String {
        guard budget > 1 else { return budget == 1 ? "…" : "" }
        guard text.count > budget else { return text }
        return text.prefix(budget - 1) + "…"
    }
}
