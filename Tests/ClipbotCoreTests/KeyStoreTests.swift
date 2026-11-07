import XCTest
import CryptoKit
@testable import ClipbotCore

final class KeyStoreTests: XCTestCase {
    let service = "io.linus.clipbot.tests"
    let account = "test-key-\(UUID().uuidString)"
    lazy var store = KeychainKeyStore(service: service)

    override func tearDown() { try? store.deleteKey(account) }

    func testKeychainCreateReadDelete() throws {
        XCTAssertNil(try store.existingKey(account))
        let created = try store.createKey(account)
        let read = try XCTUnwrap(try store.existingKey(account))
        XCTAssertEqual(created.withUnsafeBytes { Data($0) }, read.withUnsafeBytes { Data($0) })
        XCTAssertEqual(read.bitCount, 256)
        try store.deleteKey(account)
        XCTAssertNil(try store.existingKey(account))
    }

    func testCreateReplacesExistingKey() throws {
        let first = try store.createKey(account)
        let second = try store.createKey(account)
        let read = try XCTUnwrap(try store.existingKey(account))
        XCTAssertNotEqual(first.withUnsafeBytes { Data($0) }, second.withUnsafeBytes { Data($0) })
        XCTAssertEqual(second.withUnsafeBytes { Data($0) }, read.withUnsafeBytes { Data($0) })
    }

    /// The legacy login Keychain ignores kSecAttrAccessible…ThisDeviceOnly, so the raw key must never be
    /// stored: the item holds only a Secure Enclave–bound blob that can't be used on any other Mac.
    func testStoredItemIsSecureEnclaveWrappedNotRawKey() throws {
        try XCTSkipUnless(SecureEnclave.isAvailable)
        let key = try store.createKey(account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecReturnAttributes as String: true]
        var out: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(q as CFDictionary, &out), errSecSuccess)
        let attrs = try XCTUnwrap(out as? [String: Any])
        let stored = try XCTUnwrap(attrs[kSecValueData as String] as? Data)
        XCTAssertEqual(stored.first, 1, "format byte 1 = Secure Enclave wrapped")
        XCTAssertNil(stored.range(of: key.withUnsafeBytes { Data($0) }), "raw key bytes must not be stored")
        XCTAssertNotEqual(attrs[kSecAttrSynchronizable as String] as? Bool, true)
    }

    func testInMemoryStore() throws {
        let mem = InMemoryKeyStore()
        XCTAssertNil(try mem.existingKey("a"))
        let k = try mem.createKey("a")
        XCTAssertEqual(try mem.existingKey("a").map { $0.withUnsafeBytes { Data($0) } }, k.withUnsafeBytes { Data($0) })
        try mem.deleteKey("a")
        XCTAssertNil(try mem.existingKey("a"))
    }
}
