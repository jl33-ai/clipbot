import CryptoKit
import Foundation
import Security

public protocol KeyProviding: AnyObject, Sendable {
    /// nil when no key exists; throws `KeyUnusableError` when the item exists but can't be unwrapped,
    /// and `KeychainError` when the Keychain can't be read right now (locked, denied).
    func existingKey(_ account: String) throws -> SymmetricKey?
    /// Creates a fresh random 256-bit key, replacing any existing one.
    func createKey(_ account: String) throws -> SymmetricKey
    func deleteKey(_ account: String) throws
}

/// The Keychain item exists but can't be turned into a key (moved from another Mac, Secure Enclave
/// reset, damaged). Stores treat this like a missing key: quarantine and start fresh.
public struct KeyUnusableError: Error {
    public init() {}
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
    }
}

/// Keys live in the login Keychain, Secure Enclave–bound, never synchronised; item ACL defaults to this app.
public final class KeychainKeyStore: KeyProviding, @unchecked Sendable {
    public static let appService = "io.linus.clipbot"
    private let service: String
    private let useSecureEnclave: Bool

    public init(service: String = KeychainKeyStore.appService, useSecureEnclave: Bool = SecureEnclave.isAvailable) {
        self.service = service
        self.useSecureEnclave = useSecureEnclave
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    public func existingKey(_ account: String) throws -> SymmetricKey? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        do {
            return try Self.unwrap(data, account: account)
        } catch {
            throw KeyUnusableError()
        }
    }

    public func createKey(_ account: String) throws -> SymmetricKey {
        try deleteKey(account)
        let (stored, key) = try Self.makeWrappedKey(account: account, secureEnclave: useSecureEnclave)
        var q = base(account)
        q[kSecValueData as String] = stored
        q[kSecAttrLabel as String] = "Clipbot encryption key (\(account))"
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return key
    }

    // MARK: Secure Enclave wrapping
    //
    // The legacy login Keychain ignores the …ThisDeviceOnly accessibility class, and the login
    // keychain migrates to new Macs. So the key is never stored: the item holds a Secure Enclave
    // P-256 key blob (only usable by this Mac's Secure Enclave) plus a peer public key, and the
    // symmetric key is HKDF(ECDH(se, peer)). Format: 0x01 ‖ peerPublic(x963, 65 bytes) ‖ seBlob.
    // Fallback without a Secure Enclave: 0x00 ‖ raw 32-byte key.

    private static func makeWrappedKey(account: String, secureEnclave: Bool) throws -> (Data, SymmetricKey) {
        guard secureEnclave else {
            let k = SymmetricKey(size: .bits256)
            return (Data([0]) + k.withUnsafeBytes { Data($0) }, k)
        }
        let se = try SecureEnclave.P256.KeyAgreement.PrivateKey()
        let peer = P256.KeyAgreement.PrivateKey()
        let stored = Data([1]) + peer.publicKey.x963Representation + se.dataRepresentation
        return (stored, try derive(se: se, peer: peer.publicKey, account: account))
    }

    private static func unwrap(_ data: Data, account: String) throws -> SymmetricKey {
        let bytes = Data(data)
        switch bytes.first {
        case 0 where bytes.count == 33:
            return SymmetricKey(data: bytes.dropFirst())
        case 1 where bytes.count > 66:
            let peer = try P256.KeyAgreement.PublicKey(x963Representation: bytes[1..<66])
            let se = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: bytes[66...])
            return try derive(se: se, peer: peer, account: account)
        default:
            throw CocoaError(.coderReadCorrupt)
        }
    }

    private static func derive(se: SecureEnclave.P256.KeyAgreement.PrivateKey,
                               peer: P256.KeyAgreement.PublicKey, account: String) throws -> SymmetricKey {
        try se.sharedSecretFromKeyAgreement(with: peer)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("io.linus.clipbot".utf8),
                                     sharedInfo: Data(account.utf8), outputByteCount: 32)
    }

    public func deleteKey(_ account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// For tests only.
public final class InMemoryKeyStore: KeyProviding, @unchecked Sendable {
    private var keys: [String: SymmetricKey] = [:]
    private let lock = NSLock()
    public init() {}
    public func existingKey(_ account: String) throws -> SymmetricKey? { lock.withLock { keys[account] } }
    public func createKey(_ account: String) throws -> SymmetricKey {
        let k = SymmetricKey(size: .bits256)
        lock.withLock { keys[account] = k }
        return k
    }
    public func deleteKey(_ account: String) throws { _ = lock.withLock { keys.removeValue(forKey: account) } }
}
