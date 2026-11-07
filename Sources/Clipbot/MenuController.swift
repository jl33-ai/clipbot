import AppKit
import ClipbotCore

enum MenuMode { case all, history, snippets }

/// Builds and pops up the Clipy-style menu at the mouse cursor.
@MainActor
final class MenuController: NSObject {
    private let history: HistoryStore
    private let snippets: SnippetStore
    private let paster: Paster
    var onClearHistory: () -> Void = {}
    var onEditSnippets: () -> Void = {}
    var onSettings: () -> Void = {}

    private enum Pick { case clip(ClipEntry), snippet(Snippet), command(() -> Void) }
    private var pick: Pick?

    init(history: HistoryStore, snippets: SnippetStore, paster: Paster) {
        self.history = history
        self.snippets = snippets
        self.paster = paster
    }

    private var isShowing = false

    func show(_ mode: MenuMode) {
        // A hotkey can arrive while the menu (or an alert from it) is already up; never nest.
        guard !isShowing else { return }
        isShowing = true
        defer { isShowing = false }
        let front = NSWorkspace.shared.frontmostApplication
        let target = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        pick = nil
        let menu = build(mode)
        Log.app.info("menu shown: history=\(self.history.entries.count, privacy: .public)")
        NSApp.activate()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)

        switch pick {
        case .clip(let e): paster.paste(entry: e, into: target)
        case .snippet(let s): paster.paste(snippet: s, into: target)
        case .command(let run): run()
        case nil: target?.activate()
        }
        pick = nil
    }

    // MARK: Building

    private func build(_ mode: MenuMode) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if mode != .snippets { addHistory(to: menu) }
        if mode == .all { menu.addItem(.separator()) }
        if mode != .history { addSnippets(to: menu) }
        menu.addItem(.separator())
        menu.addItem(command("Clear History…") { [weak self] in self?.onClearHistory() })
        menu.addItem(command("Edit Snippets…") { [weak self] in self?.onEditSnippets() })
        menu.addItem(command("Settings…") { [weak self] in self?.onSettings() })
        menu.addItem(command("Quit Clipbot") { NSApp.terminate(nil) })
        return menu
    }

    private func addHistory(to menu: NSMenu) {
        menu.addItem(.sectionHeader(title: "History"))
        let groups = MenuModel.groups(history.entries)
        if groups.isEmpty { menu.addItem(disabled("No history yet")) }
        for g in groups {
            let sub = NSMenu(title: g.title)
            sub.autoenablesItems = false
            for (i, e) in g.items.enumerated() {
                let item = NSMenuItem(title: e.preview, action: #selector(choose(_:)), keyEquivalent: MenuModel.keyEquivalent(forIndexInGroup: i))
                item.keyEquivalentModifierMask = []
                item.target = self
                item.representedObject = Box(Pick.clip(e))
                item.image = image(for: e)
                sub.addItem(item)
            }
            let parent = NSMenuItem(title: g.title, action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
    }

    private func addSnippets(to menu: NSMenu) {
        menu.addItem(.sectionHeader(title: "Snippets"))
        let folders = snippets.folders.filter(\.enabled)
        if folders.isEmpty { menu.addItem(disabled("No snippets")) }
        for f in folders {
            let sub = NSMenu(title: f.title)
            sub.autoenablesItems = false
            let enabled = f.snippets.filter(\.enabled)
            if enabled.isEmpty { sub.addItem(disabled("Empty")) }
            for (i, s) in enabled.enumerated() {
                let item = NSMenuItem(title: MenuModel.previewText(s.title.isEmpty ? s.content : s.title),
                                      action: #selector(choose(_:)), keyEquivalent: MenuModel.keyEquivalent(forIndexInGroup: i))
                item.keyEquivalentModifierMask = []
                item.target = self
                item.representedObject = Box(Pick.snippet(s))
                sub.addItem(item)
            }
            let parent = NSMenuItem(title: f.title.isEmpty ? "Untitled" : f.title, action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
    }

    private func image(for e: ClipEntry) -> NSImage? {
        switch e.kind {
        case .image:
            guard let d = e.thumbnail, let img = NSImage(data: d) else { return nil }
            let side: CGFloat = 32
            let s = img.size
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

    private func command(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = Box(Pick.command(run))
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func choose(_ sender: NSMenuItem) {
        pick = (sender.representedObject as? Box<Pick>)?.value
    }

    private final class Box<T>: NSObject { let value: T; init(_ v: T) { value = v } }
}
