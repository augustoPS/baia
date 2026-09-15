import AppKit
import BaiaSettings
import PaneChrome

// Does a mid-drag close of the native Colors panel leave an unpublished
// preview, and does the repair commit that last accepted colour once?
//
// Native shape found 2026-09-10 on an isolated app, PID 72470, evidence
// colour-close-history.json: a grayscale drag started at #141414, the well
// and hex field showed #aaaaaa while the mouse was held, AXPress on the
// Colors close button hid the panel, and after release the field was still
// #aaaaaa while the scratch file was #141414. ⌘Z then cleared the preview
// by undoing an earlier opacity write; the colour never entered history.
//
// Root: ColourControl.picked previews while NSApp.currentEvent is a mouse
// down or drag, and only endGesture on a later callback. Closing the panel
// omits that callback.
//
// Policy: an open panel gesture interrupted by panel close or well
// deactivation commits the last accepted preview once. UI and file agree;
// one undo returns the origin. Idle close and a completed mouse-up are
// unchanged.
//
// The shipped SettingsControls.swift is compiled verbatim against a real
// SettingsTransactionController writing a scratch file. One ColourControl
// sits in an NSWindow that is never ordered on screen. The well's action is
// fired under an injected mouse event so the preview path is the one the
// panel uses; the close is the well's deactivate and the panel's
// willCloseNotification, which is what AXPress on the close button is.
//
// **No window on screen, no focus taken.** No orderFront, makeKey, activate
// or pkill. Activation policy .accessory. The well is never activate()'d,
// so the shared Colors panel is not shown.

// MARK: - scratch editor

/// The window's SettingsEditing, talking to a real transaction controller
/// and a real file. Preview must not write; endGesture must. That split is
/// the bug, so a recording editor that applied both to one value would hide
/// it.
final class ScratchEditor: SettingsEditing {
    let store: SettingsStore
    let undoManager: UndoManager
    private(set) var controller: SettingsTransactionController!
    var onChange: ((Settings) -> Void)?

    var settings: Settings { controller.settings }
    var fileHex: String { store.load().settings.backgroundHex }
    var lastFailure: SettingsWriteFailure? { controller.lastFailure }

    init(fileURL: URL) {
        store = SettingsStore(fileURL: fileURL)
        _ = store.writeDefaultIfAbsent()
        undoManager = UndoManager()
        undoManager.groupsByEvent = false
        controller = SettingsTransactionController(
            store: store,
            settings: store.load().settings,
            undoManager: undoManager
        ) { [weak self] settings in
            self?.onChange?(settings)
        }
    }

    func commit(_ edit: SettingsEdit, actionName: String) -> SettingsValidationError? {
        surface(controller.commit(edit, actionName: actionName))
    }

    func preview(_ edit: SettingsEdit) -> SettingsValidationError? {
        controller.previewGesture(edit)
    }

    func endGesture(_ edit: SettingsEdit, actionName: String) -> SettingsValidationError? {
        surface(controller.endGesture(edit, actionName: actionName))
    }

    func undo() { undoManager.undo() }
    func redo() { undoManager.redo() }

    private func surface(_ failure: SettingsWriteFailure?) -> SettingsValidationError? {
        switch failure {
        case nil:
            return nil
        case let .validation(error)?:
            return error
        case .some:
            onChange?(controller.settings)
            return nil
        }
    }
}

// MARK: - the rig

final class Rig {
    let directory: URL
    let window: NSWindow
    let editor: ScratchEditor
    let control: ColourControl
    let well: NSColorWell
    let field: NSTextField
    private var eventSerial = 1

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("baia-colour-interruption-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fatalError("could not create scratch directory: \(error)")
        }
        editor = ScratchEditor(fileURL: directory.appendingPathComponent("config.json"))
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

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    var fileHex: String { editor.fileHex }
    var runningHex: String { editor.settings.backgroundHex }
    var fieldText: String { field.stringValue }

    /// A drag frame inside the Colors panel: the well takes the colour and
    /// fires its action while currentEvent is leftMouseDragged, which is the
    /// preview path. The event is posted and dequeued so it is the one
    /// picked() reads, not a fabricated property on the control.
    func previewPick(hex: String) {
        withMouseEvent(.leftMouseDragged) { applyWell(hex: hex) }
    }

    /// The panel's mouse-up: same delivery, currentEvent is leftMouseUp.
    func releasePick(hex: String) {
        withMouseEvent(.leftMouseUp) { applyWell(hex: hex) }
    }

