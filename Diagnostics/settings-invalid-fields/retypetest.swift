import AppKit
import BaiaSettings
import PaneChrome

// After a text, number or colour field has shown an invalid-value error, does
// retyping the exact value the file holds and leaving the field clear that
// error, and does it do so without proposing a write?
//
// The shape found on 2026-09-13: the Typography page's Font size field shows
// 11.5. The owner types `abc`, leaves, and the reason appears. They come back,
// type `11.5` again, and leave. The field now shows the file's own value and
// the red line still says "Enter a number." Nothing the owner can type clears
// it, because the text equals the mirror and the mirror never proposes.
// `TextControl` and `ColourControl` carry the same shape, one flag each.
//
// Both halves of the contract are graded, because each earlier tree got one
// of them wrong. The tree before the `fieldHoldsTyping` rework proposed the
// retyped value as a fresh commit, which cleared the error by way of a
// duplicate write the transaction controller then dropped; the tree after it
// proposed nothing and left the error up. The repair proposes nothing and
// clears the error, so an arm here asserts both the error line and the list
// of proposals.
//
// The controls live in `Sources/`, which has no test target, and the question
// needs a field editor, so it is a probe. It compiles the shipped
// `SettingsControls.swift` verbatim against a recording `SettingsEditing`,
// the harness `settings-field-history` and `settings-colour-history` use,
// pointed at one control per arm.
//
// **No window on screen, no focus taken.** The window is created and never
// ordered front; `makeFirstResponder` moves the window's own responder chain,
// which is what starts and ends the field editor's session, and does not make
// the window key or the app active. The activation policy is `.accessory`,
// as in `override-wires`, and there is no `orderFront`, `makeKey`, `activate`
// or `pkill` in this file.

// MARK: - a recording editor

/// The window's side of `SettingsEditing`, reduced to what a control can
/// observe: the running value, every write it proposes, and a refresh after
/// each one, exactly as `SettingsWindowController.refresh()` runs after each
/// transaction. Three keys are applied, one per control under test. None of
/// the three text paths previews or ends a gesture, so those stop the probe.
final class RecordingEditor: SettingsEditing {
    private(set) var settings = Settings.defaultSettings
    private(set) var commits: [SettingsEdit] = []
    private var history: [Settings] = []
    var onChange: ((Settings) -> Void)?

    init(fontSize: Double, themeName: String, hex: String) {
        settings.fontSize = fontSize
        settings.themeName = themeName
        settings.backgroundHex = hex
    }

    func commit(_ edit: SettingsEdit, actionName: String) -> SettingsValidationError? {
        commits.append(edit)
        return apply(edit)
    }

    func preview(_ edit: SettingsEdit) -> SettingsValidationError? {
        fatalError("no text path previews; got \(edit)")
    }

    func endGesture(_ edit: SettingsEdit, actionName: String) -> SettingsValidationError? {
        fatalError("no text path ends a gesture; got \(edit)")
    }

    /// ⌘Z as the transaction controller performs it: the previous value is
    /// written back and every page refreshes.
    func undo() {
        guard let previous = history.popLast() else { fatalError("nothing to undo") }
        settings = previous
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
            case let .themeName(name): next.themeName = name
            case let .backgroundHex(hex): next.backgroundHex = hex
            default: fatalError("unexpected key \(valid.key)")
            }
            // A write equal to the file is dropped, as the transaction
            // controller drops it, so a duplicate proposal shows up in
            // `commits` and nowhere else.
            guard next != settings else { return nil }
            history.append(settings)
            settings = next
            onChange?(settings)
            return nil
        }
    }
}

// MARK: - the rig

/// One control in an offscreen window, with its field found by walking the
/// shipped view tree rather than reaching into the class.
struct Rig {
    let window: NSWindow
    let editor: RecordingEditor
    let control: SettingsControlBase
    let field: NSTextField
    let stepper: NSStepper?

