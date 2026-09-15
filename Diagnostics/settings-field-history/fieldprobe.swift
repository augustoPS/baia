import AppKit
import BaiaSettings
import PaneChrome

// Does a focused, untouched number or text field overwrite an undone value
// when focus leaves it, and does the repair keep every edit the owner did
// type, every refusal the owner has to correct, and the locale the owner
// types in?
//
// The shape found on 2026-09-10, on an isolated app (native proof
// `s02-number-undo-leave.json`): the Typography page has its Font size field
// focused, showing 14, and nobody types. ⌘Z writes 11.5 to the file and the
// stepper beside the field shows 11.5, but the field keeps 14, because
// `refresh` skipped any field whose `currentEditor()` was non-nil, and a
// field has an editor for as long as it has focus. Clicking the Window
// toolbar item ends editing, `controlTextDidEndEditing` committed whatever
// the field held, and 14 went back over the undone 11.5.
//
// `NumberControl` and `TextControl` live in `Sources/`, which has no test
// target, and the question needs a field editor, so it is a probe. It
// compiles the shipped `SettingsControls.swift` verbatim against a recording
// `SettingsEditing` and drives one control at a time in a window that is
// never ordered on screen. It is `settings-colour-history`'s harness pointed
// at the two other text-bearing controls; the colour one keeps its own probe.
//
// **No window on screen, no focus taken.** The window is created and never
// ordered front; `makeFirstResponder` moves the window's own responder chain,
// which is what starts and ends the field editor's session, and does not make
// the window key or the app active. Nothing is composited, and the keyboard
// stays where it was. The activation policy is `.accessory`, as in
// `override-wires`, and there is no `orderFront`, `makeKey`, `activate` or
// `pkill` in this file.
//
// `run.sh` compiles the probe twice: once against the working tree, once
// against the revision that carried the bug, and every arm that names the bug
// must fail on the second build. That is the red run, kept alongside the
// green one for as long as the revision exists.

// MARK: - a recording editor

/// The window's side of `SettingsEditing`, reduced to what a control can
/// observe: the running value, every write it proposes, and a refresh after
/// each one, exactly as `SettingsWindowController.refresh()` runs after each
/// transaction. Three keys are applied, one per control under test:
/// `fontSize` and `discoveryMaxDepth` for `NumberControl`, `themeName` for
/// `TextControl`. Neither control previews or ends a gesture, so those paths
/// stop the probe rather than record.
final class RecordingEditor: SettingsEditing {
    private(set) var settings = Settings.defaultSettings
    private(set) var commits: [SettingsEdit] = []
    private var history: [Settings] = []
    private var future: [Settings] = []
    var onChange: ((Settings) -> Void)?

    init(fontSize: Double, themeName: String) {
        settings.fontSize = fontSize
        settings.themeName = themeName
    }

    func commit(_ edit: SettingsEdit, actionName: String) -> SettingsValidationError? {
        commits.append(edit)
        return apply(edit)
    }

    func preview(_ edit: SettingsEdit) -> SettingsValidationError? {
        fatalError("neither control under test previews; got \(edit)")
    }

    func endGesture(_ edit: SettingsEdit, actionName: String) -> SettingsValidationError? {
        fatalError("neither control under test ends a gesture; got \(edit)")
    }

    /// ⌘Z as the transaction controller performs it: the previous value is
    /// written back and every page refreshes.
    func undo() {
        guard let previous = history.popLast() else { fatalError("nothing to undo") }
        future.append(settings)
        settings = previous
        onChange?(settings)
    }

    /// ⇧⌘Z, the same way.
    func redo() {
        guard let next = future.popLast() else { fatalError("nothing to redo") }
        history.append(settings)
        settings = next
        onChange?(settings)
    }

    private func apply(_ edit: SettingsEdit) -> SettingsValidationError? {
        switch edit.validated() {
        case let .failure(error):
            return error
        case let .success(valid):
            var next = settings
            switch valid {
            case let .fontSize(size): next.fontSize = size
            case let .discoveryMaxDepth(depth): next.discoveryMaxDepth = depth
            case let .themeName(name): next.themeName = name
            default: fatalError("unexpected key \(valid.key)")
            }
            // A write equal to the file is dropped, as the transaction
            // controller drops it, so a duplicate proposal shows up in
            // `commits` and nowhere else.
            guard next != settings else { return nil }
            history.append(settings)
            future.removeAll()
            settings = next
            onChange?(settings)
            return nil
        }
    }
}

