import AppKit
import ClipbotCore
import SwiftUI
import UniformTypeIdentifiers

/// Clipy-style snippet editor: folders | snippets | editor.
struct SnippetEditorView: View {
    @ObservedObject var store: SnippetStore
    @State private var folderID: UUID?
    @State private var snippetID: UUID?
    @State private var message: String?

    private var folderIndex: Int? { store.folders.firstIndex { $0.id == folderID } }
    private var snippetIndex: Int? {
        guard let f = folderIndex else { return nil }
        return store.folders[f].snippets.firstIndex { $0.id == snippetID }
    }

    var body: some View {
        HSplitView {
            column(title: "Folders", add: addFolder, remove: removeFolder, canRemove: folderIndex != nil) {
                List(selection: $folderID) {
                    ForEach($store.folders) { $f in
                        HStack {
                            Toggle("", isOn: $f.enabled).labelsHidden().help("Show in menu")
                            TextField("Folder", text: $f.title)
                        }.tag(f.id)
                    }
                    .onMove { store.folders.move(fromOffsets: $0, toOffset: $1) }
                }
            }
            .frame(minWidth: 200, idealWidth: 220)

            column(title: "Snippets", add: addSnippet, remove: removeSnippet,
                   canAdd: folderIndex != nil, canRemove: snippetIndex != nil) {
                if let f = folderIndex {
                    List(selection: $snippetID) {
                        ForEach($store.folders[f].snippets) { $s in
                            HStack {
                                Toggle("", isOn: $s.enabled).labelsHidden().help("Show in menu")
                                Text(s.title.isEmpty ? "Untitled" : s.title)
                            }.tag(s.id)
                        }
                        .onMove { store.folders[f].snippets.move(fromOffsets: $0, toOffset: $1) }
                    }
                } else {
                    placeholder("Select a folder")
                }
            }
            .frame(minWidth: 200, idealWidth: 220)

            Group {
                if let f = folderIndex, let s = snippetIndex {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Title", text: $store.folders[f].snippets[s].title)
                            .textFieldStyle(.roundedBorder)
                        TextEditor(text: $store.folders[f].snippets[s].content)
                            .font(.body.monospaced())
                            .border(Color(nsColor: .separatorColor))
                    }
                    .padding(10)
                } else {
                    placeholder("Select a snippet")
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Import from Clipy XML…", action: importXML)
                Button("Export Snippets…", action: exportXML)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let m = message ?? store.lastSaveError {
                Text(m).font(.callout).foregroundStyle(.secondary).padding(6).frame(maxWidth: .infinity)
            }
        }
        .onChange(of: folderID) { _, _ in snippetID = nil }
    }

    private func column<Content: View>(title: String, add: @escaping () -> Void, remove: @escaping () -> Void,
                                       canAdd: Bool = true, canRemove: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            content().frame(maxHeight: .infinity)
            HStack {
                Button(action: add) { Image(systemName: "plus") }.disabled(!canAdd)
                Button(action: remove) { Image(systemName: "minus") }.disabled(!canRemove)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    private func placeholder(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addFolder() {
        let f = SnippetFolder(title: "New Folder")
        store.folders.append(f)
        folderID = f.id
    }

    private func removeFolder() {
        guard let i = folderIndex else { return }
        guard confirm("Delete folder \"\(store.folders[i].title)\" and its \(store.folders[i].snippets.count) snippets?") else { return }
        store.folders.remove(at: i)
        folderID = nil
    }

    private func addSnippet() {
        guard let f = folderIndex else { return }
        let s = Snippet(title: "New Snippet", content: "")
        store.folders[f].snippets.append(s)
        snippetID = s.id
    }

    private func removeSnippet() {
        guard let f = folderIndex, let s = snippetIndex else { return }
        guard confirm("Delete snippet \"\(store.folders[f].snippets[s].title)\"?") else { return }
        store.folders[f].snippets.remove(at: s)
        snippetID = nil
    }

    private func confirm(_ text: String) -> Bool {
        let a = NSAlert()
        a.messageText = text
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        return a.runModal() == .alertFirstButtonReturn
    }

    private func importXML() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let folders = try ClipyXML.parse(Data(contentsOf: url))
            store.folders.append(contentsOf: folders)
            message = "Imported \(folders.count) folders, \(folders.reduce(0) { $0 + $1.snippets.count }) snippets."
        } catch {
            message = "That file isn't a Clipy snippets export."
        }
    }

    private func exportXML() {
        let a = NSAlert()
        a.messageText = "Export snippets as an unencrypted file?"
        a.informativeText = "The exported file is plain text, so anyone who can read it can see your snippets. Clipboard history is never exported."
        a.addButton(withTitle: "Export…")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Clipbot Snippets.xml"
        panel.allowedContentTypes = [.xml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ClipyXML.export(store.folders).write(to: url, options: .atomic)
            message = "Exported to \(url.lastPathComponent)."
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }
}
