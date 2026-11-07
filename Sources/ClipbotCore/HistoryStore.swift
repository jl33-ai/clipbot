import CryptoKit
import Foundation

/// Encrypted clipboard history: `index.bin` (sealed JSON of entries, newest first) plus one sealed
/// payload per clip in `clips/<uuid>.bin`. Not thread-safe; use from the main thread.
public final class HistoryStore {
    public static let keyAccount = "clip-key"
    private static let indexName = "index.bin"
    private static let clipsName = "clips"
    /// AES-GCM nonce (12) + tag (16): anything smaller can't be a sealed file.
    private static let minSealedSize = 28

    public private(set) var entries: [ClipEntry] = []
    /// True when existing history couldn't be decrypted (key missing or index corrupt) and was
    /// moved aside into `Unreadable-<date>/`. The app warns once.
    public private(set) var recoveredFromMissingKey = false

    public let capacity: Int
    private let directory: URL
    private let keys: KeyProviding
    private var sealer: Sealer

    private var indexURL: URL { directory.appendingPathComponent(Self.indexName) }
    private var clipsURL: URL { directory.appendingPathComponent(Self.clipsName) }
    private func clipURL(_ id: UUID) -> URL { clipsURL.appendingPathComponent("\(id.uuidString).bin") }

    public init(directory: URL, keys: KeyProviding, capacity: Int = 100) throws {
        self.directory = directory
        self.keys = keys
        self.capacity = capacity
        try SecureFiles.ensureDirectory(directory)

        let fm = FileManager.default
        let hasData = fm.fileExists(atPath: directory.appendingPathComponent(Self.indexName).path)
            || !((try? fm.contentsOfDirectory(atPath: directory.appendingPathComponent(Self.clipsName).path)) ?? []).isEmpty

        if let key = try Self.usableKey(keys, Self.keyAccount) {
            sealer = Sealer(key: key)
            if hasData {
                do {
                    entries = try loadIndex()
                } catch {
                    try Self.quarantine(directory)
                    recoveredFromMissingKey = true
                }
            }
        } else {
            if hasData {
                try Self.quarantine(directory)
                recoveredFromMissingKey = true
            }
            sealer = Sealer(key: try keys.createKey(Self.keyAccount))
        }
        try SecureFiles.ensureDirectory(clipsURL)
        try dropEntriesWithMissingFiles()
        sweepOrphans()
    }

    /// A key that exists but can't be unwrapped counts as missing; Keychain errors still throw.
    static func usableKey(_ keys: KeyProviding, _ account: String) throws -> SymmetricKey? {
        do { return try keys.existingKey(account) } catch is KeyUnusableError { return nil }
    }

    // MARK: Public API

    public func add(_ payload: ClipPayload, kind: ClipKind, preview: String, thumbnail: Data?) throws {
        let tag = sealer.tag(payload.canonicalBytes)
        if let existing = entries.first(where: { $0.tag == tag }) {
            try moveToTop(existing.id)
            return
        }
        let entry = ClipEntry(id: UUID(), lastUsed: Date(), kind: kind, preview: preview, thumbnail: thumbnail, tag: tag)
        try SecureFiles.writeAtomically(try sealer.seal(JSONEncoder().encode(payload), context: Self.clipContext(entry.id)), to: clipURL(entry.id))
        entries.insert(entry, at: 0)
        let evicted = entries.count > capacity ? Array(entries[capacity...]) : []
        entries.removeLast(evicted.count)
        try saveIndex()
        for e in evicted { try? FileManager.default.removeItem(at: clipURL(e.id)) }
    }

    /// Decrypts a clip's payload. A clip that fails authentication is removed from history.
    public func payload(for id: UUID) throws -> ClipPayload {
        do {
            return try JSONDecoder().decode(ClipPayload.self, from: sealer.open(Data(contentsOf: clipURL(id)), context: Self.clipContext(id)))
        } catch {
            try? remove(id)
            throw error
        }
    }

    public func moveToTop(_ id: UUID) throws {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        var e = entries.remove(at: i)
        e.lastUsed = Date()
        entries.insert(e, at: 0)
        try saveIndex()
    }

    /// Deletes every clip and rotates the key, so leftover ciphertext on disk is unreadable.
    public func clear() throws {
        let fm = FileManager.default
        entries = []
        try? fm.removeItem(at: clipsURL)
        try? fm.removeItem(at: indexURL)
        sealer = Sealer(key: try keys.createKey(Self.keyAccount))
        try SecureFiles.ensureDirectory(clipsURL)
        try saveIndex()
    }

    // MARK: Private

    private func remove(_ id: UUID) throws {
        entries.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: clipURL(id))
        try saveIndex()
    }

    private func loadIndex() throws -> [ClipEntry] {
        try JSONDecoder().decode([ClipEntry].self, from: sealer.open(Data(contentsOf: indexURL), context: Self.indexContext))
    }

    private func saveIndex() throws {
        try SecureFiles.writeAtomically(try sealer.seal(JSONEncoder().encode(entries), context: Self.indexContext), to: indexURL)
    }

    private static let indexContext = "io.linus.clipbot/index/v1"
    private static func clipContext(_ id: UUID) -> String { "io.linus.clipbot/clip/v1/\(id.uuidString)" }

    /// Removes clip files (and stray temp files) that no index entry references, e.g. after a crash.
    private func sweepOrphans() {
        let fm = FileManager.default
        let known = Set(entries.map { "\($0.id.uuidString).bin" })
        for dir in [clipsURL, directory] {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let orphanClip = dir == clipsURL && !known.contains(name)
                let strayTemp = name.hasPrefix(".") && name.hasSuffix(".tmp")
                if orphanClip || strayTemp { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
            }
        }
    }

    private func dropEntriesWithMissingFiles() throws {
        let before = entries.count
        entries.removeAll { e in
            let size = (try? FileManager.default.attributesOfItem(atPath: clipURL(e.id).path)[.size] as? Int) ?? 0
            return size < Self.minSealedSize
        }
        if entries.count != before { try saveIndex() }
    }

    private static func quarantine(_ directory: URL) throws {
        try SecureFiles.quarantine([indexName, clipsName], in: directory)
    }
}