// MARK: - the rig

/// One control in an offscreen window, with its field and stepper found by
/// walking the shipped view tree rather than reaching into the class.
struct Rig {
    let window: NSWindow
    let editor: RecordingEditor
    let control: SettingsControlBase
    let field: NSTextField
    let stepper: NSStepper?

    init(fontSize: Double = 14, themeName: String = "Dark Pastel", make: (RecordingEditor) -> SettingsControlBase) {
        editor = RecordingEditor(fontSize: fontSize, themeName: themeName)
        control = make(editor)
        editor.onChange = { [control] settings in control.refresh(settings) }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(control.view)
        control.view.frame = NSRect(x: 8, y: 8, width: 380, height: 100)
        control.refresh(editor.settings)

        var fields: [NSTextField] = []
        var steppers: [NSStepper] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, field.isEditable { fields.append(field) }
            if let stepper = view as? NSStepper { steppers.append(stepper) }
            view.subviews.forEach(walk)
        }
        walk(control.view)
        guard fields.count == 1, steppers.count <= 1 else {
            fatalError("expected one editable field and at most one stepper, found \(fields.count) and \(steppers.count)")
        }
        field = fields[0]
        stepper = steppers.first
    }

    /// The Typography page's Font size control, built with the arguments
    /// `SettingsPages` gives it.
    static func fontSize(_ editor: RecordingEditor) -> SettingsControlBase {
        NumberControl(
            range: Settings.Limits.fontSize,
            step: 0.5,
            fractionDigits: 1,
            unit: "pt",
            accessibilityLabel: "Font size",
            actionName: "Change Font Size",
            editor: editor,
            read: { $0.fontSize },
            edit: { .fontSize($0) }
        )
    }

    /// The Workspace page's Discovery depth control, the integer-backed one.
    static func discoveryDepth(_ editor: RecordingEditor) -> SettingsControlBase {
        NumberControl(
            range: Settings.Limits.discoveryDepth,
            step: 1,
            fractionDigits: 0,
            unit: "levels",
            accessibilityLabel: "Discovery depth",
            actionName: "Change Discovery Depth",
            editor: editor,
            read: { Double($0.discoveryMaxDepth) },
            edit: { .discoveryMaxDepth(Int($0.rounded())) }
        )
    }

    /// A `TextControl` on the theme name. No page builds one today; this is
    /// the shipped class driven the way a page would.
    static func themeName(_ editor: RecordingEditor) -> SettingsControlBase {
        TextControl(
            placeholder: nil,
            width: 200,
            accessibilityLabel: "Theme",
            actionName: "Change Theme",
            editor: editor,
            read: { $0.themeName },
            edit: { .themeName($0) }
        )
    }

    /// Whether the field has a live field editor, which is the state a page
    /// opens in.
    var fieldIsEditing: Bool { field.currentEditor() != nil }

    /// What the field editor shows, which is what the owner sees. Read off the
    /// editor rather than `stringValue`, because the getter validates editing
    /// and would copy the editor's text back into the cell, hiding a mismatch.
    var editorText: String { (field.currentEditor() as? NSTextView)?.string ?? field.stringValue }

    /// The error line under the control, hidden until a validation error.
    var errorShown: Bool {
        var labels: [NSTextField] = []
        func walk(_ view: NSView) {
            if let label = view as? NSTextField, !label.isEditable, label.textColor == .systemRed { labels.append(label) }
            view.subviews.forEach(walk)
        }
        walk(control.view)
        return labels.contains { !$0.isHidden }
    }

    func focusField() {
        guard window.makeFirstResponder(field), fieldIsEditing else {
            fatalError("the field did not start editing")
        }
    }

    /// Focus leaving the field, as a toolbar click does.
    func leaveField() {
        guard window.makeFirstResponder(nil) else { fatalError("the field refused to end editing") }
        guard !fieldIsEditing else { fatalError("the field still has an editor after focus left") }
    }

    /// Keystrokes: the field editor's own insertion path, which is what posts
    /// the change the control hears as `controlTextDidChange`.
    func type(_ text: String) {
        guard let editorView = field.currentEditor() as? NSTextView else { fatalError("no field editor to type into") }
        let whole = NSRange(location: 0, length: (editorView.string as NSString).length)
        editorView.insertText(text, replacementRange: whole)
    }

    /// Typing a value and leaving, which is the one way to give the recording
    /// editor a history for ⌘Z to walk.
    func typeAndLeave(_ text: String) {
        focusField()
        type(text)
        leaveField()
    }

    /// A stepper click, delivered the way AppKit delivers it: the stepper
    /// takes the value and fires its action.
    func step(to value: Double) {
        guard let stepper else { fatalError("this control has no stepper") }
        stepper.doubleValue = value
        guard stepper.sendAction(stepper.action, to: stepper.target) else { fatalError("the stepper's action was not delivered") }
    }
}

