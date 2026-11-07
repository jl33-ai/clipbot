import AppKit
import Carbon.HIToolbox
import ClipbotCore

/// System-wide hotkeys via Carbon `RegisterEventHotKey` (no Accessibility needed, no dependencies).
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    private struct Binding { let shortcut: Shortcut; let action: () -> Void; var ref: EventHotKeyRef? }
    private var bindings: [UInt32: Binding] = [:]
    private var handler: EventHandlerRef?
    private var suspended = false
    private let signature: OSType = 0x434C_4250 // 'CLBP'

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// Returns false when the combination is taken (by another app or another Clipbot shortcut).
    @discardableResult
    func register(_ shortcut: Shortcut, id: UInt32, action: @escaping () -> Void) -> Bool {
        unregister(id)
        var b = Binding(shortcut: shortcut, action: action, ref: nil)
        let ok = suspended || install(&b, id: id)
        bindings[id] = b
        return ok
    }

    func unregister(_ id: UInt32) {
        if let ref = bindings[id]?.ref { UnregisterEventHotKey(ref) }
        bindings[id] = nil
    }

    /// While the Settings recorder is listening, hotkeys must not fire.
    func setSuspended(_ value: Bool) {
        guard value != suspended else { return }
        suspended = value
        for id in bindings.keys {
            guard var b = bindings[id] else { continue }
            if value {
                if let ref = b.ref { UnregisterEventHotKey(ref) }
                b.ref = nil
            } else {
                _ = install(&b, id: id)
            }
            bindings[id] = b
        }
    }

    private func install(_ b: inout Binding, id: UInt32) -> Bool {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(b.shortcut.keyCode, b.shortcut.carbonModifiers,
                                         EventHotKeyID(signature: signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        b.ref = status == noErr ? ref : nil
        if status != noErr { Log.app.error("hotkey \(id, privacy: .public) register failed: \(status, privacy: .public)") }
        return status == noErr
    }

    private func fire(_ id: UInt32) {
        guard !suspended else { return }
        Log.app.info("hotkey \(id, privacy: .public) fired")
        bindings[id]?.action()
    }
}
