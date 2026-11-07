import Combine
import Foundation

/// Encrypted snippets (`snippets.bin`, own key so Clear History never touches them).
/// Every change to `folders` is saved immediately.
@MainActor
public final class SnippetStore: ObservableObject {
    public static let keyAccount = "snippet-key"
    private static let fileName = "snippets.bin"
    private static let context = "io.linus.clipbot/snippets/v1"

    @Published public var folders: [SnippetFolder] {
        didSet { save() }
    }
    /// Existing snippets couldn't be decrypted and were moved to `Unreadable-<date>/`.
    public let recoveredFromMissingKey: Bool
    /// Set when the last save failed; the editor surfaces it.
    @Published public private(set) var lastSaveError: String?

    private let fileURL: URL
    private let sealer: Sealer

    public init(directory: URL, keys: KeyProviding) throws {
        try SecureFiles.ensureDirectory(directory)
        let fileURL = directory.appendingPathComponent(Self.fileName)
        let opened = try StoreBootstrap.open(keys: keys, account: Self.keyAccount, directory: directory, files: [Self.fileName],
                                             hasData: FileManager.default.fileExists(atPath: fileURL.path)) { sealer in
            try JSONDecoder().decode([SnippetFolder].self, from: sealer.open(Data(contentsOf: fileURL), context: Self.context))
        }
        self.fileURL = fileURL
        sealer = opened.sealer
        recoveredFromMissingKey = opened.recovered
        folders = opened.value ?? [] // initial value: didSet doesn't fire during init
    }

    private func save() {
        do {
            try SecureFiles.writeAtomically(try sealer.seal(JSONEncoder().encode(folders), context: Self.context), to: fileURL)
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
    }
}