// MARK: - the history the app has

/// The window's side of `SettingsEditing` with the app's own history: a real
/// `SettingsTransactionController` writing a scratch `config.json`, and one
/// real `UndoManager` the window hands to its field editor through
/// `windowWillReturnUndoManager`, exactly as `SettingsWindowController` does.
/// Typing undo and transaction undo then share one stack, which the recording
/// editor above cannot show: its `undo()` writes the previous value straight
/// back and the field editor's own undo never runs.
final class HistoryEditor: NSObject, SettingsEditing, NSWindowDelegate {
    let store: SettingsStore
    let undoManager = UndoManager()
    private(set) var controller: SettingsTransactionController!
    private(set) var commits: [SettingsEdit] = []
    var onChange: ((Settings) -> Void)?

    var settings: Settings { controller.settings }
    var fileFontSize: Double { store.load().settings.fontSize }

    init(fileURL: URL, fontSize: Double) {
        store = SettingsStore(fileURL: fileURL)
        super.init()
        _ = store.writeDefaultIfAbsent()
        guard case .success = store.patch([.fontSize(fontSize)]) else {
            fatalError("could not seed the scratch file with fontSize \(fontSize)")
        }
        controller = SettingsTransactionController(
            store: store,
            settings: store.load().settings,
            undoManager: undoManager
        ) { [weak self] settings in self?.onChange?(settings) }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undoManager }

    func commit(_ edit: SettingsEdit, actionName: String) -> SettingsValidationError? {
        commits.append(edit)
        switch controller.commit(edit, actionName: actionName) {
        case nil: return nil
        case let .validation(error)?: return error
        case let failure?: fatalError("scratch write failed: \(failure.message)")
        }
    }

    func preview(_ edit: SettingsEdit) -> SettingsValidationError? {
        fatalError("the control under test does not preview; got \(edit)")
    }

    func endGesture(_ edit: SettingsEdit, actionName: String) -> SettingsValidationError? {
        fatalError("the control under test does not end a gesture; got \(edit)")
    }

    /// The end of one event. The manager groups by event and opened a group on
    /// the first registration; with no event loop that group stays open until
    /// the run loop waits, so one pump closes it the way the next keystroke's
    /// event boundary would. The fallback names the case where the pump did
    /// not reach the manager's observer.
    func endEvent() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        if undoManager.groupingLevel > 0 { undoManager.endUndoGrouping() }
    }

    /// ⌘Z as the Edit menu delivers it: the shared manager undoes its top
    /// group, whether that group holds typing or a transaction.
    func undo() { undoManager.undo() }
}

/// The Font size control against `HistoryEditor`, in a window whose undo
/// manager is the editor's. Same never-ordered window, same view walk.
final class HistoryRig {
    let directory: URL
    let window: NSWindow
    let editor: HistoryEditor
    let control: SettingsControlBase
    let field: NSTextField
    let stepper: NSStepper?

    init(fontSize: Double) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("baia-field-history-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fatalError("could not create scratch directory: \(error)")
        }
        editor = HistoryEditor(fileURL: directory.appendingPathComponent("config.json"), fontSize: fontSize)
        control = NumberControl(
            range: Settings.Limits.fontSize,
            step: 0.5,
            fractionDigits: 1,
            unit: "pt",
            accessibilityLabel: "Font size",
            actionName: "Change Font Size",
            editor: editor,
            read: { $0.fontSize },
            edit: { .fontSize($0) }
        )
        editor.onChange = { [control] settings in control.refresh(settings) }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.delegate = editor
        window.contentView?.addSubview(control.view)
        control.view.frame = NSRect(x: 8, y: 8, width: 380, height: 100)
        control.refresh(editor.settings)

