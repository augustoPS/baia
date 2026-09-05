import Foundation
import Testing

@testable import BaiaSettings

/// The editing contract, driven against a real file and a real `UndoManager`.
///
/// `UndoManager` groups by run loop by default, and these tests never spin one,
/// so every registration would otherwise sit in one open group and `undo()`
/// would undo nothing. `groupsByEvent = false` makes each registration its own
/// step, which is what the window's manager does per event anyway.
@MainActor
@Suite final class SettingsTransactionControllerTests {
    let fixture: DirectoryFixture
    let store: SettingsStore
    let undoManager = UndoManager()
    /// Every value handed to `apply`, in order. What the running app saw.
    var applied: [Settings] = []

    init() throws {
        fixture = try DirectoryFixture()
        store = SettingsStore(fileURL: fixture.root.appending(path: "config.json"))
        undoManager.groupsByEvent = false
    }

    private func makeController(_ settings: Settings = .defaultSettings) -> SettingsTransactionController {
        SettingsTransactionController(
            store: store,
            settings: settings,
            undoManager: undoManager
        ) { [self] value in applied.append(value) }
    }

    private var fileText: String {
        (try? String(contentsOf: store.url, encoding: .utf8)) ?? ""
    }

    // MARK: - Commit

    @Test func aValidCommitWritesAppliesAndRegistersUndo() throws {
        let controller = makeController()
        #expect(store.writeDefaultIfAbsent())

        #expect(controller.commit(.fontSize(15), actionName: "Change Font Size") == nil)
        #expect(controller.settings.fontSize == 15)
        #expect(store.load().settings.fontSize == 15)
        #expect(applied.map(\.fontSize) == [15])
        #expect(undoManager.canUndo)
        #expect(undoManager.undoActionName == "Change Font Size")
        #expect(controller.lastFailure == nil)
    }

    @Test func anInvalidCommitWritesNothingAppliesNothingAndRegistersNothing() throws {
        let controller = makeController()
        #expect(store.writeDefaultIfAbsent())
        let before = fileText

        let outcome = controller.commit(.backgroundHex("not-a-colour"), actionName: "Change Background")
        guard case let .validation(error)? = outcome else {
            Issue.record("not refused as a validation failure")
            return
        }
        #expect(error.key == .backgroundHex)
        #expect(fileText == before)
        #expect(applied.isEmpty)
        #expect(!undoManager.canUndo)
        #expect(controller.settings == .defaultSettings)
        // A validation failure is the control's to show; it is not a file
        // problem and must not raise the recovery state.
        #expect(controller.lastFailure == nil)
    }

    @Test func aCommitEqualToTheRunningValueIsANoOp() throws {
        let controller = makeController()
        #expect(store.writeDefaultIfAbsent())
        let before = fileText
        #expect(controller.commit(.fontSize(Settings.defaultSettings.fontSize), actionName: "x") == nil)
        #expect(fileText == before)
        #expect(applied.isEmpty)
        #expect(!undoManager.canUndo)
    }

    @Test func aRefusedWriteKeepsTheRunningValueAndRecordsTheFailure() throws {
        try "{ broken".write(to: store.url, atomically: true, encoding: .utf8)
        let controller = makeController()

        #expect(controller.commit(.fontSize(15), actionName: "x") == .malformed)
        #expect(controller.settings == .defaultSettings)
        #expect(applied.isEmpty)
        #expect(!undoManager.canUndo)
        #expect(controller.lastFailure == .malformed)
        #expect(fileText == "{ broken")
        #expect(controller.documentState() == .malformed)
    }

    @Test func aLaterSuccessClearsTheFailure() throws {
        try "{ broken".write(to: store.url, atomically: true, encoding: .utf8)
        let controller = makeController()
        _ = controller.commit(.fontSize(15), actionName: "x")
        #expect(controller.lastFailure != nil)
        try "{}".write(to: store.url, atomically: true, encoding: .utf8)
        #expect(controller.commit(.fontSize(15), actionName: "x") == nil)
        #expect(controller.lastFailure == nil)
    }

    // MARK: - Undo and redo

