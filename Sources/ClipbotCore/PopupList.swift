import Foundation

/// Which items a shortcut opens the popup with.
public enum PopupMode: Sendable { case all, history, snippets }

/// One row of the popup: a clip from history or a snippet.
public struct PopupItem: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case clip(ClipEntry)
        case snippet(Snippet)
    }

    public let source: Source
    public let title: String
    /// What the search box matches against (full text, not just the one-line title).
    public let searchText: String

    public var id: UUID {
        switch source {
        case .clip(let e): e.id
        case .snippet(let s): s.id
        }
    }

    public var isSnippet: Bool {
        if case .snippet = source { true } else { false }
    }

    public init(clip e: ClipEntry) {
        source = .clip(e)
        title = e.preview
        searchText = e.searchText ?? e.preview
    }

    public init(snippet s: Snippet) {
        source = .snippet(s)
        title = Preview.text(s.title.isEmpty ? s.content : s.title)
        searchText = s.title + "\n" + s.content
    }
}

/// The popup's state: everything it could show, the search query, what matches, and which row
/// is selected. Pure value logic so every edge case is unit-tested.
public struct PopupList: Equatable, Sendable {
    public let mode: PopupMode
    public private(set) var items: [PopupItem]
    public private(set) var results: [PopupItem]
    /// Index into `results`; nil only when there are no results.
    public private(set) var selection: Int?

    public var query: String = "" {
        didSet { if query != oldValue { filter() } }
    }

    /// Rows with a ⌘-number shortcut: ⌘1…⌘9, then ⌘0 for the tenth.
    public static let shortcutCount = 10

    public init(mode: PopupMode, history: [ClipEntry], folders: [SnippetFolder]) {
        self.mode = mode
        var items: [PopupItem] = []
        if mode != .snippets { items += history.map(PopupItem.init(clip:)) }
        if mode != .history {
            items += folders.filter(\.enabled).flatMap { $0.snippets.filter(\.enabled) }.map(PopupItem.init(snippet:))
        }
        self.items = items
        results = items
        selection = items.isEmpty ? nil : 0
    }

    public var selected: PopupItem? { selection.map { results[$0] } }

    /// Snippets come after history; the header goes before the first one, but only when history
    /// rows are shown above it.
    public var firstSnippetIndex: Int? {
        guard let i = results.firstIndex(where: \.isSnippet), i > 0 else { return nil }
        return i
    }

    // MARK: Moving the selection (stops at the ends, like Maccy)

    public mutating func moveDown() { if let s = selection { selection = min(s + 1, results.count - 1) } }
    public mutating func moveUp() { if let s = selection { selection = max(s - 1, 0) } }
    public mutating func moveToFirst() { if !results.isEmpty { selection = 0 } }
    public mutating func moveToLast() { if !results.isEmpty { selection = results.count - 1 } }

    public mutating func select(id: UUID) {
        if let i = results.firstIndex(where: { $0.id == id }) { selection = i }
    }

    // MARK: Shortcuts

    /// "1"…"9", "0" for the first ten rows; nil for the rest.
    public static func shortcutKey(forRow row: Int) -> String? {
        switch row {
        case 0..<9: String(row + 1)
        case 9: "0"
        default: nil
        }
    }

    /// The item ⌘<row+1> picks, if that row exists.
    public func item(atShortcutRow row: Int) -> PopupItem? {
        row >= 0 && row < Self.shortcutCount && row < results.count ? results[row] : nil
    }

    // MARK: Changes

    /// Esc clears the search first; returns true when there is nothing left to clear and the
    /// popup should close.
    public mutating func escape() -> Bool {
        guard query.isEmpty else { query = ""; return false }
        return true
    }

    /// Removes an item (after it was deleted from history). The selection stays on the same row,
    /// or moves up when the last row went.
    public mutating func remove(id: UUID) {
        items.removeAll { $0.id == id }
        guard let i = results.firstIndex(where: { $0.id == id }) else { return }
        results.remove(at: i)
        if results.isEmpty {
            selection = nil
        } else if let s = selection, s >= i {
            selection = s == i ? min(s, results.count - 1) : s - 1
        }
    }

    private mutating func filter() {
        results = query.allSatisfy({ $0.isWhitespace || $0.isNewline })
            ? items
            : items.filter { PopupSearch.matches(query, in: $0.searchText) }
        selection = results.isEmpty ? nil : 0
    }
}