        var fields: [NSTextField] = []
        var steppers: [NSStepper] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, field.isEditable { fields.append(field) }
            if let stepper = view as? NSStepper { steppers.append(stepper) }
            view.subviews.forEach(walk)
        }
        walk(control.view)
        guard fields.count == 1, steppers.count == 1 else {
            fatalError("expected one editable field and one stepper, found \(fields.count) and \(steppers.count)")
        }
        field = fields[0]
        stepper = steppers.first
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    var fieldIsEditing: Bool { field.currentEditor() != nil }
    var editorText: String { (field.currentEditor() as? NSTextView)?.string ?? field.stringValue }

    func focusField() {
        guard window.makeFirstResponder(field), fieldIsEditing else {
            fatalError("the field did not start editing")
        }
    }

    func leaveField() {
        guard window.makeFirstResponder(nil) else { fatalError("the field refused to end editing") }
        guard !fieldIsEditing else { fatalError("the field still has an editor after focus left") }
    }

    func type(_ text: String) {
        guard let editorView = field.currentEditor() as? NSTextView else { fatalError("no field editor to type into") }
        let whole = NSRange(location: 0, length: (editorView.string as NSString).length)
        editorView.insertText(text, replacementRange: whole)
    }

    /// One keystroke at the end of the text and one Backspace, through the
    /// field editor's own insertion and deletion. The text ends where it
    /// began; the control heard two changes. The caret is placed before each
    /// step: focus selects the whole text, and a Backspace against that
    /// selection deletes it rather than the keystroke (seen 2026-09-11).
    func typeAndBackspace(_ text: String) {
        guard let editorView = field.currentEditor() as? NSTextView else { fatalError("no field editor to type into") }
        let before = editorView.string
        let end = NSRange(location: (before as NSString).length, length: 0)
        editorView.setSelectedRange(end)
        editorView.insertText(text, replacementRange: end)
        guard editorView.string == before + text else {
            fatalError("the keystroke did not append: field shows \(editorView.string), expected \(before + text)")
        }
        editorView.setSelectedRange(NSRange(location: (editorView.string as NSString).length, length: 0))
        editorView.deleteBackward(nil)
        guard editorView.string == before else {
            fatalError("Backspace did not remove the keystroke: field shows \(editorView.string), expected \(before)")
        }
    }
}

// MARK: - arms

var failures: [String] = []

func expect(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

/// The owner's locale, as the control's own formatter reads it: the string
/// the owner would type for a value, and the string the field shows for one.
let locale: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 1
    return formatter
}()

func spell(_ value: Double) -> String {
    locale.string(from: value as NSNumber) ?? "\(value)"
}

let opening = 11.5
let typed = 14.0
let later = 20.0

// MARK: number, bug arms

/// The native finding, up to the toolbar click: a focused field nobody typed
/// in follows ⌘Z the way the stepper beside it does.
func numberMirrorWhileFocused() {
    let rig = Rig(fontSize: opening, make: Rig.fontSize)
    rig.typeAndLeave(spell(typed))
    expect(rig.editor.settings.fontSize == typed, "setup: typed \(typed) did not land, running value is \(rig.editor.settings.fontSize)")
    rig.focusField()
    rig.editor.undo()
    expect(rig.editor.settings.fontSize == opening, "⌘Z did not restore \(opening)")
    expect(rig.stepper?.doubleValue == opening, "after ⌘Z the stepper shows \(rig.stepper?.doubleValue ?? .nan), expected \(opening)")
    expect(rig.fieldIsEditing, "⌘Z ended the field's editing session")
    expect(rig.editorText == spell(opening), "after ⌘Z the focused field shows \(rig.editorText), expected \(spell(opening))")
}

/// The native finding in full: ⌘Z with the caret in an untouched field, then
/// focus leaves. The undone value stands and nothing is proposed.
func numberUndoThenLeave() {
    let rig = Rig(fontSize: opening, make: Rig.fontSize)
    rig.typeAndLeave(spell(typed))
    rig.focusField()
    rig.editor.undo()
    rig.leaveField()
    expect(rig.editor.commits == [.fontSize(typed)], "leaving after ⌘Z proposed \(rig.editor.commits), expected only the setup's [.fontSize(\(typed))]")
    expect(rig.editor.settings.fontSize == opening, "running value is \(rig.editor.settings.fontSize) after ⌘Z and leaving, expected \(opening)")
    expect(rig.editorText == spell(opening), "field shows \(rig.editorText), expected \(spell(opening))")
}

