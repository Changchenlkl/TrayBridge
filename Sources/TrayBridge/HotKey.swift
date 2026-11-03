import Carbon
import Foundation

final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?
    private(set) var registered = false

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x54425247, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { [weak owner] in owner?.onPress?() }
            return noErr
        }, 1, &eventType, context, &handler)
        guard installed == noErr else { return }
        let identifier = EventHotKeyID(signature: 0x54425247, id: 1)
        registered = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey),
                                        identifier, GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
