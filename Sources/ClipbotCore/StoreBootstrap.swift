import CryptoKit
import Foundation

/// Opens the key for one encrypted store and loads its existing data, applying the recovery rules
/// in exactly one place:
/// - key unwraps → load; data that won't decrypt/decode is quarantined (never deleted);
/// - key exists but can't be unwrapped → it is retired (renamed, kept), data quarantined, new key;
/// - no key → any existing data quarantined, new key;
/// - Keychain unavailable (locked, denied) → throws; nothing is touched.
enum StoreBootstrap {
    struct Opened<Value> {
        let sealer: Sealer
        let value: Value?
        /// Existing data couldn't be read and was moved to `Unreadable-<date>/`.
        let recovered: Bool
    }

    static func open<Value>(keys: KeyProviding, account: String, directory: URL, files: [String],
                            hasData: Bool, load: (Sealer) throws -> Value) throws -> Opened<Value> {
        let existing: SymmetricKey?
        do {
            existing = try keys.existingKey(account)
        } catch is KeyUnusableError {
            try keys.retireKey(account)
            existing = nil
        }
        if let key = existing {
            let sealer = Sealer(key: key)
            guard hasData else { return Opened(sealer: sealer, value: nil, recovered: false) }
            do {
                return Opened(sealer: sealer, value: try load(sealer), recovered: false)
            } catch {
                try SecureFiles.quarantine(files, in: directory)
                return Opened(sealer: sealer, value: nil, recovered: true)
            }
        }
        if hasData { try SecureFiles.quarantine(files, in: directory) }
        return Opened(sealer: Sealer(key: try keys.createKey(account)), value: nil, recovered: hasData)
    }
}