/// Focus in and out of an untouched field proposes nothing. The buggy
/// revision committed the opening value on every focus loss, a write the
/// transaction controller dropped as equal to the file, so this grades the
/// proposal rather than the file.
func numberLeaveUntouched() {
    let rig = Rig(fontSize: opening, make: Rig.fontSize)
    rig.focusField()
    rig.leaveField()
    expect(rig.editor.commits.isEmpty, "leaving an untouched field proposed \(rig.editor.commits)")
    expect(rig.editorText == spell(opening), "field shows \(rig.editorText), expected \(spell(opening))")
}

/// A stepper click mid-edit replaces the typed text with its own value and
/// writes once; leaving the field afterwards proposes nothing more.
func numberStepperReplacesTyping() {
    let rig = Rig(fontSize: opening, make: Rig.fontSize)
    rig.focusField()
    rig.type(spell(later))
    rig.step(to: 12)
    expect(rig.editorText == spell(12), "after the stepper the field shows \(rig.editorText), expected \(spell(12))")
    expect(rig.editor.settings.fontSize == 12, "the stepper's value did not reach the running value")
    rig.leaveField()
    expect(rig.editor.commits == [.fontSize(12)], "commits were \(rig.editor.commits), expected the stepper's [.fontSize(12)] alone")
}

/// A keystroke and a Backspace leave the text as it was, then ⌘Z on the app's
/// own stack undoes the last write. Nothing is pending, so the undone value
/// must show in the field and leaving must propose nothing. A flag raised on
/// the first keystroke and lowered only by a commit is still up after the
/// Backspace: the refresh skips the text, the field freezes at the old value,
/// and leaving writes it over the undone one (independent review D1,
/// 2026-09-11). The same shape follows a hand edit of the file while the flag
/// is up. Driven against a real `SettingsTransactionController` and the one
/// manager the window hands its field editor, so the ⌘Z is the app's.
func numberKeystrokeBackspaceThenHistoryUndo() {
    let rig = HistoryRig(fontSize: opening)
    defer { rig.cleanup() }
    rig.focusField()
    rig.type(spell(typed))
    rig.leaveField()
    rig.editor.endEvent()
    expect(rig.editor.fileFontSize == typed, "setup: typed \(typed) did not land, file is \(rig.editor.fileFontSize)")
    expect(rig.editor.undoManager.canUndo, "setup: the commit registered no undo on the window's manager")

    rig.focusField()
    rig.typeAndBackspace("2")
    rig.editor.endEvent()
    expect(rig.editorText == spell(typed), "a keystroke and a Backspace left the field at \(rig.editorText), expected \(spell(typed))")
    expect(rig.editor.fileFontSize == typed, "a keystroke and a Backspace wrote the file: \(rig.editor.fileFontSize)")

    rig.editor.undo()
    expect(rig.editor.fileFontSize == opening, "⌘Z left the file at \(rig.editor.fileFontSize), expected \(opening)")
    expect(rig.stepper?.doubleValue == opening, "after ⌘Z the stepper shows \(rig.stepper?.doubleValue ?? .nan), expected \(opening)")
    expect(rig.fieldIsEditing, "⌘Z ended the field's editing session")
    expect(rig.editorText == spell(opening), "after ⌘Z the focused field shows \(rig.editorText), expected \(spell(opening))")

    rig.leaveField()
    expect(rig.editor.commits == [.fontSize(typed)], "leaving after ⌘Z proposed \(rig.editor.commits), expected only the setup's [.fontSize(\(typed))]")
    expect(rig.editor.fileFontSize == opening, "leaving wrote \(rig.editor.fileFontSize) over the undone \(opening)")
}

