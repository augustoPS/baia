import AppKit
import Carbon

/// Owns the system-wide Command + grave shortcut without an event tap or
/// Accessibility permission. Keep one instance alive for the app's lifetime.
@MainActor
final class GlobalTerminalShortcut {
    private let action: () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let identifier = EventHotKeyID(signature: 0x42616961, id: 1) // Baia

    init(action: @escaping () -> Void) {
        self.action = action
    }

    /// Returns the Carbon error if another app owns the shortcut. A failed
    /// registration leaves no handler installed and can be retried.
    @discardableResult
    func register() -> OSStatus {
        guard hotKey == nil else { return noErr }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    let owner = Unmanaged<GlobalTerminalShortcut>.fromOpaque(context)
                        .takeUnretainedValue()
                    var received = EventHotKeyID()
                    let status = GetEventParameter(
                        event, EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &received
                    )
                    guard status == noErr,
                          received.signature == owner.identifier.signature,
                          received.id == owner.identifier.id else {
                        return OSStatus(eventNotHandledErr)
                    }
                    owner.action()
                    return noErr
                }
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard handlerStatus == noErr else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            return handlerStatus
        }

        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_Grave), UInt32(cmdKey), identifier,
            GetApplicationEventTarget(), 0, &hotKey
        )
        if status != noErr {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = nil
            if let handler { RemoveEventHandler(handler) }
            handler = nil
        }
        return status
    }

    isolated deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
