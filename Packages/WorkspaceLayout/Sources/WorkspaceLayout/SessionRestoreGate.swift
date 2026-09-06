import Foundation

/// Holds the session file closed to writers while a launch-time restore is
/// still reading from it.
///
/// Reconciling a loaded snapshot asks the filesystem once per recorded
/// directory and once per surviving pane, and on a stalled volume those calls
/// block. Moving them off the main thread keeps the app responsive, and it opens
/// a hole: the coalesced autosave, the terminate flush and the Debug drivers can
/// all reach the store before the restore has opened a single window, and a
/// snapshot taken then describes whatever the owner opened in the meantime, not
/// the session on disk. Writing it would replace the file the restore is still
/// working from.
///
/// So a restore is a *generation*. ``begin()`` opens one and refuses saves;
/// ``complete(_:)`` closes it and answers whether the caller holds the
/// generation still expected, so a result that arrives after a quit, or after a
/// newer restore began, is discarded rather than applied over live windows.
/// A value type with no clock and no thread: the caller decides where the work
/// runs and this only decides what may be written and what may be applied.
public struct SessionRestoreGate: Sendable, Equatable {
    /// One restore, as begun. Opaque on purpose: the only thing to do with it
    /// is hand it back to ``complete(_:)``.
    public struct Generation: Sendable, Equatable, Hashable {
        fileprivate let id: UInt64
    }

    private var next: UInt64 = 0
    private var pending: UInt64?

    public init() {}

    /// Whether a restore is still expected.
    public var isPending: Bool { pending != nil }

    /// Whether the session file may be written now.
    ///
    /// False for as long as a restore is pending, whatever the windows on
    /// screen describe: they are not the session that was saved.
    public var allowsSave: Bool { pending == nil }

    /// Opens a restore. A restore already pending is superseded, so its result
    /// will be refused by ``complete(_:)``.
    public mutating func begin() -> Generation {
        next &+= 1
        pending = next
        return Generation(id: next)
    }

    /// Forgets the pending restore without applying anything. Saves are allowed
    /// again, which is right for the one caller that does this: a quit, whose
    /// flush then finds the same file it would have found before launch.
    public mutating func cancel() {
        pending = nil
    }

    /// Closes the pending restore if `generation` is the one expected.
    ///
    /// True exactly once per generation, and never for one that was cancelled
    /// or superseded. A false answer means "do not apply this result".
    public mutating func complete(_ generation: Generation) -> Bool {
        guard pending == generation.id else { return false }
        pending = nil
        return true
    }
}
