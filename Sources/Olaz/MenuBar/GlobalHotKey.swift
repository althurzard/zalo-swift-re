import Carbon.HIToolbox

/// A system-wide keyboard shortcut (Carbon `RegisterEventHotKey`: needs no Accessibility permission).
/// Actions run on the main actor; call `unregister()` to release the shortcut.
@MainActor
final class GlobalHotKey {
    private static let signature: OSType = 0x4F4C_415A // "OLAZ"
    private static var actions: [UInt32: @MainActor () -> Void] = [:]
    private static var handlerInstalled = false

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// `keyCode` is a virtual key (`kVK_*`), `modifiers` Carbon flags (`cmdKey | optionKey`…).
    /// nil when another app already holds the shortcut.
    init?(keyCode: Int, modifiers: Int, id: UInt32, action: @escaping @MainActor () -> Void) {
        Self.installHandler()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers),
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        self.ref = ref
        self.id = id
        Self.actions[id] = action
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.actions[id] = nil
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr, hotKey.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
            let id = hotKey.id
            Task { @MainActor in GlobalHotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
