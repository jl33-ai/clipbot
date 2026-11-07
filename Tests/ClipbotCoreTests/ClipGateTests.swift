import AppKit
import CryptoKit
import XCTest
@testable import ClipbotCore

/// The whole record-or-drop decision for one pasteboard change.
final class ClipGateTests: XCTestCase {
    var pb: NSPasteboard!
    let filter = SecretFilter(ignoredBundleIDs: SecretFilter.defaultIgnoredBundleIDs)
    override func setUp() { pb = NSPasteboard(name: .init("clipbot-test-\(UUID().uuidString)")); pb.clearContents() }
    override func tearDown() { pb.releaseGlobally() }

    func gate(sources: Set<String> = ["com.apple.TextEdit"]) -> ClipGate.Result {
        ClipGate.evaluate(items: pb.pasteboardItems ?? [], sourceBundleIDs: sources, filter: filter)
    }

    func testPlainCopyIsRecorded() {
        pb.setString("hello", forType: .string)
        guard case .record(let c) = gate() else { return XCTFail() }
        XCTAssertEqual(c.preview, "hello")
    }

    func testMarkerOnAnyItemDropsWholeChange() {
        let a = NSPasteboardItem(); a.setString("visible", forType: .string)
        let b = NSPasteboardItem(); b.setString("hunter2", forType: .string)
        b.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        pb.writeObjects([a, b])
        XCTAssertEqual(gate(), .dropped(.marker))
    }

    func testAnyIgnoredSourceSinceLastChangeDrops() {
        pb.setString("from keychain", forType: .string)
        // User copied in Keychain Access, then ⌘-Tabbed to TextEdit before the poll ran.
        XCTAssertEqual(gate(sources: ["com.apple.keychainaccess", "com.apple.TextEdit"]), .dropped(.ignoredApp))
    }

    func testSecretInRTFOnlyClipIsDropped() throws {
        let key = "sk-" + String(repeating: "aB3", count: 14)
        let rtf = try NSAttributedString(string: key).data(from: NSRange(location: 0, length: key.utf16.count),
                                                          documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        pb.setData(rtf, forType: .rtf)
        XCTAssertEqual(gate(), .dropped(.secretPattern))
    }

    func testSecretPlainTextAndURLDropped() {
        pb.setString("ghp_" + String(repeating: "a1", count: 18), forType: .string)
        XCTAssertEqual(gate(), .dropped(.secretPattern))
    }

    func testEmptyIsSkipped() {
        pb.setString("  ", forType: .string)
        XCTAssertEqual(gate(), .skipped)
    }
}

/// A Keychain item that exists but can't be unwrapped (new Mac, reset Secure Enclave).
final class UnusableKeyStore: KeyProviding, @unchecked Sendable {
    let inner = InMemoryKeyStore()
    var unusable: Set<String> = []
    func existingKey(_ a: String) throws -> SymmetricKey? {
        if unusable.contains(a) { throw KeyUnusableError() }
        return try inner.existingKey(a)
    }
    func createKey(_ a: String) throws -> SymmetricKey { unusable.remove(a); return try inner.createKey(a) }
    func deleteKey(_ a: String) throws { unusable.remove(a); try inner.deleteKey(a) }
}

/// Keychain locked / access denied: must NOT quarantine (data is fine, key is just unavailable now).
final class LockedKeyStore: KeyProviding, @unchecked Sendable {
    func existingKey(_ a: String) throws -> SymmetricKey? { throw KeychainError(status: errSecInteractionNotAllowed) }
    func createKey(_ a: String) throws -> SymmetricKey { throw KeychainError(status: errSecInteractionNotAllowed) }
    func deleteKey(_ a: String) throws {}
}

final class KeyRecoveryTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = makeTempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testUnwrappableHistoryKeyQuarantinesAndRecovers() throws {
        let keys = UnusableKeyStore()
        try HistoryStore(directory: dir, keys: keys).add(textPayload("x"), kind: .text, preview: "x", thumbnail: nil)
        keys.unusable = [HistoryStore.keyAccount]
        let h = try HistoryStore(directory: dir, keys: keys)
        XCTAssertTrue(h.recoveredFromMissingKey)
        XCTAssertTrue(h.entries.isEmpty)
        try h.add(textPayload("y"), kind: .text, preview: "y", thumbnail: nil)
        XCTAssertEqual(try HistoryStore(directory: dir, keys: keys).entries.map(\.preview), ["y"])
    }

