import Foundation

/// The editing contract behind the Settings window.
///
/// A control proposes one ``SettingsEdit``. This validates it, patches that one
/// key into the file, takes the decoded result as the new running value, hands
/// it to `apply`, and registers the inverse edit with the undo manager. Undo and
/// redo come back through the same path, so both the running configuration and
/// the file move together, and an undo that cannot be written reports why
/// instead of pretending.
///
/// There is no draft. Nothing here stages a value for a later Apply, which is
/// what let the old window overwrite an edit made outside it (audit S2) and
/// discard an edit when the window was reopened (S1).
///
/// Foundation only, so `make test` exercises every transition with a real
/// `UndoManager` and a real file in a fixture directory. The AppKit half is one
/// closure: `apply` is `ConfigurationCenter.adopt(_:)` in the app.
@MainActor
public final class SettingsTransactionController {
    /// The running settings: what the file last decoded to, or the value a
    /// gesture is previewing. The baseline every inverse edit is read from.
    public private(set) var settings: Settings

    /// The window's undo manager. Settable because the window is built after
    /// this object and can change, and nil when there is no window to undo in.
    public var undoManager: UndoManager?

    /// The last write that did not land, or nil once one has. Settings shows it
    /// as the persistent recovery state until a later write succeeds.
    public private(set) var lastFailure: SettingsWriteFailure?

    private let store: SettingsStore
    private let apply: @MainActor (Settings) -> Void

    /// The field a continuous control is dragging, with the value it started
    /// from. One gesture becomes one undo step whose inverse is that origin.
    private var gesture: (key: SettingsKey, origin: SettingsEdit)?

    public init(
        store: SettingsStore,
        settings: Settings,
        undoManager: UndoManager?,
        apply: @escaping @MainActor (Settings) -> Void
    ) {
        self.store = store
        self.settings = settings
        self.undoManager = undoManager
        self.apply = apply
    }

    /// The file's location, for the recovery banner's reveal action.
    public var fileURL: URL { store.url }

    /// What the file is right now. Read fresh, never cached: the file can be
    /// edited by hand while the window is open.
    public func documentState() -> SettingsDocumentState {
        store.inspect()
    }

    // MARK: - Transactions

    /// Validates, writes, applies and registers undo for one edit. Nil means
    /// it landed, or that there was nothing to do.
    ///
    /// An edit equal to the running value writes nothing and registers nothing.
    /// An invalid edit writes nothing, registers nothing and answers the
    /// validation error, so the control keeps its text and shows the reason.
    @discardableResult
    public func commit(_ edit: SettingsEdit, actionName: String) -> SettingsWriteFailure? {
        transact(edit, actionName: actionName)
    }

    private func transact(_ edit: SettingsEdit, actionName: String) -> SettingsWriteFailure? {
        let valid: SettingsEdit
        switch edit.validated() {
        case let .success(value): valid = value
        case let .failure(error): return .validation(error)
        }

        var probe = settings
        valid.apply(to: &probe)
        guard probe != settings else { return nil }

        let inverse = SettingsEdit.value(of: valid.key, in: settings)
        switch store.patch([valid]) {
        case let .failure(failure):
            lastFailure = failure
            return failure
        case let .success(result):
            lastFailure = nil
            settings = result.settings
            apply(settings)
            registerUndo(inverse, actionName: actionName)
            return nil
        }
    }

    /// Registers `inverse` as the undo of the write just made.
    ///
    /// The closure runs ``transact(_:actionName:)`` again, which registers its
    /// own inverse while the manager is undoing, and the manager files that on
    /// the redo stack. One path for the edit, its undo and its redo.
    ///
    /// A manager that does not group by event (the tests' manager, and any
    /// caller registering outside a run loop) has no open group to register
    /// into, so one is opened around the registration. A window's manager
    /// groups per event and has one open already; the manager also opens one
    /// itself while undoing, which is where the redo registration lands.
    private func registerUndo(_ inverse: SettingsEdit, actionName: String) {
        guard let undoManager else { return }
        let opensGroup = undoManager.groupingLevel == 0 && !undoManager.groupsByEvent
        if opensGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { target in
            _ = target.transact(inverse, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        if opensGroup { undoManager.endUndoGrouping() }
    }

    // MARK: - Gestures

    /// Marks the start of a continuous edit of `key`, remembering where it was.
    ///
    /// Idempotent while a gesture is open, so a control that cannot tell the
    /// first drag event from the rest can call it on every one.
    public func beginGesture(_ key: SettingsKey) {
        guard gesture == nil else { return }
        gesture = (key, SettingsEdit.value(of: key, in: settings))
    }

    /// Shows `edit` in the running app without writing it.
    ///
    /// Opens the gesture if none is open. Answers the validation error for an
    /// edit the file would refuse, and moves nothing in that case.
    @discardableResult
    public func previewGesture(_ edit: SettingsEdit) -> SettingsValidationError? {
        beginGesture(edit.key)
        switch edit.validated() {
        case let .failure(error):
            return error
        case let .success(valid):
            var next = settings
            valid.apply(to: &next)
            guard next != settings else { return nil }
            settings = next
            apply(next)
            return nil
        }
    }

    /// Ends the gesture on `edit`: one write, one undo step back to where the
    /// gesture began.
    ///
    /// A failed write puts the running app back on the origin, so what is on
    /// screen matches the file again rather than the value that never landed.
    @discardableResult
    public func endGesture(_ edit: SettingsEdit, actionName: String) -> SettingsWriteFailure? {
        let origin = gesture?.origin ?? SettingsEdit.value(of: edit.key, in: settings)
        gesture = nil

        // The baseline goes back to the origin before the write, so the inverse
        // the transaction records is the gesture's start rather than its last
        // preview frame.
        var base = settings
        origin.apply(to: &base)
        settings = base

        let failure = transact(edit, actionName: actionName)
        if settings == base {
            // Nothing was written: the edit matched the origin, or the write
            // failed. Either way the preview has to come off the screen.
            apply(settings)
        }
        return failure
    }

    /// Drops an open gesture and puts the running app back on its origin.
    public func cancelGesture() {
        guard let gesture else { return }
        self.gesture = nil
        var base = settings
        gesture.origin.apply(to: &base)
        settings = base
        apply(base)
    }

    // MARK: - The file changing underneath

    /// Adopts a value the file watcher decoded after an edit made outside this
    /// controller.
    ///
    /// The baseline moves so the next transaction's inverse is what the file
    /// holds now. Undo entries already registered keep the values they recorded:
    /// an external change to a field is superseded only by the owner's next
    /// explicit edit of that field, which is what the spec asks for.
    ///
    /// Ignored mid-gesture. The preview is what the owner is looking at, and the
    /// write at the gesture's end reads the file fresh anyway.
    public func noteExternalReload(_ reloaded: Settings) {
        guard gesture == nil else { return }
        settings = reloaded
    }

    // MARK: - Repair

    /// Replaces a file ordinary writes refuse, keeping its bytes as a backup.
    ///
    /// The undo stack is cleared on success: every entry in it was recorded
    /// against a document that no longer exists.
    public func repair() -> Result<URL, SettingsWriteFailure> {
        switch store.repair(with: settings) {
        case let .failure(failure):
            lastFailure = failure
            return .failure(failure)
        case let .success(receipt):
            lastFailure = nil
            settings = receipt.result.settings
            apply(settings)
            undoManager?.removeAllActions(withTarget: self)
            return .success(receipt.backupURL)
        }
    }
}
