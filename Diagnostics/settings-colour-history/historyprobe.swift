import AppKit
import BaiaSettings
import PaneChrome

// Does the Appearance page's hex field overwrite the colour the owner chose in
// the native colour panel when focus leaves it, and does the fix keep every
// edit the owner did type?
//
// The shape found on 2026-09-10, on an isolated app: the page opens with the
// hex field focused, showing `#141414`, and nobody types. A continuous drag in
// the Colors panel writes `#bababa` to the well and the file; ⌘Z returns
// `#141414` and ⇧⌘Z `#bababa`. The field shows `#141414` throughout, because
// `refresh` skipped any field whose `currentEditor()` was non-nil, and the
// field has an editor for as long as it has focus. Clicking the Typography
// toolbar item ends editing, `controlTextDidEndEditing` committed whatever the
// field held, and `#141414` went over the chosen value.
//
// `ColourControl` lives in `Sources/`, which has no test target, and its
// question needs a field editor, so it is a probe. It compiles the shipped
// `SettingsControls.swift` verbatim against a recording `SettingsEditing` and
// drives one control in a window that is never ordered on screen.
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
// against the revision that carried the bug, and the four arms that name the
// bug must fail on the second build. That is the red run, kept alongside the
// green one for as long as the revision exists.

// MARK: - a recording editor

/// The window's side of `SettingsEditing`, reduced to what the control can
/// observe: the running value, every write it proposes, and a refresh after
/// each one, exactly as `SettingsWindowController.refresh()` runs after each
/// transaction. Only `backgroundHex` is applied; no other key reaches it.
final class RecordingEditor: SettingsEditing {
    private(set) var settings = Settings.defaultSettings
    private(set) var commits: [String] = []
    private(set) var previews: [String] = []
    private(set) var gestures: [String] = []
    private var history: [Settings] = []
    private var future: [Settings] = []
    var onChange: ((Settings) -> Void)?

    init(hex: String) {
        settings.backgroundHex = hex
    }

    func commit(_ edit: SettingsEdit, actionName: String) -> SettingsValidationError? {
        commits.append(describe(edit))
        return apply(edit)
    }

    func preview(_ edit: SettingsEdit) -> SettingsValidationError? {
        previews.append(describe(edit))
        return apply(edit)
    }

    func endGesture(_ edit: SettingsEdit, actionName: String) -> SettingsValidationError? {
        gestures.append(describe(edit))
        return apply(edit)
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
            guard case let .backgroundHex(hex) = valid else { fatalError("unexpected key \(valid.key)") }
            guard hex != settings.backgroundHex else { return nil }
            history.append(settings)
            future.removeAll()
            settings.backgroundHex = hex
            onChange?(settings)
            return nil
        }
    }

    private func describe(_ edit: SettingsEdit) -> String {
        guard case let .backgroundHex(hex) = edit else { return "\(edit)" }
        return hex
    }
}

// MARK: - the rig

/// One control in an offscreen window, with its well and hex field found by
/// walking the shipped view tree rather than reaching into the class.
struct Rig {
    let window: NSWindow
    let editor: RecordingEditor
    let control: ColourControl
    let well: NSColorWell
    let field: NSTextField

    init(hex: String) {
        editor = RecordingEditor(hex: hex)
        control = ColourControl(editor: editor)
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

        var wells: [NSColorWell] = []
        var fields: [NSTextField] = []
        func walk(_ view: NSView) {
            if let well = view as? NSColorWell { wells.append(well) }
            if let field = view as? NSTextField, field.isEditable { fields.append(field) }
            view.subviews.forEach(walk)
        }
        walk(control.view)
        guard wells.count == 1, fields.count == 1 else {
            fatalError("expected one well and one editable field, found \(wells.count) and \(fields.count)")
        }
        well = wells[0]
        field = fields[0]
    }

    /// Whether the hex field has a live field editor, which is the state the
    /// Appearance page opens in.
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