/// Report only, always exit 0, not in `run.sh`'s lists: what the field editor's
/// undo is wired to in this rig. Asked for after the first run showed typing
/// registering nothing on the window's manager, so a typing-undo arm could not
/// be written. Prints the field editor's `allowsUndo`, the cell's, which
/// manager the editor answers, and what the shared manager holds after typing
/// and after the event closes.
func undoWiring() {
    let rig = HistoryRig(fontSize: opening)
    defer { rig.cleanup() }
    rig.focusField()
    guard let editorView = rig.field.currentEditor() as? NSTextView else { fatalError("no field editor") }
    let shared = rig.editor.undoManager
    print("  field editor allowsUndo: \(editorView.allowsUndo)")
    print("  cell allowsUndo: \((rig.field.cell as? NSTextFieldCell)?.allowsUndo ?? false)")
    print("  editor.undoManager is the window's: \(editorView.undoManager === rig.window.undoManager)")
    print("  editor.undoManager is the shared one: \(editorView.undoManager === shared)")
    print("  editor.undoManager is nil: \(editorView.undoManager == nil)")
    rig.type(spell(later))
    print("  after typing: shared canUndo \(shared.canUndo), groupingLevel \(shared.groupingLevel)")
    if let own = editorView.undoManager, own !== shared {
        print("  after typing: editor's own manager canUndo \(own.canUndo), groupingLevel \(own.groupingLevel)")
    }
    rig.editor.endEvent()
    print("  after the event closed: shared canUndo \(shared.canUndo), groupingLevel \(shared.groupingLevel)")
    if let own = editorView.undoManager, own !== shared {
        print("  after the event closed: editor's own manager canUndo \(own.canUndo)")
    }
}

// MARK: number, guard arms

/// Typed text is committed once, when focus leaves, in the owner's locale.
func numberTypedCommit() {
    let rig = Rig(fontSize: opening, make: Rig.fontSize)
    rig.focusField()
    rig.type(spell(later))
    expect(rig.editor.commits.isEmpty, "typing proposed \(rig.editor.commits) before focus left")
    rig.leaveField()
    expect(rig.editor.commits == [.fontSize(later)], "commits were \(rig.editor.commits), expected [.fontSize(\(later))]")
    expect(rig.editor.settings.fontSize == later, "running value is \(rig.editor.settings.fontSize), expected \(later)")
    expect(!rig.errorShown, "a valid number left the error line showing")
    expect(rig.editorText == spell(later), "field shows \(rig.editorText), expected \(spell(later))")
}

/// A fractional value typed and shown with the locale's own separator: what
/// the owner types is what the formatter spells, and it round-trips. `run.sh`
/// runs this arm under a second locale and checks the separator it prints.
func numberLocaleTyped() {
    let separator = Locale.current.decimalSeparator ?? "?"
    let half = 12.5
    expect(spell(half).contains(separator), "the locale spells \(half) as \(spell(half)) without its separator '\(separator)'")
    let rig = Rig(fontSize: opening, make: Rig.fontSize)
    rig.typeAndLeave(spell(half))
    expect(rig.editor.commits == [.fontSize(half)], "typing \(spell(half)) proposed \(rig.editor.commits), expected [.fontSize(\(half))]")
    expect(!rig.errorShown, "typing \(spell(half)) left the error line showing")
    expect(rig.editorText == spell(half), "field shows \(rig.editorText), expected \(spell(half))")
    rig.editor.undo()
    expect(rig.editorText == spell(opening), "after ⌘Z the field shows \(rig.editorText), expected \(spell(opening))")
    rig.editor.redo()
    expect(rig.editorText == spell(half), "after ⇧⌘Z the field shows \(rig.editorText), expected \(spell(half))")
    print("  decimal separator '\(separator)'")
}

/// ⌘Z while the owner is mid-edit does not replace what they typed; the
/// stepper follows, and what they typed is what lands.
func numberTypedSurvivesUndo() {
    let rig = Rig(fontSize: opening, make: Rig.fontSize)
    rig.typeAndLeave(spell(typed))
    rig.focusField()
    rig.type(spell(later))
    rig.editor.undo()
    expect(rig.stepper?.doubleValue == opening, "after ⌘Z the stepper shows \(rig.stepper?.doubleValue ?? .nan), expected \(opening)")
    expect(rig.editorText == spell(later), "⌘Z replaced typed text with \(rig.editorText)")
    rig.leaveField()
    expect(rig.editor.commits == [.fontSize(typed), .fontSize(later)], "commits were \(rig.editor.commits), expected [.fontSize(\(typed)), .fontSize(\(later))]")
    expect(rig.editor.settings.fontSize == later, "running value is \(rig.editor.settings.fontSize), expected the typed \(later)")
}

