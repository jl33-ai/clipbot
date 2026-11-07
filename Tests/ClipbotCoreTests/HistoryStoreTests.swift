import XCTest
@testable import ClipbotCore

final class HistoryStoreTests: XCTestCase {
    var dir: URL!
    var keys: InMemoryKeyStore!

    override func setUp() { dir = makeTempDir(); keys = InMemoryKeyStore() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func open(capacity: Int = 100) throws -> HistoryStore { try HistoryStore(directory: dir, keys: keys, capacity: capacity) }
    func add(_ s: HistoryStore, _ text: String) throws { try s.add(textPayload(text), kind: .text, preview: text, thumbnail: nil) }
    func clipFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("clips").path)) ?? []).filter { $0.hasSuffix(".bin") }
    }

    func testAddPersistsAcrossReopen() throws {
        let s = try open()
        try add(s, "one")
        try s.add(ClipPayload(representations: [.init(type: "public.png", data: Data([1, 2, 3]))]), kind: .image, preview: "Image", thumbnail: Data([9]))
        let r = try open()
        XCTAssertEqual(r.entries.map(\.preview), ["Image", "one"])
        XCTAssertEqual(r.entries.first?.thumbnail, Data([9]))
        XCTAssertEqual(r.entries.first?.kind, .image)
        XCTAssertEqual(try r.payload(for: r.entries[1].id), textPayload("one"))
        XCTAssertFalse(r.recoveredFromMissingKey)
    }

    func testEvictsOldestBeyondCapacity() throws {
        let s = try open()
        for i in 1...101 { try add(s, "clip \(i)") }
        XCTAssertEqual(s.entries.count, 100)
        XCTAssertEqual(s.entries.first?.preview, "clip 101")
        XCTAssertEqual(s.entries.last?.preview, "clip 2")
        XCTAssertEqual(clipFiles().count, 100)
    }

    func testDuplicateMovesToTopInsteadOfAdding() throws {
        let s = try open()
        try add(s, "a"); try add(s, "b"); try add(s, "c")
        let idA = s.entries[2].id
        try add(s, "a")
        XCTAssertEqual(s.entries.map(\.preview), ["a", "c", "b"])
        XCTAssertEqual(s.entries.first?.id, idA)
        XCTAssertEqual(clipFiles().count, 3)
    }

    func testMoveToTop() throws {
        let s = try open()
        try add(s, "a"); try add(s, "b")
        try s.moveToTop(s.entries[1].id)
        XCTAssertEqual(try open().entries.map(\.preview), ["a", "b"])
    }

    func testClearErasesAndRotatesKey() throws {
        let s = try open()
        try add(s, "secret-ish")
        let oldKey = try XCTUnwrap(try keys.existingKey("clip-key")).withUnsafeBytes { Data($0) }
        let oldIndex = try Data(contentsOf: dir.appendingPathComponent("index.bin"))
        try s.clear()
        XCTAssertTrue(s.entries.isEmpty)
        XCTAssertTrue(clipFiles().isEmpty)
        let newKey = try XCTUnwrap(try keys.existingKey("clip-key"))
        XCTAssertNotEqual(newKey.withUnsafeBytes { Data($0) }, oldKey)
        XCTAssertThrowsError(try Sealer(key: newKey).open(oldIndex), "old ciphertext must be unreadable after clear")
        XCTAssertTrue(try open().entries.isEmpty)
    }

    func testCorruptClipFileIsSkipped() throws {
        let s = try open()
        try add(s, "good"); try add(s, "bad")
        let bad = s.entries[0].id
        try Data(repeating: 0xAB, count: 64).write(to: dir.appendingPathComponent("clips/\(bad.uuidString).bin"))
        let r = try open()
        XCTAssertThrowsError(try r.payload(for: bad))
        XCTAssertEqual(r.entries.map(\.preview), ["good"], "corrupt entry is dropped once detected")
        XCTAssertEqual(try open().entries.map(\.preview), ["good"], "and the drop is persisted")
        XCTAssertEqual(try r.payload(for: r.entries[0].id), textPayload("good"))
    }

    func testMissingClipFileIsDroppedOnOpen() throws {
        let s = try open()
        try add(s, "keep"); try add(s, "gone")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("clips/\(s.entries[0].id.uuidString).bin"))
        XCTAssertEqual(try open().entries.map(\.preview), ["keep"])
    }

    func testCorruptIndexQuarantinesAndStartsFresh() throws {
        let s = try open()
        try add(s, "x")
        try Data(repeating: 0x00, count: 80).write(to: dir.appendingPathComponent("index.bin"))
        let r = try open()
        XCTAssertTrue(r.entries.isEmpty)
        XCTAssertTrue(r.recoveredFromMissingKey)
        try add(r, "works again")
        XCTAssertEqual(try open().entries.map(\.preview), ["works again"])
    }

    func testMissingKeyQuarantinesFiles() throws {
        let s = try open()
        try add(s, "x")
        try keys.deleteKey("clip-key")
        let r = try open()
        XCTAssertTrue(r.entries.isEmpty)
        XCTAssertTrue(r.recoveredFromMissingKey)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let q = try XCTUnwrap(names.first { $0.hasPrefix("Unreadable-") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(q)/index.bin").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("\(q)/clips").path).count, 1)
    }

    func testFirstLaunchIsNotARecovery() throws {
        XCTAssertFalse(try open().recoveredFromMissingKey)
    }

    func testNoPlaintextOnDisk() throws {
        let s = try open()
        let canary = "PLAINTEXT-CANARY-123"
        try s.add(textPayload(canary), kind: .text, preview: canary, thumbnail: nil)
        for (url, bytes) in allFileBytes(under: dir) {
            XCTAssertNil(bytes.range(of: Data(canary.utf8)), "plaintext found in \(url.lastPathComponent)")
        }
    }
}
