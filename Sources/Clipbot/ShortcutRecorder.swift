import AppKit
import ClipbotCore
import SwiftUI

/// Click, then type a shortcut. Esc cancels. Global hotkeys are suspended while recording.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    let defaultValue: Shortcut
    let onRecording: (Bool) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button(recording ? "Type shortcut…" : shortcut.display) { recording ? stop() : start() }
                .frame(minWidth: 130)
            if shortcut != defaultValue {
                Button("Reset") { shortcut = defaultValue }.buttonStyle(.link)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        onRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            MainActor.assumeIsolated { handle(keyCode: keyCode, flags: flags) }
            return nil // swallow every key while recording
        }
    }

    private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        if keyCode == 53 { stop(); return } // Esc
        let s = Shortcut(keyCode: keyCode, modifierFlags: flags)
        if s.isValid {
            shortcut = s
            stop()
        } else {
            NSSound.beep()
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if recording { onRecording(false) }
        recording = false
    }
}