/// Text that is not a number shows its reason, writes nothing, stays through
/// ⌘Z, and clears when corrected.
func numberInvalidKept() {
    let rig = Rig(fontSize: opening, make: Rig.fontSize)
    rig.typeAndLeave(spell(typed))
    rig.typeAndLeave("abc")
    expect(rig.editor.commits == [.fontSize(typed)], "invalid text proposed \(rig.editor.commits), expected only the setup's write")
    expect(rig.errorShown, "text that is not a number showed no error")
    expect(rig.editorText == "abc", "the invalid text was replaced with \(rig.editorText)")
    expect(rig.editor.settings.fontSize == typed, "invalid text changed the running value to \(rig.editor.settings.fontSize)")
    rig.editor.undo()
    expect(rig.stepper?.doubleValue == opening, "after ⌘Z the stepper shows \(rig.stepper?.doubleValue ?? .nan), expected \(opening)")
    expect(rig.editorText == "abc", "⌘Z replaced uncorrected invalid text with \(rig.editorText)")
    expect(rig.errorShown, "⌘Z hid the error under uncorrected text")
    rig.typeAndLeave(spell(later))
    expect(!rig.errorShown, "a correction left the error line showing")
    expect(rig.editor.settings.fontSize == later, "the correction did not land, running value is \(rig.editor.settings.fontSize)")
}

/// A number outside the file's range is refused with the range, not clamped.
func numberOutOfRange() {
    let rig = Rig(fontSize: opening, make: Rig.fontSize)
    rig.typeAndLeave("3")
    expect(rig.editor.commits.isEmpty, "3 proposed \(rig.editor.commits); the range is \(Settings.Limits.fontSize)")
    expect(rig.errorShown, "3 showed no error")
    expect(rig.editorText == "3", "the refused text was replaced with \(rig.editorText)")
    expect(rig.editor.settings.fontSize == opening, "3 changed the running value to \(rig.editor.settings.fontSize)")
}

/// The integer-backed control refuses a fraction before `edit` can round it,
/// and takes a whole number.
func numberWholeLevels() {
    let rig = Rig(make: Rig.discoveryDepth)
    let start = rig.editor.settings.discoveryMaxDepth
    rig.typeAndLeave(spell(2.5))
    expect(rig.editor.commits.isEmpty, "\(spell(2.5)) proposed \(rig.editor.commits) on a whole-number control")
    expect(rig.errorShown, "\(spell(2.5)) showed no error on a whole-number control")
    expect(rig.editor.settings.discoveryMaxDepth == start, "a fraction changed the depth to \(rig.editor.settings.discoveryMaxDepth)")
    rig.typeAndLeave("4")
    expect(rig.editor.commits == [.discoveryMaxDepth(4)], "commits were \(rig.editor.commits), expected [.discoveryMaxDepth(4)]")
    expect(!rig.errorShown, "a whole number left the error line showing")
}

// MARK: text, bug arms

let openingName = "Dark Pastel"
let typedName = "Nord"
let laterName = "Solarized"

/// A focused text field nobody typed in follows ⌘Z.
func textMirrorWhileFocused() {
    let rig = Rig(themeName: openingName, make: Rig.themeName)
    rig.typeAndLeave(typedName)
    expect(rig.editor.settings.themeName == typedName, "setup: typed \(typedName) did not land")
    rig.focusField()
    rig.editor.undo()
    expect(rig.fieldIsEditing, "⌘Z ended the field's editing session")
    expect(rig.editorText == openingName, "after ⌘Z the focused field shows \(rig.editorText), expected \(openingName)")
}

/// ⌘Z with the caret in an untouched text field, then focus leaves.
func textUndoThenLeave() {
    let rig = Rig(themeName: openingName, make: Rig.themeName)
    rig.typeAndLeave(typedName)
    rig.focusField()
    rig.editor.undo()
    rig.leaveField()
    expect(rig.editor.commits == [.themeName(typedName)], "leaving after ⌘Z proposed \(rig.editor.commits), expected only the setup's write")
    expect(rig.editor.settings.themeName == openingName, "running value is \(rig.editor.settings.themeName) after ⌘Z and leaving, expected \(openingName)")
}