    /// AXPress on the Colors close button: the panel posts willClose and is
    /// gone. The shared panel is never ordered front.
    func closePanel() {
        let panel = NSColorPanel.shared
        panel.orderOut(nil)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: panel)
    }

    /// The well losing the panel, which is also how a focus transfer that
    /// dismisses the panel arrives.
    func deactivateWell() {
        well.deactivate()
    }

    func breakFile() {
        do {
            try "{ broken".write(to: editor.store.url, atomically: true, encoding: .utf8)
        } catch {
            fatalError("could not break scratch file: \(error)")
        }
    }

    private func applyWell(hex: String) {
        guard let rgb = RGB(hex: hex) else { fatalError("bad hex \(hex)") }
        well.color = NSColor(srgbRed: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
        guard well.sendAction(well.action, to: well.target) else {
            fatalError("the well's action was not delivered")
        }
    }

    private func withMouseEvent(_ type: NSEvent.EventType, _ body: () -> Void) {
        let mask: NSEvent.EventTypeMask
        switch type {
        case .leftMouseDown: mask = .leftMouseDown
        case .leftMouseDragged: mask = .leftMouseDragged
        case .leftMouseUp: mask = .leftMouseUp
        default: fatalError("unsupported event type \(type)")
        }
        eventSerial += 1
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: 8, y: 8),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventSerial,
            clickCount: 1,
            pressure: 1
        ) else {
            fatalError("could not make \(type) event")
        }
        NSApp.postEvent(event, atStart: true)
        guard NSApp.nextEvent(matching: mask, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) != nil else {
            fatalError("could not dequeue injected \(type); the preview path would not be the one picked() takes")
        }
        guard NSApp.currentEvent?.type == type else {
            fatalError("currentEvent is \(String(describing: NSApp.currentEvent?.type)), expected \(type)")
        }
        body()
    }
}

// MARK: - arms

var failures: [String] = []

