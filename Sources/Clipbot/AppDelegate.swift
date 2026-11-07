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
    private var statusItem: NSStatusItem?

    private enum HotKeyID: UInt32, CaseIterable { case main = 1, history, snippets }

    func applicationDidFinishLaunching(_ note: Notification) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipbot", isDirectory: true)
        let keys = KeychainKeyStore(service: Bundle.main.bundleIdentifier ?? KeychainKeyStore.appService)
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
        watcher.onSecureInputStuck = { [weak self] holder in self?.warnSecureInput(holder) }
        watcher.start()
        installMainMenu()
        prefs.$showMenuBarIcon
            .receive(on: RunLoop.main)
            .sink { [weak self] show in self?.setMenuBarIcon(show) }
            .store(in: &bag)

        registerHotKeys()
        Publishers.Merge3(prefs.$mainShortcut.map { _ in () }, prefs.$historyShortcut.map { _ in () },
                          prefs.$snippetsShortcut.map { _ in () })
            .dropFirst(3)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.registerHotKeys() }
            .store(in: &bag)

        configureLoginItemOnFirstLaunch()
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

    private func registerHotKeys() {
        let h = HotKeys.shared
        for id in HotKeyID.allCases { h.unregister(id.rawValue) }
        var conflicts: Set<String> = []
        if !h.register(prefs.mainShortcut, id: HotKeyID.main.rawValue, action: { [weak self] in self?.menu.show(.all) }) { conflicts.insert("main") }
        if !h.register(prefs.historyShortcut, id: HotKeyID.history.rawValue, action: { [weak self] in self?.menu.show(.history) }) { conflicts.insert("history") }
        if !h.register(prefs.snippetsShortcut, id: HotKeyID.snippets.rawValue, action: { [weak self] in self?.menu.show(.snippets) }) { conflicts.insert("snippets") }
        if prefs.shortcutConflicts != conflicts { prefs.shortcutConflicts = conflicts }
    }

    // MARK: Menu bar icon

    private func setMenuBarIcon(_ show: Bool) {
        if show, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Clipbot")
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked)
            statusItem = item
        } else if !show, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// Clicking the icon doesn't change the frontmost app, so the picked item pastes where you were.
    @objc private func statusItemClicked() { menu.show(.all) }

    // MARK: Windows

    func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(prefs: prefs,
                                    onClearHistory: { [weak self] in self?.confirmClearHistory() },
                                    onEditSnippets: { [weak self] in self?.showSnippetEditor() },
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
        appMenu.addItem(withTitle: "Quit Clipbot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        let a = NSAlert()
        a.messageText = "Clipbot isn't recording copies right now"
        a.informativeText = "Secure keyboard input is on\(holder.map { " (held by \($0))" } ?? ""), so Clipbot skips everything you copy — that's how it keeps passwords out. This normally lasts only while a password field is focused. If it keeps happening, the app above may have \"Secure Keyboard Entry\" turned on."
        NSApp.activate()
        a.runModal()
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
