import CryptoKit
import Foundation

/// AES-256-GCM sealing for every byte Clipbot persists, plus keyed dedupe tags.
public struct Sealer: Sendable {
    private let key: SymmetricKey
    private let tagKey: SymmetricKey

    public init(key: SymmetricKey) {
        self.key = key
        self.tagKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data("dedupe".utf8), outputByteCount: 32)
    }

    /// nonce ‖ ciphertext ‖ tag (CryptoKit combined representation).
    /// `context` is authenticated (AAD), binding the ciphertext to its role/location.
    public func seal(_ data: Data, context: String? = nil) throws -> Data {
        let box = try context.map { try AES.GCM.seal(data, using: key, authenticating: Data($0.utf8)) }
            ?? AES.GCM.seal(data, using: key)
        guard let combined = box.combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return combined
    }

    public func open(_ data: Data, context: String? = nil) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        if let context { return try AES.GCM.open(box, using: key, authenticating: Data(context.utf8)) }
        return try AES.GCM.open(box, using: key)
    }

    /// HMAC-SHA256 under a key derived from the sealing key; never a plain content hash.
    public func tag(_ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: tagKey))
    }
}
