import Combine
import Foundation

/// Encrypted snippets (`snippets.bin`, own key so Clear History never touches them).
/// Every change to `folders` is saved immediately.
@MainActor
public final class SnippetStore: ObservableObject {
    public static let keyAccount = "snippet-key"
    private static let fileName = "snippets.bin"

    @Published public var folders: [SnippetFolder] = [] {
        didSet { save() }
    }
    public private(set) var recoveredFromMissingKey = false
    /// Set when the last save failed; the editor surfaces it.
    @Published public private(set) var lastSaveError: String?

    private let fileURL: URL
    private let sealer: Sealer
    private var loading = true

    public init(directory: URL, keys: KeyProviding) throws {
        try SecureFiles.ensureDirectory(directory)
        fileURL = directory.appendingPathComponent(Self.fileName)
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        var recovered = false
        var loaded: [SnippetFolder] = []

        var needsMigration = false
        if let key = try HistoryStore.usableKey(keys, Self.keyAccount) {
            sealer = Sealer(key: key)
            if exists {
                do {
                    let sealed = try Data(contentsOf: fileURL)
                    if let plain = try? sealer.open(sealed, context: Self.context) {
                        loaded = try JSONDecoder().decode([SnippetFolder].self, from: plain)
                    } else {
                        // Files written before AAD binding (2026-11-07 builds): read once, re-save bound.
                        loaded = try JSONDecoder().decode([SnippetFolder].self, from: sealer.open(sealed))
                        needsMigration = true
                    }
                } catch {
                    try SecureFiles.quarantine([Self.fileName], in: directory)
                    recovered = true
                }
            }
        } else {
            if exists {
                try SecureFiles.quarantine([Self.fileName], in: directory)
                recovered = true
            }
            sealer = Sealer(key: try keys.createKey(Self.keyAccount))
        }
        recoveredFromMissingKey = recovered
        folders = loaded
        loading = false
        if needsMigration { save() }
    }

    private static let context = "io.linus.clipbot/snippets/v1"

    private func save() {
        guard !loading else { return }
        do {
            try SecureFiles.writeAtomically(try sealer.seal(JSONEncoder().encode(folders), context: Self.context), to: fileURL)
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
    }
}