    /// The colour panel's mouse-up on a new colour, delivered the way AppKit
    /// delivers it: the well takes the colour and fires its action. There is
    /// no current event in this process, so the control takes the gesture-end
    /// path; the drag frames go through `preview` and are the slider's
    /// arrangement, unchanged here.
    func pickInPanel(hex: String) {
        guard let rgb = RGB(hex: hex) else { fatalError("bad hex \(hex)") }
        well.color = NSColor(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
        guard well.sendAction(well.action, to: well.target) else { fatalError("the well's action was not delivered") }
    }
}

// MARK: - arms

var failures: [String] = []

func expect(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

let opening = "#141414"
let chosen = "#bababa"

/// A focused field with nothing typed in it follows the panel.
func mirrorWhileFocused() {
    let rig = Rig(hex: opening)
    rig.focusField()
    rig.pickInPanel(hex: chosen)
    expect(rig.editor.settings.backgroundHex == chosen, "the panel's colour did not reach the running value")
    expect(rig.fieldIsEditing, "the panel pick ended the field's editing session")
    expect(rig.editorText == chosen, "field shows \(rig.editorText) after the panel chose \(chosen)")
}

/// Leaving a field nobody typed in commits nothing and keeps the chosen colour.
func leaveWithoutTyping() {
    let rig = Rig(hex: opening)
    rig.focusField()
    rig.pickInPanel(hex: chosen)
    rig.leaveField()
    expect(rig.editor.commits.isEmpty, "leaving the field committed \(rig.editor.commits) with nothing typed")
    expect(rig.editor.settings.backgroundHex == chosen, "running value is \(rig.editor.settings.backgroundHex), expected \(chosen)")
    expect(rig.editorText == chosen, "field shows \(rig.editorText), expected \(chosen)")
}

/// ⌘Z and ⇧⌘Z with the caret in the field, then focus leaves: the redo stands.
func undoRedoThenLeave() {
    let rig = Rig(hex: opening)
    rig.focusField()
    rig.pickInPanel(hex: chosen)
    rig.editor.undo()
    expect(rig.editorText == opening, "after ⌘Z the field shows \(rig.editorText), expected \(opening)")
    rig.editor.redo()
    expect(rig.editorText == chosen, "after ⇧⌘Z the field shows \(rig.editorText), expected \(chosen)")
    rig.leaveField()
    expect(rig.editor.commits.isEmpty, "leaving the field after ⇧⌘Z committed \(rig.editor.commits)")
    expect(rig.editor.settings.backgroundHex == chosen, "running value is \(rig.editor.settings.backgroundHex) after ⇧⌘Z and leaving, expected \(chosen)")
}

/// Typed text is committed once, when focus leaves.
func typedCommit() {
    let rig = Rig(hex: opening)
    rig.focusField()
    rig.type("#0a0b0c")
    expect(rig.editor.commits.isEmpty, "typing committed \(rig.editor.commits) before focus left")
    rig.leaveField()
    expect(rig.editor.commits == ["#0a0b0c"], "commits were \(rig.editor.commits), expected [\"#0a0b0c\"]")
    expect(rig.editor.settings.backgroundHex == "#0a0b0c", "running value is \(rig.editor.settings.backgroundHex), expected #0a0b0c")
    expect(!rig.errorShown, "a valid hex left the error line showing")
}

/// A panel pick while the owner is mid-edit does not replace what they typed,
/// and what they typed is what lands.
func typedSurvivesPanel() {
    let rig = Rig(hex: opening)
    rig.focusField()
    rig.type("#0a0b0c")
    rig.pickInPanel(hex: chosen)
    expect(rig.editorText == "#0a0b0c", "the panel replaced typed text with \(rig.editorText)")
    rig.leaveField()
    expect(rig.editor.commits == ["#0a0b0c"], "commits were \(rig.editor.commits), expected [\"#0a0b0c\"]")
    expect(rig.editor.settings.backgroundHex == "#0a0b0c", "running value is \(rig.editor.settings.backgroundHex), expected the typed #0a0b0c")
}

/// Invalid text shows its reason and stays put through a later panel pick.
func invalidKept() {
    let rig = Rig(hex: opening)
    rig.focusField()
    rig.type("zzz")
    rig.leaveField()
    expect(rig.editor.commits == ["zzz"], "commits were \(rig.editor.commits), expected [\"zzz\"]")
    expect(rig.errorShown, "an invalid hex showed no error")
    expect(rig.editorText == "zzz", "the invalid text was replaced with \(rig.editorText)")
    expect(rig.editor.settings.backgroundHex == opening, "an invalid hex changed the running value to \(rig.editor.settings.backgroundHex)")
}

/// Refused text and a later valid panel pick end consistent: the well's colour
/// replaces the text and the reason goes with it. Before the repair the write's
/// synchronous refresh ran while the reason was still up and left the text,
/// and the nil result then hid the reason: `zzz` beside a well of another
/// colour with nothing saying why (independent review D2, 2026-09-11). The
/// first assertion is the consistency either policy needs; the second pins
/// the policy taken, which is the one `NumberControl`'s stepper already has.
func invalidThenPanelConsistent() {
    let rig = Rig(hex: opening)
    rig.focusField()
    rig.type("zzz")
    rig.leaveField()
    expect(rig.errorShown, "setup: an invalid hex showed no error")
    rig.pickInPanel(hex: chosen)
    expect(rig.editor.settings.backgroundHex == chosen, "the panel pick did not reach the running value")
    let consistent = (rig.errorShown && rig.editorText == "zzz") || (!rig.errorShown && rig.editorText == chosen)
    expect(consistent, "after the pick the field shows \(rig.editorText) with the reason \(rig.errorShown ? "shown" : "hidden")")
    expect(rig.editorText == chosen, "the well's valid colour did not replace the refused text: field shows \(rig.editorText)")
}

/// A keystroke and a Backspace leave the text as it was, then a panel pick.
/// Nothing is pending, so the pick must show in the field and leaving must
/// propose nothing. A flag raised on the first keystroke and lowered only by
/// a commit is still up after the Backspace: the pick's refresh skips the
/// text and leaving writes the opening hex over the chosen one, the original
/// finding one keystroke later (independent review D1, 2026-09-11).
func keystrokeBackspaceThenPanel() {
    let rig = Rig(hex: opening)
    rig.focusField()
    rig.typeAndBackspace("0")
    expect(rig.editorText == opening, "a keystroke and a Backspace left the field at \(rig.editorText), expected \(opening)")
    expect(rig.editor.commits.isEmpty, "a keystroke and a Backspace proposed \(rig.editor.commits)")
    rig.pickInPanel(hex: chosen)
    expect(rig.editor.settings.backgroundHex == chosen, "the panel pick did not reach the running value")
    expect(rig.editorText == chosen, "after a keystroke and a Backspace the panel pick left the field at \(rig.editorText), expected \(chosen)")
    rig.leaveField()
    expect(rig.editor.commits.isEmpty, "leaving after a keystroke, a Backspace and a panel pick committed \(rig.editor.commits)")
    expect(rig.editor.settings.backgroundHex == chosen, "running value is \(rig.editor.settings.backgroundHex) after leaving, expected \(chosen)")
}

/// Leaving a field that was focused and never touched, with no panel activity
/// at all, proposes nothing. A bug arm: the buggy revision committed the
/// opening value on every focus loss, a write the transaction controller
/// happened to drop as equal to the file, so the arm grades the proposal.
func leaveUntouched() {
    let rig = Rig(hex: opening)
    rig.focusField()
    rig.leaveField()
    expect(rig.editor.commits.isEmpty, "leaving an untouched field committed \(rig.editor.commits)")
    expect(rig.editorText == opening, "field shows \(rig.editorText), expected \(opening)")
}

/// `@main` rather than top-level statements: `run.sh` compiles this file
/// beside `SettingsControls.swift`, and a multi-file build allows top-level
/// code only in a file named `main.swift`.
@main
struct HistoryProbe {
    @MainActor static func main() {
        let arms: [String: @MainActor () -> Void] = [
            "mirror-while-focused": mirrorWhileFocused,
            "leave-without-typing": leaveWithoutTyping,
            "undo-redo-then-leave": undoRedoThenLeave,
            "leave-untouched": leaveUntouched,
            "keystroke-backspace-then-panel": keystrokeBackspaceThenPanel,
            "invalid-then-panel-consistent": invalidThenPanelConsistent,
            "typed-commit": typedCommit,
            "typed-survives-panel": typedSurvivesPanel,
            "invalid-kept": invalidKept,
        ]

        let name = CommandLine.arguments.dropFirst().first ?? ""
        guard let arm = arms[name] else {
            print("usage: historyprobe <arm>; arms: \(arms.keys.sorted().joined(separator: " "))")
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
