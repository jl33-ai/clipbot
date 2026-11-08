import AppKit
import ClipbotCore
import SwiftUI

/// Opens the Maccy-style popup (search box, list, footer) and turns its keys and clicks into
/// pastes and commands.
@MainActor
final class PopupController {
    struct Commands {
        let clearHistory: () -> Void
        let editSnippets: () -> Void
        let settings: () -> Void
    }

    private let history: HistoryStore
    private let snippets: SnippetStore
    private let paster: Paster
    private let commands: Commands
    private let panel = PopupPanel()
    private var state: PopupState?
    /// The app that was in front when the popup opened; picks paste into it.
    private var target: NSRunningApplication?
    private var monitors: [Any] = []
    /// When the panel last closed by losing focus. Clicking the menu bar icon while the popup is
    /// open first takes focus away (closing it) and then clicks; that click must not reopen it.
    private var lastFocusClose = Date.distantPast

    init(history: HistoryStore, snippets: SnippetStore, paster: Paster, commands: Commands) {
        self.history = history
        self.snippets = snippets
        self.paster = paster
        self.commands = commands
        panel.onResignKey = { [weak self] in
            self?.lastFocusClose = Date()
            self?.close()
        }
    }

    var isOpen: Bool { state != nil }

    /// A shortcut or the menu bar icon: opens the popup, or closes it if it is already open in
    /// that mode (pressing the shortcut again), or switches to the other mode.
    func toggle(_ mode: PopupMode, below anchor: NSStatusBarButton? = nil) {
        if let state {
            if state.list.mode == mode { close() } else { open(mode, below: anchor) }
            return
        }
        if anchor != nil, Date().timeIntervalSince(lastFocusClose) < 0.3 { return }
        open(mode, below: anchor)
    }

    private func open(_ mode: PopupMode, below anchor: NSStatusBarButton?) {
        if state == nil {
            let front = NSWorkspace.shared.frontmostApplication
            target = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        }
        let list = PopupList(mode: mode, history: history.entries, folders: snippets.folders)
        let state = PopupState(list: list, actions: PopupActions(
            pick: { [weak self] in self?.pick($0) },
            clearHistory: { [weak self] in self?.closeThen { $0.commands.clearHistory() } },
            editSnippets: { [weak self] in self?.closeThen { $0.commands.editSnippets() } },
            settings: { [weak self] in self?.closeThen { $0.commands.settings() } },
            quit: { NSApp.terminate(nil) }))
        state.onResultsChange = { [weak self] in DispatchQueue.main.async { self?.resize() } }
        self.state = state
        // A fresh view each time, so the search field takes focus and nothing from last time stays.
        panel.setContent(NSHostingView(rootView: PopupView(state: state)))
        if panel.isVisible {
            panel.setHeight(PopupLayout.height(list))
        } else {
            panel.open(height: PopupLayout.height(list), below: anchor)
            installMonitors()
        }
        Log.app.info("popup shown: history=\(self.history.entries.count, privacy: .public)")
    }

    func close() {
        guard state != nil else { return }
        state = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel.orderOut(nil)
        panel.contentView = nil // drop the view (and the clip titles it holds)
    }

    // MARK: Keys

    private func installMonitors() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) ?? false } ? nil : event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated {
                if let state = self?.state, state.keyboardNavigating { state.keyboardNavigating = false }
            }
            return event
        } as Any)
    }

    /// True when the popup handled the key; otherwise it goes on to the search box.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === panel, let state else { return false }
        // While an input method is composing (e.g. Japanese), its keys are its own.
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        guard let command = PopupKeys.command(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return false }

        switch command {
        case .moveDown: navigate { $0.moveDown() }
        case .moveUp: navigate { $0.moveUp() }
        case .moveToFirst: navigate { $0.moveToFirst() }
        case .moveToLast: navigate { $0.moveToLast() }
        case .paste:
            if let item = state.list.selected { pick(item) } else { NSSound.beep() }
        case .pasteRow(let row):
            if let item = state.list.item(atShortcutRow: row) { pick(item) } else { NSSound.beep() }
        case .escape:
            if state.list.escape() { close() }
        case .deleteItem:
            deleteSelected()
        case .clearHistory:
            closeThen { $0.commands.clearHistory() }
        case .settings:
            closeThen { $0.commands.settings() }
        case .quit:
            NSApp.terminate(nil)
        }
        return true
    }

    private func navigate(_ move: (inout PopupList) -> Void) {
        guard let state else { return }
        state.keyboardNavigating = true
        move(&state.list)
    }

    /// ⌥⌫ removes the selected clip from history. Snippets are only changed in the editor.
    private func deleteSelected() {
        guard let state, let item = state.list.selected, case .clip(let e) = item.source else { NSSound.beep(); return }
        do {
            try history.delete(e.id)
            state.keyboardNavigating = true
            state.list.remove(id: e.id)
        } catch {
            Log.app.error("delete failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
    }

    // MARK: Picking

    private func pick(_ item: PopupItem) {
        let target = target
        close()
        switch item.source {
        case .clip(let e): paster.paste(entry: e, into: target)
        case .snippet(let s): paster.paste(snippet: s, into: target)
        }
    }

    /// Footer commands open windows or alerts, so the popup closes first.
    private func closeThen(_ run: @escaping (PopupController) -> Void) {
        close()
        DispatchQueue.main.async { [weak self] in if let self { run(self) } }
    }

    // MARK: Size

    /// Typing filters the list; the panel follows its height, keeping its top edge.
    private func resize() {
        if let state { panel.setHeight(PopupLayout.height(state.list)) }
    }
}
