import AppKit
import ClipbotCore
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences()
    private var history: HistoryStore!
    private var snippets: SnippetStore!
    private var watcher: PasteboardWatcher!
    private var paster: Paster!
    private var menu: MenuController!
    private var settingsWindow: NSWindow?
    private var editorWindow: NSWindow?
    private var bag: Set<AnyCancellable> = []

    private enum HotKeyID: UInt32 { case main = 1, history, snippets }

    func applicationDidFinishLaunching(_ note: Notification) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipbot", isDirectory: true)
        let keys = KeychainKeyStore()
        do {
            history = try HistoryStore(directory: dir, keys: keys)
            snippets = try SnippetStore(directory: dir, keys: keys)
        } catch {
            fail("Clipbot can't open its encrypted storage", error)
            return
        }

        watcher = PasteboardWatcher(store: history) { [prefs] in prefs.filter }
        paster = Paster(history: history, watcher: watcher, prefs: prefs)
        menu = MenuController(history: history, snippets: snippets, paster: paster)
        menu.onClearHistory = { [weak self] in self?.confirmClearHistory() }
        menu.onEditSnippets = { [weak self] in self?.showSnippetEditor() }
        menu.onSettings = { [weak self] in self?.showSettings() }
        watcher.start()

        registerHotKeys()
        prefs.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.registerHotKeys() }
            .store(in: &bag)

        configureLoginItemOnFirstLaunch()
        warnAboutRecoveredStores()
        if Permissions.pasteboardAccess == .denied { warnPasteboardDenied() }
        if !Permissions.accessibilityTrusted { Permissions.requestAccessibility() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return false
    }

    // MARK: Hotkeys

    private func registerHotKeys() {
        let h = HotKeys.shared
        h.register(prefs.mainShortcut, id: HotKeyID.main.rawValue) { [weak self] in self?.menu.show(.all) }
        h.register(prefs.historyShortcut, id: HotKeyID.history.rawValue) { [weak self] in self?.menu.show(.history) }
        h.register(prefs.snippetsShortcut, id: HotKeyID.snippets.rawValue) { [weak self] in self?.menu.show(.snippets) }
    }

    // MARK: Windows

    func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(prefs: prefs,
                                    onClearHistory: { [weak self] in self?.confirmClearHistory() },
                                    onRecording: { HotKeys.shared.setSuspended($0) })
            settingsWindow = makeWindow(title: "Clipbot Settings", view: view, size: NSSize(width: 520, height: 640))
        }
        present(settingsWindow)
    }

    func showSnippetEditor() {
        if editorWindow == nil {
            editorWindow = makeWindow(title: "Snippets", view: SnippetEditorView(store: snippets), size: NSSize(width: 820, height: 480))
        }
        present(editorWindow)
    }

    private func makeWindow<V: View>(title: String, view: V, size: NSSize) -> NSWindow {
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = title
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(size)
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }

    private func present(_ w: NSWindow?) {
        NSApp.activate()
        w?.makeKeyAndOrderFront(nil)
    }

    // MARK: Actions & alerts

    private func confirmClearHistory() {
        let a = NSAlert()
        a.messageText = "Clear all clipboard history?"
        a.informativeText = "This permanently erases all \(history.entries.count) clips and replaces the encryption key, so they can't be recovered. Snippets are kept."
        a.addButton(withTitle: "Clear History")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do { try history.clear() } catch { fail("Couldn't clear history", error, fatal: false) }
    }

    private func configureLoginItemOnFirstLaunch() {
        guard !prefs.hasConfiguredLoginItem else { return }
        prefs.hasConfiguredLoginItem = true
        try? SMAppService.mainApp.register()
    }

    private func warnAboutRecoveredStores() {
        var what: [String] = []
        if history.recoveredFromMissingKey { what.append("clipboard history") }
        if snippets.recoveredFromMissingKey { what.append("snippets") }
        guard !what.isEmpty else { return }
        let a = NSAlert()
        a.messageText = "Clipbot couldn't unlock your saved \(what.joined(separator: " and "))"
        a.informativeText = "Its encryption key is missing or the data is damaged — this happens after moving to a new Mac or resetting the Keychain. Nothing was deleted: the old encrypted files were moved into an \"Unreadable\" folder in Clipbot's storage, and Clipbot has started fresh. Use Edit Snippets → Import to restore snippets from an export."
        NSApp.activate()
        a.runModal()
    }

    private func warnPasteboardDenied() {
        let a = NSAlert()
        a.messageText = "Clipbot isn't allowed to read the clipboard"
        a.informativeText = "Clipboard history stays empty until you allow Clipbot to paste from other apps in System Settings → Privacy & Security."
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Later")
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn { Permissions.openPrivacySettings() }
    }

    private func fail(_ title: String, _ error: Error, fatal: Bool = true) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = String(describing: error)
        NSApp.activate()
        a.runModal()
        if fatal { NSApp.terminate(nil) }
    }
}
