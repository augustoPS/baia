#if DEBUG
import AppKit

/// Calls the shipped drag destination methods in a disposable app and real PTY.
@MainActor
enum FileDropSelfCheck {
    static func runIfRequested(in delegate: AppDelegate) {
        guard let path = ProcessInfo.processInfo.environment["BAIA_FILE_DROP_SELFCHECK_ROOT"] else { return }
        guard SupportDirectory.name.hasPrefix("baia-file-drop."), path.hasPrefix("/"),
              ProcessInfo.processInfo.environment["BAIA_CONFIG_FILE"] != nil
        else { return }
        let root = URL(filePath: path)
        poll(in: delegate, root: root, remaining: 100)
    }

    private static func poll(in delegate: AppDelegate, root: URL, remaining: Int) {
        guard remaining > 0 else {
            emit(["ready": false], root: root)
            return
        }
        guard FileManager.default.fileExists(atPath: root.appending(path: "receiver.ready").path),
              let window = delegate.windows.first?.window,
              let content = window.contentView,
              let terminal = terminals(in: content).first,
              terminal.foregroundPid != nil
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                poll(in: delegate, root: root, remaining: remaining - 1)
            }
            return
        }
        do {
            let data = try Data(contentsOf: root.appending(path: "manifest.json"))
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            let urls = try manifest.files.map { file in
                guard let url = URL(string: file.url) else { throw CocoaError(.fileReadCorruptFile) }
                return url
            }
            var checks = ["ready": true, "registered": terminal.registeredDraggedTypes.contains(.fileURL)]
            let midpoint = terminal.convert(NSPoint(x: terminal.bounds.midX, y: terminal.bounds.midY), to: content)
            let hit = content.hitTest(midpoint)
            checks["terminalHitTarget"] = hit === terminal || hit?.isDescendant(of: terminal) == true
            let other = NSTextField(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
            content.addSubview(other)
            checks["focusStartsElsewhere"] = window.makeFirstResponder(other) && window.firstResponder !== terminal
            let beforeHover = window.firstResponder
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally(); other.removeFromSuperview() }
            func set(_ values: [String], type: NSPasteboard.PasteboardType = .fileURL) {
                board.clearContents()
                let items = values.map { value in
                    let item = NSPasteboardItem(); item.setString(value, forType: type); return item
                }
                board.writeObjects(items)
            }
            let drag = FileDropDraggingInfo(pasteboard: board, window: window)
            set([])
            checks["emptyRejected"] = !terminal.performDragOperation(drag)
            set(["not a file"], type: .string)
            checks["textRejected"] = !terminal.performDragOperation(drag)
            set(["https://example.com/image.png"])
            checks["remoteRejected"] = !terminal.performDragOperation(drag)
            set([root.appending(path: "absent.png").absoluteString])
            checks["missingRejected"] = !terminal.performDragOperation(drag)
            set([root.absoluteString])
            checks["directoryRejected"] = !terminal.performDragOperation(drag)
            set([root.appending(path: "bad\n.png").absoluteString])
            checks["controlRejected"] = !terminal.performDragOperation(drag)
            set([urls[0].absoluteString, root.appending(path: "absent.png").absoluteString])
            checks["partialRejected"] = !terminal.performDragOperation(drag)
            set(urls.map(\.absoluteString))
            drag.draggingSourceOperationMask = .move
            checks["moveOnlyRejected"] = terminal.draggingEntered(drag).isEmpty && !terminal.performDragOperation(drag)
            drag.draggingSourceOperationMask = .copy
            let unattached = TerminalFileDropView(frame: .zero)
            checks["unreadyRejected"] = !unattached.acceptFileDrop(from: board)
            checks["hoverCopy"] = terminal.draggingEntered(drag) == .copy && terminal.draggingUpdated(drag) == .copy
            checks["hoverPreservesFocus"] = beforeHover === window.firstResponder
            checks["prepare"] = terminal.prepareForDragOperation(drag)
            checks["dropAccepted"] = terminal.performDragOperation(drag)
            checks["receivingTerminalFocused"] = window.firstResponder === terminal
            emit(checks, root: root)
        } catch { emit(["manifestReadable": false], root: root) }
    }

    private struct Manifest: Decodable {
        struct File: Decodable { let url: String }
        let files: [File]
    }

    private static func terminals(in view: NSView) -> [TerminalFileDropView] {
        (view as? TerminalFileDropView).map { [$0] } ?? view.subviews.flatMap(terminals)
    }

    private static func emit(_ checks: [String: Bool], root: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["checks": checks], options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: root.appending(path: "adapter-result.json"), options: .atomic)
    }
}

@MainActor
private final class FileDropDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
    let draggingLocation = NSPoint.zero
    let draggedImageLocation = NSPoint.zero
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    let springLoadingHighlight: NSSpringLoadingHighlight = .none
    init(pasteboard: NSPasteboard, window: NSWindow) {
        draggingPasteboard = pasteboard; draggingDestinationWindow = window
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
#endif