    @MainActor
    func testUnwrappableSnippetKeyQuarantinesAndRecovers() throws {
        let keys = UnusableKeyStore()
        try SnippetStore(directory: dir, keys: keys).folders = [SnippetFolder(title: "f")]
        keys.unusable = [SnippetStore.keyAccount]
        let s = try SnippetStore(directory: dir, keys: keys)
        XCTAssertTrue(s.recoveredFromMissingKey)
        XCTAssertTrue(s.folders.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("Unreadable-") })
    }

    func testLockedKeychainThrowsWithoutQuarantining() throws {
        let keys = InMemoryKeyStore()
        try HistoryStore(directory: dir, keys: keys).add(textPayload("x"), kind: .text, preview: "x", thumbnail: nil)
        XCTAssertThrowsError(try HistoryStore(directory: dir, keys: LockedKeyStore()))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("Unreadable-") })
        XCTAssertEqual(try HistoryStore(directory: dir, keys: keys).entries.count, 1, "data intact once keychain unlocks")
    }

    func testKeychainStoreReportsCorruptItemAsUnusable() throws {
        let service = "io.linus.clipbot.tests", account = "corrupt-\(UUID().uuidString)"
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data([1, 2, 3])]
        XCTAssertEqual(SecItemAdd(q as CFDictionary, nil), errSecSuccess)
        defer { SecItemDelete(q as CFDictionary) }
        XCTAssertThrowsError(try KeychainKeyStore(service: service).existingKey(account)) { XCTAssertTrue($0 is KeyUnusableError) }
    }
}

final class HardeningTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = makeTempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testSwappedClipFilesDoNotDecryptAsEachOther() throws {
        let keys = InMemoryKeyStore()
        let s = try HistoryStore(directory: dir, keys: keys)
        try s.add(textPayload("A"), kind: .text, preview: "A", thumbnail: nil)
        try s.add(textPayload("B"), kind: .text, preview: "B", thumbnail: nil)
        let (b, a) = (s.entries[0].id, s.entries[1].id)
        let clips = dir.appendingPathComponent("clips")
        try FileManager.default.removeItem(at: clips.appendingPathComponent("\(a.uuidString).bin"))
        try FileManager.default.copyItem(at: clips.appendingPathComponent("\(b.uuidString).bin"), to: clips.appendingPathComponent("\(a.uuidString).bin"))
        let r = try HistoryStore(directory: dir, keys: keys)
        XCTAssertThrowsError(try r.payload(for: a), "file bound to its id via AAD")
    }

    func testOrphanClipFilesAreSweptOnOpen() throws {
        let keys = InMemoryKeyStore()
        _ = try HistoryStore(directory: dir, keys: keys)
        let orphan = dir.appendingPathComponent("clips/\(UUID().uuidString).bin")
        try Data(repeating: 7, count: 64).write(to: orphan)
        _ = try HistoryStore(directory: dir, keys: keys)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    @MainActor
    func testLegacySnippetFileWithoutAADIsMigrated() throws {
        let keys = InMemoryKeyStore()
        let key = try keys.createKey(SnippetStore.keyAccount)
        try SecureFiles.ensureDirectory(dir)
        let legacy = try Sealer(key: key).seal(JSONEncoder().encode([SnippetFolder(title: "old")]))
        try legacy.write(to: dir.appendingPathComponent("snippets.bin"))
        XCTAssertEqual(try SnippetStore(directory: dir, keys: keys).folders.map(\.title), ["old"])
        let migrated = try Data(contentsOf: dir.appendingPathComponent("snippets.bin"))
        XCTAssertThrowsError(try Sealer(key: key).open(migrated), "re-saved with AAD")
    }

    func testPreviewStripsBidiAndControlCharacters() {
        XCTAssertEqual(MenuModel.previewText("abc\u{202E}gpj.exe"), "abcgpj.exe")
        XCTAssertEqual(MenuModel.previewText("a\u{0000}b\u{200B}c\u{2066}d"), "abcd")
        XCTAssertEqual(MenuModel.previewText("👨‍👩‍👧 family"), "👨‍👩‍👧 family", "ZWJ inside emoji sequences is kept")
    }

    func testPreviewOfHugeTextIsCheap() {
        let huge = String(repeating: "word ", count: 2_000_000)
        let t0 = Date()
        XCTAssertEqual(MenuModel.previewText(huge).count, 61)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.05)
    }

    func testReservedShortcutsRejected() {
        for key in [9, 8, 7, 6, 0, 12, 13, 48, 49] { // V C X Z A Q W Tab Space with ⌘
            XCTAssertFalse(Shortcut(keyCode: UInt16(key), modifierFlags: [.command]).isValid, "⌘ + key \(key)")
        }
        XCTAssertTrue(Shortcut.mainDefault.isValid)
        XCTAssertTrue(Shortcut(keyCode: 9, modifierFlags: [.command, .option]).isValid)
    }

    func testExportDropsXMLIllegalCharactersAndReimports() throws {
        let f = [SnippetFolder(title: "t\u{0001}", snippets: [Snippet(title: "s", content: "a\u{0008}b\tc\n")])]
        let back = try ClipyXML.parse(ClipyXML.export(f))
        XCTAssertEqual(back.first?.title, "t")
        XCTAssertEqual(back.first?.snippets.first?.content, "ab\tc\n")
    }
}
