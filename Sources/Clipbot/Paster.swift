import AppKit
import ClipbotCore

/// Puts an item on the clipboard and pastes it into the app the user was in.
@MainActor
final class Paster {
    private let history: HistoryStore
    private let watcher: PasteboardWatcher
    private let prefs: Preferences

    init(history: HistoryStore, watcher: PasteboardWatcher, prefs: Preferences) {
        self.history = history
        self.watcher = watcher
        self.prefs = prefs
    }

    func paste(entry: ClipEntry, into app: NSRunningApplication?) {
        guard let payload = try? history.payload(for: entry.id) else { NSSound.beep(); return }
        ClipWriter.write(payload, to: .general)
        watcher.noteOwnWrite()
        try? history.moveToTop(entry.id)
        sendPaste(to: app)
    }

    func paste(snippet: Snippet, into app: NSRunningApplication?) {
        ClipWriter.writeText(snippet.content, to: .general)
        watcher.noteOwnWrite()
        sendPaste(to: app)
    }

    private func sendPaste(to app: NSRunningApplication?) {
        app?.activate()
        guard Permissions.accessibilityTrusted else {
            if !prefs.hasShownAccessibilityHelp {
                prefs.hasShownAccessibilityHelp = true
                let a = NSAlert()
                a.messageText = "Copied — but Clipbot can't paste for you yet"
                a.informativeText = "To paste automatically, allow Clipbot in System Settings → Privacy & Security → Accessibility. Until then, press ⌘V yourself."
                a.addButton(withTitle: "Open Settings")
                a.addButton(withTitle: "Not Now")
                NSApp.activate()
                if a.runModal() == .alertFirstButtonReturn { Permissions.openAccessibilitySettings() }
            }
            return
        }
        // Give the target app a moment to become active before the keystroke arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let vKey: CGKeyCode = 0x09
            let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }
}
