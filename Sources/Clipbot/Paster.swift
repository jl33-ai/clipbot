import AppKit
import ClipbotCore

/// Puts an item on the clipboard and pastes it into the app the user was in — and only that app.
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
        guard Permissions.accessibilityTrusted else {
            app?.activate()
            explainAccessibilityOnce()
            return
        }
        let targetPID = app?.processIdentifier ?? ProcessInfo.processInfo.processIdentifier
        app?.activate()
        // Post ⌘V only once the target is verifiably frontmost; otherwise the clip could land in
        // whatever app grabbed focus. On timeout the item just stays on the clipboard.
        waitForFront(targetPID, deadline: Date().addingTimeInterval(0.6)) { ok in
            guard ok else { Log.app.info("paste skipped: target app never became frontmost"); return }
            Self.postCommandV()
        }
    }

    private func waitForFront(_ pid: pid_t, deadline: Date, then done: @escaping (Bool) -> Void) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            // Small settle delay so the app's key window is ready for the keystroke.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                done(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)
            }
            return
        }
        guard Date() < deadline else { done(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.waitForFront(pid, deadline: deadline, then: done)
        }
    }

    private static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func explainAccessibilityOnce() {
        guard !prefs.hasShownAccessibilityHelp else { return }
        prefs.hasShownAccessibilityHelp = true
        let a = NSAlert()
        a.messageText = "Copied — but Clipbot can't paste for you yet"
        a.informativeText = "To paste automatically, allow Clipbot in System Settings → Privacy & Security → Accessibility. Until then, press ⌘V yourself."
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Not Now")
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn { Permissions.openAccessibilitySettings() }
    }
}
