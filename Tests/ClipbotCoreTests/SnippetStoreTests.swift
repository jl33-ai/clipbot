import XCTest
@testable import ClipbotCore

@MainActor
final class SnippetStoreTests: XCTestCase {
    var dir: URL!
    var keys: InMemoryKeyStore!
    override func setUp() async throws { dir = makeTempDir(); keys = InMemoryKeyStore() }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    let folder = SnippetFolder(title: "cal", snippets: [Snippet(title: "15m", content: "https://cal.com/x/15min")])

    func testPersistsAcrossReopen() throws {
        let s = try SnippetStore(directory: dir, keys: keys)
        XCTAssertTrue(s.folders.isEmpty)
        s.folders = [folder]
        XCTAssertEqual(try SnippetStore(directory: dir, keys: keys).folders, [folder])
    }

    func testHistoryClearDoesNotTouchSnippets() throws {
        let s = try SnippetStore(directory: dir, keys: keys)
        s.folders = [folder]
        let h = try HistoryStore(directory: dir, keys: keys)
        try h.add(textPayload("x"), kind: .text, preview: "x", thumbnail: nil)
        try h.clear()
        XCTAssertEqual(try SnippetStore(directory: dir, keys: keys).folders, [folder])
    }

    func testMissingKeyQuarantinesSnippets() throws {
        let s = try SnippetStore(directory: dir, keys: keys)
        s.folders = [folder]
        try keys.deleteKey("snippet-key")
        let r = try SnippetStore(directory: dir, keys: keys)
        XCTAssertTrue(r.folders.isEmpty)
        XCTAssertTrue(r.recoveredFromMissingKey)
        let q = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: dir.path).first { $0.hasPrefix("Unreadable-") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(q)/snippets.bin").path))
    }

    func testNoPlaintextOnDisk() throws {
        let s = try SnippetStore(directory: dir, keys: keys)
        s.folders = [SnippetFolder(title: "SNIPPET-CANARY-FOLDER", snippets: [Snippet(title: "t", content: "SNIPPET-CANARY-BODY")])]
        for (url, bytes) in allFileBytes(under: dir) {
            XCTAssertNil(bytes.range(of: Data("SNIPPET-CANARY".utf8)), url.lastPathComponent)
        }
    }
}