/// Focus in and out of an untouched text field proposes nothing.
func textLeaveUntouched() {
    let rig = Rig(themeName: openingName, make: Rig.themeName)
    rig.focusField()
    rig.leaveField()
    expect(rig.editor.commits.isEmpty, "leaving an untouched field proposed \(rig.editor.commits)")
    expect(rig.editorText == openingName, "field shows \(rig.editorText), expected \(openingName)")
}

// MARK: text, guard arms

/// Typed text is committed once, when focus leaves.
func textTypedCommit() {
    let rig = Rig(themeName: openingName, make: Rig.themeName)
    rig.focusField()
    rig.type(typedName)
    expect(rig.editor.commits.isEmpty, "typing proposed \(rig.editor.commits) before focus left")
    rig.leaveField()
    expect(rig.editor.commits == [.themeName(typedName)], "commits were \(rig.editor.commits), expected [.themeName(\(typedName))]")
    expect(rig.editor.settings.themeName == typedName, "running value is \(rig.editor.settings.themeName), expected \(typedName)")
    expect(!rig.errorShown, "a valid name left the error line showing")
}

/// ⌘Z mid-edit does not replace typed text, and the typed text lands.
func textTypedSurvivesUndo() {
    let rig = Rig(themeName: openingName, make: Rig.themeName)
    rig.typeAndLeave(typedName)
    rig.focusField()
    rig.type(laterName)
    rig.editor.undo()
    expect(rig.editorText == laterName, "⌘Z replaced typed text with \(rig.editorText)")
    rig.leaveField()
    expect(rig.editor.commits == [.themeName(typedName), .themeName(laterName)], "commits were \(rig.editor.commits)")
    expect(rig.editor.settings.themeName == laterName, "running value is \(rig.editor.settings.themeName), expected the typed \(laterName)")
}

/// Text the file refuses shows its reason, stays, and writes nothing.
func textInvalidKept() {
    let rig = Rig(themeName: openingName, make: Rig.themeName)
    rig.typeAndLeave("   ")
    expect(rig.errorShown, "a blank name showed no error")
    expect(rig.editorText == "   ", "the refused text was replaced with \"\(rig.editorText)\"")
    expect(rig.editor.settings.themeName == openingName, "a blank name changed the running value to \(rig.editor.settings.themeName)")
}

/// `@main` rather than top-level statements: `run.sh` compiles this file
/// beside `SettingsControls.swift`, and a multi-file build allows top-level
/// code only in a file named `main.swift`.
@main
struct FieldProbe {
    @MainActor static func main() {
        let arms: [String: @MainActor () -> Void] = [
            "number-mirror-while-focused": numberMirrorWhileFocused,
            "number-undo-then-leave": numberUndoThenLeave,
            "number-leave-untouched": numberLeaveUntouched,
            "number-stepper-replaces-typing": numberStepperReplacesTyping,
            "number-keystroke-backspace-then-history-undo": numberKeystrokeBackspaceThenHistoryUndo,
            "undo-wiring": undoWiring,
            "number-typed-commit": numberTypedCommit,
            "number-locale-typed": numberLocaleTyped,
            "number-typed-survives-undo": numberTypedSurvivesUndo,
            "number-invalid-kept": numberInvalidKept,
            "number-out-of-range": numberOutOfRange,
            "number-whole-levels": numberWholeLevels,
            "text-mirror-while-focused": textMirrorWhileFocused,
            "text-undo-then-leave": textUndoThenLeave,
            "text-leave-untouched": textLeaveUntouched,
            "text-typed-commit": textTypedCommit,
            "text-typed-survives-undo": textTypedSurvivesUndo,
            "text-invalid-kept": textInvalidKept,
        ]

        // The arm is the first argument. Anything after it is left to
        // Foundation's argument domain, which is how `run.sh` hands the
        // locale arm a second locale (`-AppleLocale de_DE`).
        let name = CommandLine.arguments.dropFirst().first ?? ""
        guard let arm = arms[name] else {
            print("usage: fieldprobe <arm> [-AppleLocale xx_YY]; arms: \(arms.keys.sorted().joined(separator: " "))")
            exit(2)
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        arm()
        if failures.isEmpty {
            print("\(name): pass")
            exit(0)
        }
        print("\(name): FAIL")
        for failure in failures { print("  \(failure)") }
        exit(1)
    }
}
