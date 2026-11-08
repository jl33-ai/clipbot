// The popup's look is adapted from Maccy's ContentView, HeaderView, SearchFieldView, ListItemView,
// FooterView and VisualEffectView (https://github.com/p0deje/Maccy), MIT License,
// Copyright (c) 2025 Alex Rodionov. See docs/licenses/Maccy.txt.
import AppKit
import ClipbotCore
import SwiftUI

/// Sizes, from Maccy's Popup constants. Every row has a fixed height so the panel's height can be
/// computed exactly from what it shows.
enum PopupLayout {
    static let width: CGFloat = 450
    static let padding: CGFloat = 5
    static let separatorPadding: CGFloat = 6
    static let cornerRadius: CGFloat = if #available(macOS 26.0, *) { 7 } else { 4 }
    static let windowCornerRadius: CGFloat = cornerRadius + padding
    static let rowHeight: CGFloat = if #available(macOS 26.0, *) { 24 } else { 22 }
    static let imageRowHeight: CGFloat = 40
    static let sectionHeight: CGFloat = 22
    static let searchHeight: CGFloat = 23
    static let headerHeight: CGFloat = padding + searchHeight
    static let maxListHeight: CGFloat = 480
    static let footerRows = 4
    static let footerHeight: CGFloat = 1 + separatorPadding + CGFloat(footerRows) * rowHeight + padding

    static func rowHeight(_ item: PopupItem) -> CGFloat {
        if case .clip(let e) = item.source, e.kind == .image, e.thumbnail != nil { return imageRowHeight }
        return rowHeight
    }

    static func listHeight(_ list: PopupList) -> CGFloat {
        let rows = list.results.isEmpty ? rowHeight : list.results.reduce(0) { $0 + rowHeight($1) }
        let section = list.firstSnippetIndex == nil ? 0 : sectionHeight
        return min(rows + section + 2 * separatorPadding, maxListHeight)
    }

    static func height(_ list: PopupList) -> CGFloat { headerHeight + listHeight(list) + footerHeight }
}

/// What the view reads and the controller changes.
@MainActor
final class PopupState: ObservableObject {
    @Published var list: PopupList {
        didSet { if list.results.map(\.id) != oldValue.results.map(\.id) { onResultsChange?() } }
    }
    /// Called when the rows shown change (typing, deleting), so the panel can fit them.
    var onResultsChange: (() -> Void)?
    /// True after a key moved the selection; hovering only selects once the mouse really moves,
    /// so a list scrolling under a still pointer doesn't steal the selection.
    @Published var keyboardNavigating = true
    let actions: PopupActions
    private var thumbnails: [UUID: NSImage] = [:]

    init(list: PopupList, actions: PopupActions) {
        self.list = list
        self.actions = actions
    }

    func thumbnail(_ e: ClipEntry) -> NSImage? {
        if let img = thumbnails[e.id] { return img }
        guard let d = e.thumbnail, let img = NSImage(data: d) else { return nil }
        thumbnails[e.id] = img
        return img
    }
}

struct PopupActions {
    let pick: (PopupItem) -> Void
    let clearHistory: () -> Void
    let editSnippets: () -> Void
    let settings: () -> Void
    let quit: () -> Void
}

struct PopupView: View {
    @ObservedObject var state: PopupState

    var body: some View {
        ZStack {
            if #available(macOS 26.0, *) { GlassEffectView() } else { VisualEffectView() }
            VStack(spacing: 0) {
                header
                list
                footer
            }
            .padding(.horizontal, PopupLayout.padding)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Dclip")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
            SearchFieldView(query: $state.list.query)
        }
        .frame(height: PopupLayout.searchHeight)
        .padding(.top, PopupLayout.padding)
        .padding(.horizontal, 5)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if state.list.results.isEmpty {
                        Text(state.list.items.isEmpty ? emptyText : "No matches")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: PopupLayout.rowHeight, alignment: .leading)
                            .padding(.leading, 10)
                    }
                    ForEach(Array(state.list.results.enumerated()), id: \.element.id) { row, item in
                        if row == state.list.firstSnippetIndex {
                            Text("Snippets")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: PopupLayout.sectionHeight, alignment: .bottomLeading)
                                .padding(.leading, 10)
                        }
                        PopupRow(state: state, item: item, row: row)
                    }
                }
                .padding(.vertical, PopupLayout.separatorPadding)
            }
            .scrollIndicators(.automatic)
            .onChange(of: state.list.selected?.id) { _, id in
                if let id, state.keyboardNavigating { proxy.scrollTo(id) }
            }
        }
        .frame(height: PopupLayout.listHeight(state.list))
    }

    private var emptyText: String {
        switch state.list.mode {
        case .snippets: "No snippets"
        case .history: "No history yet"
        case .all: "No history or snippets yet"
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.horizontal, PopupLayout.separatorPadding)
                .padding(.bottom, PopupLayout.separatorPadding)
            FooterRow(title: "Clear History…", shortcut: "⌥⌘⌫", action: state.actions.clearHistory)
            FooterRow(title: "Edit Snippets…", shortcut: nil, action: state.actions.editSnippets)
            FooterRow(title: "Settings…", shortcut: "⌘,", action: state.actions.settings)
            FooterRow(title: "Quit Dclip", shortcut: "⌘Q", action: state.actions.quit)
        }
        .padding(.bottom, PopupLayout.padding)
    }
}

