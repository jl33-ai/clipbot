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

        if let key = try keys.existingKey(Self.keyAccount) {
            sealer = Sealer(key: key)
            if exists {
                do {
                    loaded = try JSONDecoder().decode([SnippetFolder].self, from: sealer.open(Data(contentsOf: fileURL)))
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
    }

    private func save() {
        guard !loading else { return }
        do {
            try SecureFiles.writeAtomically(try sealer.seal(JSONEncoder().encode(folders)), to: fileURL)
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
    }
}