    @Test func undoAndRedoMoveBothTheRunningValueAndTheFile() throws {
        let controller = makeController()
        #expect(store.writeDefaultIfAbsent())
        _ = controller.commit(.themeName("Midnight"), actionName: "Change Theme")

        undoManager.undo()
        #expect(controller.settings.themeName == "Dark Pastel")
        #expect(store.load().settings.themeName == "Dark Pastel")
        #expect(undoManager.canRedo)
        #expect(undoManager.redoActionName == "Change Theme")

        undoManager.redo()
        #expect(controller.settings.themeName == "Midnight")
        #expect(store.load().settings.themeName == "Midnight")
        #expect(undoManager.canUndo)

        #expect(applied.map(\.themeName) == ["Midnight", "Dark Pastel", "Midnight"])
    }

    @Test func undoWritesProjectRootsBackWithTheTilde() throws {
        // The running value is expanded, so the inverse edit is expanded, and it
        // still has to reach the file as `~/...`.
        let controller = makeController()
        try "{\"projectRoots\": [\"~/Projects\"]}".write(to: store.url, atomically: true, encoding: .utf8)
        _ = controller.commit(.projectRoots(["/opt/src"]), actionName: "Change Project Roots")
        #expect(fileText.contains("\"projectRoots\": [\"/opt/src\"]"))
        undoManager.undo()
        #expect(fileText.contains("\"projectRoots\": [\"~/Projects\"]"))
        #expect(!fileText.contains(NSHomeDirectory()))
    }

    @Test func undoThatCannotBeWrittenReportsInsteadOfPretending() throws {
        let controller = makeController()
        var failures: [SettingsWriteFailure] = []
        controller.onFailure = { failures.append($0) }
        #expect(store.writeDefaultIfAbsent())
        _ = controller.commit(.fontSize(15), actionName: "x")
        try "{ broken".write(to: store.url, atomically: true, encoding: .utf8)

        undoManager.undo()
        #expect(controller.settings.fontSize == 15)
        #expect(controller.lastFailure == .malformed)
        #expect(fileText == "{ broken")
        #expect(failures == [.malformed])
        #expect(controller.hasPendingHistory)
        try "{\"fontSize\":15}".write(to: store.url, atomically: true, encoding: .utf8)
        #expect(controller.retryHistory() == nil)
        #expect(!controller.hasPendingHistory)
        #expect(store.load().settings.fontSize == Settings.defaultSettings.fontSize)
        undoManager.undo()
        #expect(store.load().settings.fontSize == 15)
    }

    // MARK: - Gestures

    @Test func aGestureIsOneUndoStepBackToItsOrigin() throws {
        let controller = makeController()
        #expect(store.writeDefaultIfAbsent())
        let writesBefore = fileText

        controller.beginGesture(.backgroundOpacity)
        #expect(controller.previewGesture(.backgroundOpacity(0.5)) == nil)
        #expect(controller.previewGesture(.backgroundOpacity(0.6)) == nil)
        #expect(controller.previewGesture(.backgroundOpacity(0.7)) == nil)
        // Previews reach the running app and never the file.
        #expect(applied.map(\.backgroundOpacity) == [0.5, 0.6, 0.7])
        #expect(fileText == writesBefore)
        #expect(!undoManager.canUndo)

        #expect(controller.endGesture(.backgroundOpacity(0.7), actionName: "Change Opacity") == nil)
        #expect(store.load().settings.backgroundOpacity == 0.7)
        #expect(undoManager.canUndo)

        undoManager.undo()
        #expect(controller.settings.backgroundOpacity == Settings.defaultSettings.backgroundOpacity)
        #expect(store.load().settings.backgroundOpacity == Settings.defaultSettings.backgroundOpacity)
        // One step: nothing is left to undo, and the whole drag is redoable.
        #expect(!undoManager.canUndo)
        #expect(undoManager.canRedo)
    }

    @Test func aGestureThatEndsWhereItBeganWritesNothingAndTakesThePreviewDown() throws {
        let controller = makeController()
        #expect(store.writeDefaultIfAbsent())
        let origin = Settings.defaultSettings.backgroundOpacity
        controller.previewGesture(.backgroundOpacity(0.9))
        #expect(controller.endGesture(.backgroundOpacity(origin), actionName: "x") == nil)
        #expect(applied.last?.backgroundOpacity == origin)
        #expect(!undoManager.canUndo)
        #expect(store.load().settings.backgroundOpacity == origin)
    }