func expect(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

let opening = "#141414"
let mid = "#888888"
let chosen = "#aaaaaa"

/// Native defect: drag frames preview, the panel closes with no mouse-up,
/// the last colour must land once in both the UI and the file.
func panelCloseWhileHeld() {
    let rig = Rig()
    defer { rig.cleanup() }
    expect(rig.fileHex == opening, "scratch did not start at \(opening), file is \(rig.fileHex)")
    rig.previewPick(hex: mid)
    rig.previewPick(hex: chosen)
    expect(rig.runningHex == chosen, "running value is \(rig.runningHex) during the drag, expected \(chosen)")
    expect(rig.fileHex == opening, "a preview wrote the file: \(rig.fileHex)")
    expect(rig.fieldText == chosen, "field shows \(rig.fieldText) during the drag, expected \(chosen)")
    expect(!rig.editor.undoManager.canUndo, "a preview registered undo")
    rig.closePanel()
    expect(rig.fileHex == chosen, "after panel close the file is \(rig.fileHex), expected \(chosen)")
    expect(rig.runningHex == chosen, "after panel close the running value is \(rig.runningHex), expected \(chosen)")
    expect(rig.fieldText == chosen, "after panel close the field shows \(rig.fieldText), expected \(chosen)")
    expect(rig.editor.undoManager.canUndo, "panel close did not register one undo step")
    expect(rig.editor.undoManager.undoActionName == "Change Background Colour", "undo name is \(rig.editor.undoManager.undoActionName)")
    rig.editor.undo()
    expect(rig.fileHex == opening, "one undo left the file at \(rig.fileHex), expected \(opening)")
    expect(rig.runningHex == opening, "one undo left the running value at \(rig.runningHex), expected \(opening)")
    expect(rig.fieldText == opening, "one undo left the field at \(rig.fieldText), expected \(opening)")
    expect(!rig.editor.undoManager.canUndo, "undo did not consume the only colour step")
    rig.editor.redo()
    expect(rig.fileHex == chosen, "one redo left the file at \(rig.fileHex), expected \(chosen)")
    rig.closePanel()
    rig.deactivateWell()
    rig.editor.undo()
    expect(rig.fileHex == opening, "a second close after commit added another undo; file is \(rig.fileHex)")
    expect(!rig.editor.undoManager.canUndo, "a second close after commit registered another step")
}

/// Same commit, arriving as the well deactivating rather than willClose.
func wellDeactivateWhileHeld() {
    let rig = Rig()
    defer { rig.cleanup() }
    rig.previewPick(hex: chosen)
    expect(rig.fileHex == opening, "a preview wrote the file: \(rig.fileHex)")
    rig.deactivateWell()
    expect(rig.fileHex == chosen, "after well deactivation the file is \(rig.fileHex), expected \(chosen)")
    expect(rig.runningHex == chosen, "after well deactivation the running value is \(rig.runningHex), expected \(chosen)")
    expect(rig.fieldText == chosen, "after well deactivation the field shows \(rig.fieldText), expected \(chosen)")
    expect(rig.editor.undoManager.canUndo, "well deactivation did not register one undo step")
    rig.editor.undo()
    expect(rig.fileHex == opening, "one undo left the file at \(rig.fileHex), expected \(opening)")
    expect(!rig.editor.undoManager.canUndo, "undo did not consume the only colour step")
}

/// Closing the panel against a file that refuses the write must take the
/// preview down rather than leave it unpublished.
func panelCloseWriteFailure() {
    let rig = Rig()
    defer { rig.cleanup() }
    rig.previewPick(hex: chosen)
    expect(rig.runningHex == chosen, "preview did not reach the running value")
    rig.breakFile()
    rig.closePanel()
    expect(rig.runningHex == opening, "a failed close left the running value at \(rig.runningHex), expected origin \(opening)")
    expect(rig.fieldText == opening, "a failed close left the field at \(rig.fieldText), expected origin \(opening)")
    expect(rig.editor.lastFailure == .malformed, "a failed close did not record the write failure")
    expect(!rig.editor.undoManager.canUndo, "a failed close registered undo")
    let bytes = (try? String(contentsOf: rig.editor.store.url, encoding: .utf8)) ?? ""
    expect(bytes == "{ broken", "a failed close changed the broken file to \(bytes)")
}

/// A completed drag still writes once on mouse-up, one undo, and a later
/// idle close adds nothing.
func releaseOneUndo() {
    let rig = Rig()
    defer { rig.cleanup() }
    rig.previewPick(hex: mid)
    rig.previewPick(hex: chosen)
    expect(rig.fileHex == opening, "a preview wrote the file: \(rig.fileHex)")
    rig.releasePick(hex: chosen)
    expect(rig.fileHex == chosen, "mouse-up left the file at \(rig.fileHex), expected \(chosen)")
    expect(rig.editor.undoManager.canUndo, "mouse-up did not register one undo step")
    rig.closePanel()
    rig.deactivateWell()
    rig.editor.undo()
    expect(rig.fileHex == opening, "one undo after a completed drag left the file at \(rig.fileHex)")
    expect(!rig.editor.undoManager.canUndo, "idle close after mouse-up registered another step")
    rig.editor.redo()
    expect(rig.fileHex == chosen, "one redo left the file at \(rig.fileHex), expected \(chosen)")
}

/// Opening and closing the panel with no drag writes nothing.
func idlePanelClose() {
    let rig = Rig()
    defer { rig.cleanup() }
    rig.closePanel()
    rig.deactivateWell()
    expect(rig.fileHex == opening, "idle close wrote the file: \(rig.fileHex)")
    expect(rig.runningHex == opening, "idle close moved the running value to \(rig.runningHex)")
    expect(rig.fieldText == opening, "idle close moved the field to \(rig.fieldText)")
    expect(!rig.editor.undoManager.canUndo, "idle close registered undo")
}

/// Write failure on the mouse-up path still reverts, the existing
/// endGesture contract.
func writeFailureOnRelease() {
    let rig = Rig()
    defer { rig.cleanup() }
    rig.previewPick(hex: chosen)
    rig.breakFile()
    rig.releasePick(hex: chosen)
    expect(rig.runningHex == opening, "a failed mouse-up left the running value at \(rig.runningHex), expected origin")
    expect(rig.editor.lastFailure == .malformed, "a failed mouse-up did not record the write failure")
    expect(!rig.editor.undoManager.canUndo, "a failed mouse-up registered undo")
}

@main
struct InterruptProbe {
    @MainActor static func main() {
        let arms: [String: @MainActor () -> Void] = [
            "panel-close-while-held": panelCloseWhileHeld,
            "well-deactivate-while-held": wellDeactivateWhileHeld,
            "panel-close-write-failure": panelCloseWriteFailure,
            "release-one-undo": releaseOneUndo,
            "idle-panel-close": idlePanelClose,
            "write-failure-on-release": writeFailureOnRelease,
        ]

        let name = CommandLine.arguments.dropFirst().first ?? ""
        guard let arm = arms[name] else {
            print("usage: interruptprobe <arm>; arms: \(arms.keys.sorted().joined(separator: " "))")
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
