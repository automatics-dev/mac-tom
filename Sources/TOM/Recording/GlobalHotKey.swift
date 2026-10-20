import Carbon.HIToolbox

/// A system-wide keyboard shortcut via Carbon `RegisterEventHotKey`: fires
/// while any app is frontmost and, unlike an `NSEvent` global monitor, needs
/// no Accessibility permission. Unregistered on deinit, so the shortcut only
/// exists while its owner holds the instance.
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandlerInstalled = false
    private static let signature: OSType = 0x544F_4D4B  // 'TOMK'

    /// `keyCode` is a `kVK_*` constant, `modifiers` a mask of Carbon
    /// `optionKey` / `cmdKey` / … flags. Returns nil when another app already
    /// owns the combination.
    init?(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        Self.installEventHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr else {
            tomLog("GlobalHotKey: register failed (key=\(keyCode), mods=\(modifiers), status=\(status))")
            return nil
        }
        Self.handlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers.removeValue(forKey: id)
    }

    private static func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == GlobalHotKey.signature,
                  let handler = GlobalHotKey.handlers[hotKeyID.id] else {
                return OSStatus(eventNotHandledErr)
            }
            handler()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
