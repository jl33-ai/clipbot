import AppKit
import CryptoKit
import XCTest
@testable import ClipbotCore

func makeTempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("clipbot-tests-\(UUID().uuidString)")
}

func textPayload(_ s: String) -> ClipPayload {
    ClipPayload(representations: [ClipRepresentation(type: "public.utf8-plain-text", data: Data(s.utf8))])
}

/// Every byte of every file under `dir`, for "no plaintext on disk" checks.
func allFileBytes(under dir: URL) -> [(URL, Data)] {
    let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])!
    return e.compactMap { item in
        guard let u = item as? URL, (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return (u, (try? Data(contentsOf: u)) ?? Data())
    }
}

final class InMemoryKeyStore: KeyProviding, @unchecked Sendable {
    private var keys: [String: SymmetricKey] = [:]
    private let lock = NSLock()
    init() {}
    func existingKey(_ account: String) throws -> SymmetricKey? { lock.withLock { keys[account] } }
    func createKey(_ account: String) throws -> SymmetricKey {
        let k = SymmetricKey(size: .bits256)
        lock.withLock { keys[account] = k }
        return k
    }
    func deleteKey(_ account: String) throws { _ = lock.withLock { keys.removeValue(forKey: account) } }
    func retireKey(_ account: String) throws {
        lock.withLock { if let k = keys.removeValue(forKey: account) { keys["\(account).unreadable"] = k } }
    }
}

/// A test case with a fresh temp directory per test.
class TempDirTestCase: XCTestCase {
    var dir: URL!
    override func setUp() { super.setUp(); dir = makeTempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }
}

/// A test case with a private, empty pasteboard per test.
class PasteboardTestCase: XCTestCase {
    var pb: NSPasteboard!
    override func setUp() { super.setUp(); pb = NSPasteboard(name: .init("clipbot-test-\(UUID().uuidString)")); pb.clearContents() }
    override func tearDown() { pb.releaseGlobally(); super.tearDown() }
    /// The production capture path on this test pasteboard.
    func capture() -> CapturedClip? { ClipCapture.capture(items: pb.pasteboardItems ?? []) }
}

func rtfData(_ s: String) throws -> Data {
    try NSAttributedString(string: s).data(from: NSRange(location: 0, length: s.utf16.count),
                                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
}
