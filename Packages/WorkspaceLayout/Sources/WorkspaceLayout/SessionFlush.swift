import Foundation

/// Which snapshot a save writes when the workspace may already be empty.
///
/// **The window this exists for is about one second wide.** Session writes are
/// coalesced on a timer, closing the last window empties the app's window list
/// before the terminate flush runs, and a save that finds no windows has nothing
/// to snapshot. So a sidebar dragged, a pane split, or a tab reordered in the last
/// second before the window closed was scheduled, then flushed against an empty
/// workspace, and never landed. The file kept whatever the previous write left,
/// which is up to a second stale and looks exactly like the app ignoring the last
/// thing the owner did.
///
/// Refusing to write anything in that state is still right, and it is the other
/// half of the rule: an empty workspace must never overwrite a good session file,
/// or quitting by closing the window would erase what a relaunch is supposed to
/// restore. This type keeps both by holding the snapshot taken while the last
/// window was still in place and handing it to the flush that follows.
///
/// In `WorkspaceLayout` rather than beside its caller in the app target for the
/// reason the app target keeps proving: it needs no `NSWindow` and no descriptor,
/// so it is answerable by a test, and a rule that lives where no test can reach it
/// is a rule that gets to be wrong for four days.
public struct SessionFlush: Sendable, Equatable {
    /// The snapshot taken while a window was still open, kept for the flush that
    /// arrives after the last one has gone.
    ///
    /// Private with no accessor. The only questions worth asking are the two
    /// methods below, and a readable property would invite a caller to make the
    /// decision a third time.
    private var held: SessionSnapshot?

    public init() {}

    /// Records the workspace as it stands, to be written if the next flush finds
    /// no windows left.
    ///
    /// Called on the way out of the last window and not on every save. Holding on
    /// every save would be correct and would also mean carrying a full snapshot
    /// for the entire life of the app to serve a case that arises once.
    public mutating func hold(_ snapshot: SessionSnapshot) {
        held = snapshot
    }

    /// What to write now, or nil for "write nothing".
    ///
    /// - Parameter live: the workspace as it is, or nil when no window is left to
    ///   snapshot. A caller with windows open passes one and always gets it back:
    ///   a held snapshot never wins over a live one, because the live one is
    ///   newer by construction.
    ///
    /// Consuming rather than peeking. A held snapshot describes one moment that
    /// has passed, and a second flush answering with it again would write a
    /// workspace the app has since left, which is how a closed window would come
    /// back on the launch after next.
    public mutating func resolve(live: SessionSnapshot?) -> SessionSnapshot? {
        if let live {
            held = nil
            return live
        }
        defer { held = nil }
        return held
    }
}
