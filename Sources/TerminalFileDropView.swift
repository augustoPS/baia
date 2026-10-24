import AppKit
import GhosttyTerminal
import PanePrompt

/// File drops insert paths into the receiving terminal. They never submit input.
final class TerminalFileDropView: TerminalView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSourceOperationMask.contains(.copy),
              foregroundPid != nil,
              payload(from: sender.draggingPasteboard) != nil
        else { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        draggingEntered(sender) == .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard sender.draggingSourceOperationMask.contains(.copy) else { return false }
        return acceptFileDrop(from: sender.draggingPasteboard)
    }

    @discardableResult
    func acceptFileDrop(from pasteboard: NSPasteboard) -> Bool {
        guard foregroundPid != nil, let bytes = payload(from: pasteboard),
              window?.makeFirstResponder(self) == true
        else { return false }
        sendBytes(bytes)
        return true
    }

    private func payload(from pasteboard: NSPasteboard) -> [UInt8]? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }
        var urls: [URL] = []
        for item in items {
            guard let value = item.string(forType: .fileURL), let url = URL(string: value)
            else { return nil }
            urls.append(url)
        }
        guard case let .send(bytes) = TerminalFileDrop.resolve(fileURLs: urls) else { return nil }
        // Reject the whole drop if any item cannot be opened as a local file.
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey]),
                  values.isRegularFile == true, values.isReadable == true
            else { return nil }
        }
        return bytes
    }
}
