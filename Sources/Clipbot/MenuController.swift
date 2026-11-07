import AppKit
import ClipbotCore

enum MenuMode { case all, history, snippets }

/// Builds and pops up the Clipy-style menu at the mouse cursor.
@MainActor
final class MenuController {
    struct Commands {
        let clearHistory: () -> Void
        let editSnippets: () -> Void
        let settings: () -> Void
    }

    private let history: HistoryStore
    private let snippets: SnippetStore
    private let paster: Paster
    private let commands: Commands
    /// What the picked item does; run after the menu has closed and focus is back where it was.
    private var pending: (() -> Void)?
    private var isShowing = false

    init(history: HistoryStore, snippets: SnippetStore, paster: Paster, commands: Commands) {
        self.history = history
        self.snippets = snippets
        self.paster = paster
        self.commands = commands
    }

    func show(_ mode: MenuMode) {
        // A hotkey can arrive while the menu (or an alert from it) is already up; never nest.
        guard !isShowing else { return }
        isShowing = true
        defer { isShowing = false }

        let front = NSWorkspace.shared.frontmostApplication
        let target = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        pending = nil
        let menu = build(mode, target: target)
        Log.app.info("menu shown: history=\(self.history.entries.count, privacy: .public)")
        NSApp.activate()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)

        if let run = pending { run() } else { target?.activate() }
        pending = nil
    }

    // MARK: Building

    private func build(_ mode: MenuMode, target: NSRunningApplication?) -> NSMenu {
        let menu = Self.menu()
        if mode != .snippets { addHistory(to: menu, target: target) }
        if mode == .all { menu.addItem(.separator()) }
        if mode != .history { addSnippets(to: menu, target: target) }
        menu.addItem(.separator())
        menu.addItem(item("Clear History…") { [commands] in commands.clearHistory() })
        menu.addItem(item("Edit Snippets…") { [commands] in commands.editSnippets() })
        menu.addItem(item("Settings…") { [commands] in commands.settings() })
        menu.addItem(item("Quit Clipbot") { NSApp.terminate(nil) })
        return menu
    }

    private func addHistory(to menu: NSMenu, target: NSRunningApplication?) {
        menu.addItem(.sectionHeader(title: "History"))
        let groups = MenuModel.groups(history.entries)
        if groups.isEmpty { menu.addItem(Self.disabled("No history yet")) }
        for g in groups {
            menu.addItem(Self.submenu(g.title, g.items.enumerated().map { i, e in
                let it = item(e.preview, key: MenuModel.keyEquivalent(forIndexInGroup: i)) { [paster] in paster.paste(entry: e, into: target) }
                it.image = Self.image(for: e)
                return it
            }))
        }
    }

    private func addSnippets(to menu: NSMenu, target: NSRunningApplication?) {
        menu.addItem(.sectionHeader(title: "Snippets"))
        let folders = snippets.folders.filter(\.enabled)
        if folders.isEmpty { menu.addItem(Self.disabled("No snippets")) }
        for f in folders {
            let items = f.snippets.filter(\.enabled).enumerated().map { i, s in
                item(Preview.text(s.title.isEmpty ? s.content : s.title), key: MenuModel.keyEquivalent(forIndexInGroup: i)) { [paster] in
                    paster.paste(snippet: s, into: target)
                }
            }
            menu.addItem(Self.submenu(f.title.isEmpty ? "Untitled" : f.title, items.isEmpty ? [Self.disabled("Empty")] : items))
        }
    }

    // MARK: Items

    /// A menu item whose action is recorded, and run once the menu has closed.
    private func item(_ title: String, key: String = "", _ action: @escaping () -> Void) -> NSMenuItem {
        let it = ActionItem(title: title, action: #selector(ActionItem.fire), keyEquivalent: key)
        it.keyEquivalentModifierMask = []
        it.target = it
        it.onPick = { [weak self] in self?.pending = action }
        return it
    }

    private static func menu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        return m
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let sub = menu()
        items.forEach(sub.addItem)
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    private static func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private static func image(for e: ClipEntry) -> NSImage? {
        switch e.kind {
        case .image:
            guard let d = e.thumbnail, let img = NSImage(data: d) else { return nil }
            let side: CGFloat = 32, s = img.size
            let scale = min(side / max(s.width, 1), side / max(s.height, 1), 1)
            img.size = NSSize(width: s.width * scale, height: s.height * scale)
            return img
        case .file:
            let img = NSWorkspace.shared.icon(for: .item)
            img.size = NSSize(width: 16, height: 16)
            return img
        default:
            return nil
        }
    }
}

private final class ActionItem: NSMenuItem {
    var onPick: (() -> Void)?
    @objc func fire() { onPick?() }
}
