import AppKit
import ClipbotCore
import SwiftUI
import UniformTypeIdentifiers

/// Clipy-style snippet editor: folders | snippets | editor.
/// All bindings look items up by id (never by array index), so deletes, reorders and imports
/// can't crash a live field or write into the wrong snippet.
struct SnippetEditorView: View {
    @ObservedObject var store: SnippetStore
    @State private var folderID: UUID?
    @State private var snippetID: UUID?
    @State private var message: String?

    private var folder: SnippetFolder? { store.folders.first { $0.id == folderID } }
    private var snippet: Snippet? { folder?.snippets.first { $0.id == snippetID } }

    var body: some View {
        HSplitView {
            column(title: "Folders", add: addFolder, remove: removeFolder, canRemove: folder != nil) {
                List(selection: $folderID) {
                    ForEach(store.folders) { f in
                        HStack {
                            Toggle("", isOn: folderField(f.id, \.enabled, true)).labelsHidden().help("Show in menu")
                            TextField("Folder", text: folderField(f.id, \.title, ""))
                        }.tag(f.id)
                    }
                    .onMove { store.folders.move(fromOffsets: $0, toOffset: $1) }
                }
            }
            .frame(minWidth: 200, idealWidth: 220)

            column(title: "Snippets", add: addSnippet, remove: removeSnippet,
                   canAdd: folder != nil, canRemove: snippet != nil) {
                if let f = folder {
                    List(selection: $snippetID) {
                        ForEach(f.snippets) { s in
                            HStack {
                                Toggle("", isOn: snippetField(f.id, s.id, \.enabled, true)).labelsHidden().help("Show in menu")
                                Text(s.title.isEmpty ? "Untitled" : s.title)
                            }.tag(s.id)
                        }
                        .onMove { from, to in update(folder: f.id) { $0.snippets.move(fromOffsets: from, toOffset: to) } }
                    }
                } else {
                    placeholder("Select a folder")
                }
            }
            .frame(minWidth: 200, idealWidth: 220)

            Group {
                if let f = folder, let s = snippet {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Title", text: snippetField(f.id, s.id, \.title, ""))
                            .textFieldStyle(.roundedBorder)
                        TextEditor(text: snippetField(f.id, s.id, \.content, ""))
                            .font(.body.monospaced())
                            .border(Color(nsColor: .separatorColor))
                    }
                    .padding(10)
                    .id(s.id)
                } else {
                    placeholder("Select a snippet")
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        // Keep snippet text on this Mac: no Writing Tools (can use Private Cloud Compute), no autocorrect.
        .writingToolsBehavior(.disabled)
        .autocorrectionDisabled()
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

    // MARK: Id-based bindings

    private func update(folder id: UUID, _ change: (inout SnippetFolder) -> Void) {
        guard let i = store.folders.firstIndex(where: { $0.id == id }) else { return }
        change(&store.folders[i])
    }

    private func folderField<T>(_ id: UUID, _ kp: WritableKeyPath<SnippetFolder, T>, _ fallback: T) -> Binding<T> {
        Binding(
            get: { store.folders.first { $0.id == id }?[keyPath: kp] ?? fallback },
            set: { v in update(folder: id) { $0[keyPath: kp] = v } })
    }

    private func snippetField<T>(_ fid: UUID, _ sid: UUID, _ kp: WritableKeyPath<Snippet, T>, _ fallback: T) -> Binding<T> {
        Binding(
            get: { store.folders.first { $0.id == fid }?.snippets.first { $0.id == sid }?[keyPath: kp] ?? fallback },
            set: { v in
                update(folder: fid) { f in
                    guard let j = f.snippets.firstIndex(where: { $0.id == sid }) else { return }
                    f.snippets[j][keyPath: kp] = v
                }
            })
    }

    // MARK: Layout helpers

    private func column<Content: View>(title: String, add: @escaping () -> Void, remove: @escaping () -> Void,
                                       canAdd: Bool = true, canRemove: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            content().frame(maxHeight: .infinity)
            HStack {
                Button(action: add) { Image(systemName: "plus") }.disabled(!canAdd).accessibilityLabel("Add")
                Button(action: remove) { Image(systemName: "minus") }.disabled(!canRemove).accessibilityLabel("Remove")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    private func placeholder(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func addFolder() {
        let f = SnippetFolder(title: "New Folder")
        store.folders.append(f)
        folderID = f.id
    }

    private func removeFolder() {
        guard let f = folder else { return }
        guard confirm("Delete folder \"\(f.title)\" and its \(f.snippets.count) snippets?") else { return }
        folderID = nil
        store.folders.removeAll { $0.id == f.id }
    }

    private func addSnippet() {
        guard let f = folder else { return }
        let s = Snippet(title: "New Snippet", content: "")
        update(folder: f.id) { $0.snippets.append(s) }
        snippetID = s.id
    }

    private func removeSnippet() {
        guard let f = folder, let s = snippet else { return }
        guard confirm("Delete snippet \"\(s.title)\"?") else { return }
        snippetID = nil
        update(folder: f.id) { $0.snippets.removeAll { $0.id == s.id } }
    }

    private func confirm(_ text: String) -> Bool {
        Alert.run(text, buttons: ["Delete", "Cancel"], destructive: true)
    }

    private func importXML() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attrs[.size] as? Int ?? 0) < 10 * 1024 * 1024 else { message = "That file is too large to be a snippets export."; return }
            let folders = try ClipyXML.parse(Data(contentsOf: url))
            store.folders.append(contentsOf: folders)
            message = "Imported \(folders.count) folders, \(folders.reduce(0) { $0 + $1.snippets.count }) snippets."
        } catch {
            message = "That file isn't a Clipy snippets export."
        }
    }

    private func exportXML() {
        guard Alert.run("Export snippets as an unencrypted file?",
                        "The exported file is plain text, so anyone who can read it can see your snippets. Don't save it in a folder that syncs to iCloud or another cloud service. Clipboard history is never exported.",
                        buttons: ["Export…", "Cancel"]) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Dclip Snippets.xml"
        // Downloads isn't synced by iCloud Desktop & Documents.
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.xml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let fm = FileManager.default
        // Owner-only from the moment it exists (and fixed up if overwriting an existing file).
        if fm.createFile(atPath: url.path, contents: ClipyXML.export(store.folders), attributes: [.posixPermissions: 0o600]) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            message = "Exported to \(url.lastPathComponent) (readable only by you)."
        } else {
            message = "Export failed."
        }
    }
}
