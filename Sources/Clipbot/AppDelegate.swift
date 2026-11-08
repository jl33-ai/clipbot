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
    private var popup: PopupController!
    private var settingsWindow: NSWindow?
    private var editorWindow: NSWindow?
    private var bag: Set<AnyCancellable> = []
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipbot", isDirectory: true) // the original name; kept so existing data opens
        let keys = KeychainKeyStore(service: Bundle.main.bundleIdentifier ?? KeychainKeyStore.appService)
        do {
            history = try HistoryStore(directory: dir, keys: keys)
            snippets = try SnippetStore(directory: dir, keys: keys)
        } catch {
            fail("Dclip can't open its encrypted storage", error)
            return
        }

        watcher = PasteboardWatcher(store: history) { [prefs] in prefs.filter }
        paster = Paster(history: history, watcher: watcher, prefs: prefs)
        popup = PopupController(history: history, snippets: snippets, paster: paster, commands: .init(
            clearHistory: { [weak self] in self?.confirmClearHistory() },
            editSnippets: { [weak self] in self?.showSnippetEditor() },
            settings: { [weak self] in self?.showSettings() }))
        watcher.onSecureInputStuck = { [weak self] holder in self?.warnSecureInput(holder) }
        watcher.start()
        installMainMenu()
        prefs.$showMenuBarIcon
            .receive(on: RunLoop.main)
            .sink { [weak self] show in self?.setMenuBarIcon(show) }
            .store(in: &bag)

        prefs.$shortcuts
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.registerHotKeys($0) }
            .store(in: &bag)

        configureLoginItem()
        warnAboutRecoveredStores()
        if Permissions.pasteboardAccess == .denied { warnPasteboardDenied() }
        if !Permissions.accessibilityTrusted, !prefs.hasPromptedAccessibility {
            prefs.hasPromptedAccessibility = true
            Permissions.requestAccessibility()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return false
    }

    // MARK: Hotkeys

    private func registerHotKeys(_ shortcuts: [ShortcutSlot: Shortcut]) {
        // Unregister all first so swapping two shortcuts doesn't collide with itself.
        for slot in ShortcutSlot.allCases { HotKeys.shared.unregister(slot.id) }
        for slot in ShortcutSlot.allCases {
            HotKeys.shared.register(shortcuts[slot] ?? slot.defaultValue, id: slot.id) { [weak self] in self?.popup.toggle(slot.popupMode) }
        }
    }

    // MARK: Menu bar icon

    private func setMenuBarIcon(_ show: Bool) {
        if show, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Dclip")
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked)
            statusItem = item
        } else if !show, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// Clicking the icon doesn't change the frontmost app, so the picked item pastes where you were.
    @objc private func statusItemClicked() { popup.toggle(.all, below: statusItem?.button) }

    // MARK: Windows

    func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(prefs: prefs,
                                    onClearHistory: { [weak self] in self?.confirmClearHistory() },
                                    onEditSnippets: { [weak self] in self?.showSnippetEditor() },
                                    onRecording: { HotKeys.shared.setSuspended($0) })
            settingsWindow = makeWindow(title: "Dclip Settings", view: view, size: NSSize(width: 520, height: 640))
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
        w.isRestorable = false // never let window state (which can include snippet text) be saved
        w.center()
        return w
    }

    private func present(_ w: NSWindow?) {
        NSApp.activate()
        w?.makeKeyAndOrderFront(nil)
    }

    /// Standard Edit/Window menu so ⌘C/⌘V/⌘X/⌘A/⌘Z/⌘W work in Clipbot's windows (invisible for an agent app).
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Dclip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    private func warnSecureInput(_ holder: String?) {
        Alert.run("Dclip isn't recording copies right now",
                  "Secure keyboard input is on\(holder.map { " (held by \($0))" } ?? ""), so Dclip skips everything you copy — that's how it keeps passwords out. This normally lasts only while a password field is focused. If it keeps happening, the app above may have \"Secure Keyboard Entry\" turned on.")
    }

    // MARK: Actions & alerts

    private func confirmClearHistory() {
        guard Alert.run("Clear all clipboard history?",
                        "This permanently erases all \(history.entries.count) clips and replaces the encryption key, so they can't be recovered. Snippets are kept.",
                        buttons: ["Clear History", "Cancel"], destructive: true) else { return }
        do { try history.clear() } catch { fail("Couldn't clear history", error, fatal: false) }
    }

    /// Turns launch at login on the first time. After that, if the app was moved or renamed (as when
    /// Clipbot became Dclip), the login item still points at the old path, so re-register it here.
    private func configureLoginItem() {
        let service = SMAppService.mainApp
        if !prefs.hasConfiguredLoginItem {
            prefs.hasConfiguredLoginItem = true
            try? service.register()
            prefs.loginItemPath = Bundle.main.bundlePath
        } else if service.status == .enabled, prefs.loginItemPath != Bundle.main.bundlePath {
            try? service.unregister()
            try? service.register()
            prefs.loginItemPath = Bundle.main.bundlePath
            Log.app.info("login item moved to this copy of the app")
        }
    }

    private func warnAboutRecoveredStores() {
        let what = [history.recoveredFromMissingKey ? "clipboard history" : nil,
                    snippets.recoveredFromMissingKey ? "snippets" : nil].compactMap { $0 }
        guard !what.isEmpty else { return }
        Alert.run("Dclip couldn't unlock your saved \(what.joined(separator: " and "))",
                  "Its encryption key is missing or the data is damaged — this happens after moving to a new Mac or resetting the Keychain. Nothing was deleted: the old encrypted files were moved into an \"Unreadable\" folder in Dclip's storage and the old key was set aside. Dclip has started fresh. Use Edit Snippets → Import to restore snippets from an export.")
    }

    private func warnPasteboardDenied() {
        if Alert.run("Dclip isn't allowed to read the clipboard",
                     "Clipboard history stays empty until you allow Dclip to paste from other apps in System Settings → Privacy & Security.",
                     buttons: ["Open Settings", "Later"]) {
            Permissions.openPrivacySettings()
        }
    }

    private func fail(_ title: String, _ error: Error, fatal: Bool = true) {
        Alert.run(title, String(describing: error))
        if fatal { NSApp.terminate(nil) }
    }
}