    @Test func aGestureWhoseWriteFailsRevertsTheRunningValue() throws {
        try "{ broken".write(to: store.url, atomically: true, encoding: .utf8)
        let controller = makeController()
        controller.previewGesture(.backgroundOpacity(0.9))
        #expect(controller.endGesture(.backgroundOpacity(0.9), actionName: "x") == .malformed)
        #expect(controller.settings.backgroundOpacity == Settings.defaultSettings.backgroundOpacity)
        #expect(applied.last?.backgroundOpacity == Settings.defaultSettings.backgroundOpacity)
        #expect(controller.lastFailure == .malformed)
    }

    @Test func cancellingAGestureRestoresTheOrigin() throws {
        let controller = makeController()
        controller.previewGesture(.fontSize(20))
        controller.cancelGesture()
        #expect(controller.settings.fontSize == Settings.defaultSettings.fontSize)
        #expect(applied.last?.fontSize == Settings.defaultSettings.fontSize)
    }

    @Test func anInvalidPreviewMovesNothing() throws {
        let controller = makeController()
        #expect(controller.previewGesture(.backgroundOpacity(2)) != nil)
        #expect(applied.isEmpty)
    }

    // MARK: - External edits

    @Test func undoUsesTheValueReplacedBeforeTheWatcherReloads() throws {
        let controller = makeController()
        try "{\"fontSize\":20}".write(to: store.url, atomically: true, encoding: .utf8)
        #expect(controller.commit(.fontSize(18), actionName: "Font") == nil)
        undoManager.undo()
        #expect(store.load().settings.fontSize == 20)
    }

    @Test func explicitEditEqualToCacheStillReplacesExternalValue() throws {
        let controller = makeController()
        try "{\"fontSize\":20}".write(to: store.url, atomically: true, encoding: .utf8)
        #expect(controller.commit(.fontSize(Settings.defaultSettings.fontSize), actionName: "Font") == nil)
        #expect(store.load().settings.fontSize == Settings.defaultSettings.fontSize)
        undoManager.undo()
        #expect(store.load().settings.fontSize == 20)
    }

    @Test func anExternalEditToAnotherFieldSurvivesTheNextTransaction() throws {
        let controller = makeController()
        #expect(store.writeDefaultIfAbsent())
        try String(fileText.replacingOccurrences(of: "\"backgroundHex\": \"#141414\"", with: "\"backgroundHex\": \"#abcdef\""))
            .write(to: store.url, atomically: true, encoding: .utf8)

        _ = controller.commit(.fontSize(15), actionName: "x")
        #expect(store.load().settings.backgroundHex == "#abcdef")
        #expect(store.load().settings.fontSize == 15)
    }

    @Test func anExternalEditToTheSameFieldIsSupersededOnlyByTheNextExplicitEdit() throws {
        // The reload moves the baseline; the earlier undo entry keeps the value
        // it recorded; the next explicit edit of the field takes over from the
        // external value and its undo goes back to that external value.
        let controller = makeController()
        #expect(store.writeDefaultIfAbsent())
        _ = controller.commit(.fontSize(15), actionName: "x")

        var external = store.load()
        external = SettingsDecoder.decode(Data(fileText.replacingOccurrences(of: "\"fontSize\": 15", with: "\"fontSize\": 20").utf8))
        try fileText.replacingOccurrences(of: "\"fontSize\": 15", with: "\"fontSize\": 20")
            .write(to: store.url, atomically: true, encoding: .utf8)
        controller.noteExternalReload(external.settings)
        #expect(controller.settings.fontSize == 20)
        #expect(store.load().settings.fontSize == 20)

        _ = controller.commit(.fontSize(18), actionName: "y")
        #expect(store.load().settings.fontSize == 18)
        undoManager.undo()
        #expect(store.load().settings.fontSize == 20)
        undoManager.undo()
        #expect(store.load().settings.fontSize == Settings.defaultSettings.fontSize)
    }

    // MARK: - Repair

    @Test func repairReplacesTheFileFromTheRunningValueAndClearsUndo() throws {
        let controller = makeController()
        #expect(store.writeDefaultIfAbsent())
        _ = controller.commit(.themeName("Midnight"), actionName: "x")
        try "{ broken".write(to: store.url, atomically: true, encoding: .utf8)
        #expect(controller.documentState() == .malformed)

        let backup = try controller.repair().get()
        #expect(try String(contentsOf: backup, encoding: .utf8) == "{ broken")
        #expect(controller.documentState() == .valid)
        #expect(store.load().settings.themeName == "Midnight")
        #expect(controller.lastFailure == nil)
        #expect(!undoManager.canUndo)
        #expect(applied.last?.themeName == "Midnight")
    }
}