private struct PopupRow: View {
    @ObservedObject var state: PopupState
    let item: PopupItem
    let row: Int

    private var isSelected: Bool { state.list.selection == row }

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 10)
            content.padding(.trailing, 5)
            Spacer(minLength: 0)
            if let key = PopupList.shortcutKey(forRow: row) {
                ShortcutLabel(modifiers: "⌘", key: key).padding(.trailing, 10)
            }
        }
        .frame(height: PopupLayout.rowHeight(item))
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(isSelected ? Color.white : .primary)
        .background(isSelected ? Color.accentColor.opacity(0.8) : .white.opacity(0.001),
                    in: RoundedRectangle(cornerRadius: PopupLayout.cornerRadius, style: .continuous))
        .contentShape(Rectangle())
        .id(item.id)
        .onHover { inside in
            if inside, !state.keyboardNavigating { state.list.select(id: item.id) }
        }
        .onTapGesture { state.actions.pick(item) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.title))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder private var content: some View {
        if case .clip(let e) = item.source, e.kind == .image, let img = state.thumbnail(e) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 64, maxHeight: PopupLayout.imageRowHeight - 8, alignment: .leading)
        } else {
            HStack(spacing: 5) {
                if case .clip(let e) = item.source, e.kind == .file {
                    Image(nsImage: NSWorkspace.shared.icon(for: .item)).resizable().frame(width: 15, height: 15)
                }
                Text(highlighted).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    /// The title with the search words in bold, as in Maccy.
    private var highlighted: AttributedString {
        let title = item.title
        var out = AttributedString(title)
        for r in PopupSearch.ranges(of: state.list.query, in: title) {
            guard let lo = AttributedString.Index(r.lowerBound, within: out),
                  let hi = AttributedString.Index(r.upperBound, within: out) else { continue }
            out[lo..<hi].font = .body.bold()
        }
        return out
    }
}

private struct FooterRow: View {
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Text(title).padding(.leading, 10)
            Spacer()
            if let shortcut {
                ShortcutLabel(modifiers: String(shortcut.dropLast()), key: String(shortcut.suffix(1))).padding(.trailing, 10)
            }
        }
        .frame(height: PopupLayout.rowHeight)
        .foregroundStyle(hovering ? Color.white : .primary)
        .background(hovering ? Color.accentColor.opacity(0.8) : .white.opacity(0.001),
                    in: RoundedRectangle(cornerRadius: PopupLayout.cornerRadius, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(.isButton)
    }
}

/// "⌘ 1" with the key in a fixed-width column, like Maccy's KeyboardShortcutView.
private struct ShortcutLabel: View {
    let modifiers: String
    let key: String

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(modifiers), id: \.self) { Text(String($0)) }
            Text(key).frame(width: 12, alignment: .center)
        }
        .lineLimit(1)
        .opacity(0.7)
        .accessibilityHidden(true)
    }
}

/// Maccy's search field, on an AppKit text field so it takes focus as soon as the panel opens.
private struct SearchFieldView: View {
    @Binding var query: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: PopupLayout.cornerRadius, style: .continuous)
                .fill(Color.secondary)
                .opacity(0.1)
                .frame(height: PopupLayout.searchHeight)
            HStack {
                Image(systemName: "magnifyingglass")
                    .frame(width: 11, height: 11)
                    .padding(.leading, 5)
                    .opacity(0.8)
                    .accessibilityHidden(true)
                SearchTextField(text: $query)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .frame(width: 11, height: 11)
                            .padding(.trailing, 5)
                    }
                    .buttonStyle(.plain)
                    .opacity(0.9)
                    .accessibilityLabel(Text("Clear search"))
                }
            }
        }
    }
}

private struct SearchTextField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Type to search…"
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.isAutomaticTextCompletionEnabled = false
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search")
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSTextField { text.wrappedValue = field.stringValue }
        }
    }
}

final class FocusingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}

private struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

@available(macOS 26.0, *)
private struct GlassEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let v = NSGlassEffectView()
        v.style = .regular
        return v
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {}
}