    init(make: (RecordingEditor) -> SettingsControlBase) {
        editor = RecordingEditor(fontSize: openingSize, themeName: openingName, hex: openingHex)
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

    /// A `TextControl` on the theme name: the shipped class driven the way a
    /// page would.
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

    /// The Appearance page's background colour control.
    static func colour(_ editor: RecordingEditor) -> SettingsControlBase {
        ColourControl(editor: editor)
    }

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

    func typeAndLeave(_ text: String) {
        focusField()
        type(text)
        leaveField()
    }
}

// MARK: - arms

var failures: [String] = []

func expect(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

/// The owner's locale, as the number control's own formatter reads it.
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

let openingSize = 11.5
let openingName = "Dark Pastel"
let openingHex = "#141414"

/// Refused text, then the mirror typed back over it. The reason comes down,
/// nothing is proposed, and the field shows the file's value.
func retypeClears(_ rig: Rig, refused: String, mirror: String, describe: (Rig) -> String) {
    rig.typeAndLeave(refused)
    expect(rig.errorShown, "setup: \"\(refused)\" showed no error")
    expect(rig.editorText == refused, "setup: the refused text was replaced with \"\(rig.editorText)\"")
    let proposals = rig.editor.commits
    let running = describe(rig)

    rig.typeAndLeave(mirror)
    expect(!rig.errorShown, "retyping the mirror \"\(mirror)\" left the error line showing")
    expect(rig.editor.commits == proposals, "retyping the mirror proposed \(rig.editor.commits), expected \(proposals) unchanged")
    expect(rig.editorText == mirror, "field shows \"\(rig.editorText)\", expected \"\(mirror)\"")
    expect(describe(rig) == running, "retyping the mirror moved the running value from \(running) to \(describe(rig))")
}

// MARK: bug arms

func textRetypeMirrorClears() {
    let rig = Rig(make: Rig.themeName)
    retypeClears(rig, refused: "   ", mirror: openingName) { $0.editor.settings.themeName }
}

func numberRetypeMirrorClears() {
    let rig = Rig(make: Rig.fontSize)
    retypeClears(rig, refused: "abc", mirror: spell(openingSize)) { "\($0.editor.settings.fontSize)" }
    expect(rig.stepper?.doubleValue == openingSize, "the stepper shows \(rig.stepper?.doubleValue ?? .nan), expected \(openingSize)")
}

func colourRetypeMirrorClears() {
    let rig = Rig(make: Rig.colour)
    retypeClears(rig, refused: "zzz", mirror: openingHex) { $0.editor.settings.backgroundHex }
}

// MARK: guard arms

/// Focus through a field holding refused text, with nothing typed, keeps the
/// text and its reason: the retype path must not read an untouched field as
/// a correction.
func numberLeaveRefusedUntouched() {
    let rig = Rig(make: Rig.fontSize)
    rig.typeAndLeave("abc")
    expect(rig.errorShown, "setup: abc showed no error")
    rig.focusField()
    rig.leaveField()
    expect(rig.errorShown, "focus through untouched refused text hid the error")
    expect(rig.editorText == "abc", "focus through untouched refused text replaced it with \"\(rig.editorText)\"")
    expect(rig.editor.commits.isEmpty, "focus through untouched refused text proposed \(rig.editor.commits)")
}

/// While the error is up, ⌘Z moves the file. The mirror moves with it, so
/// typing the value the file held before ⌘Z is a proposal and lands, rather
/// than being read as the mirror and dropped.
func numberRetypeOldValueAfterUndoCommits() {
    let typed = 14.0
    let rig = Rig(make: Rig.fontSize)
    rig.typeAndLeave(spell(typed))
    expect(rig.editor.settings.fontSize == typed, "setup: typed \(typed) did not land")
    rig.typeAndLeave("abc")
    expect(rig.errorShown, "setup: abc showed no error")
    rig.editor.undo()
    expect(rig.editor.settings.fontSize == openingSize, "⌘Z did not restore \(openingSize)")
    expect(rig.errorShown, "⌘Z hid the error under uncorrected text")

    rig.typeAndLeave(spell(typed))
    expect(!rig.errorShown, "typing \(spell(typed)) over refused text left the error line showing")
    expect(rig.editor.commits == [.fontSize(typed), .fontSize(typed)], "commits were \(rig.editor.commits), expected the setup's write and the retyped \(typed)")
    expect(rig.editor.settings.fontSize == typed, "running value is \(rig.editor.settings.fontSize), expected \(typed)")
}

/// `@main` rather than top-level statements: `run.sh` compiles this file
/// beside `SettingsControls.swift`, and a multi-file build allows top-level
/// code only in a file named `main.swift`.
@main
struct RetypeProbe {
    @MainActor static func main() {
        let arms: [String: @MainActor () -> Void] = [
            "text-retype-mirror-clears": textRetypeMirrorClears,
            "number-retype-mirror-clears": numberRetypeMirrorClears,
            "colour-retype-mirror-clears": colourRetypeMirrorClears,
            "number-leave-refused-untouched": numberLeaveRefusedUntouched,
            "number-retype-old-value-after-undo-commits": numberRetypeOldValueAfterUndoCommits,
        ]

        let name = CommandLine.arguments.dropFirst().first ?? ""
        guard let arm = arms[name] else {
            print("usage: retypetest <arm>; arms: \(arms.keys.sorted().joined(separator: " "))")
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
