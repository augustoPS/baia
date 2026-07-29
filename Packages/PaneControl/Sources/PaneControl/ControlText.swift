import Foundation

/// The rule every free-text value on this wire obeys: one value is one line.
///
/// Pane output reaches the wire in several places, and each of them is named by
/// whoever runs in the pane: the OSC 9 attention message, the activity label
/// built from a process name, the working directory, a published channel name.
/// `subscribe` prints one event per line and `list` prints one field per line,
/// so a newline in any of those is a pane writing a record of its own into a
/// supervisor's stream. A file called `x\n999 paneClosed <uuid>` is legal on
/// macOS, and the classifier takes a `lastPathComponent`, which splits on "/"
/// alone, so the newline survives all the way to the reader.
///
/// **Flattened rather than escaped, and where the value is built rather than
/// where it is printed.** An escape would have to be undone by every consumer,
/// including the `while read` loop the line format exists for. A renderer-side
/// rule would be one rule with as many readers as there are output formats, and
/// `--json` would keep the raw bytes anyway.
enum ControlText {
    /// Every control scalar replaced by a space.
    ///
    /// The control category and nothing wider: it covers the C0 block, DEL and
    /// C1, which is every scalar a line-oriented reader could take as a
    /// separator. A format character like a zero-width joiner separates no
    /// records, and replacing it would mangle text that is foreign rather than
    /// hostile.
    ///
    /// A space rather than a deletion, so two tokens a newline held apart do not
    /// silently become one word.
    ///
    /// The substitution can only shrink the UTF-8 length, because a C1 control
    /// is two bytes and a space is one. A caller that bounds the result
    /// afterwards therefore keeps its bound.
    static func oneLine(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isControl) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.map { isControl($0) ? " " : $0 }))
    }

    static func oneLine(_ text: String?) -> String? {
        text.map(oneLine)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
    }
}
