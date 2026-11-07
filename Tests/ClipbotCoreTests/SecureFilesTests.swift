import XCTest
@testable import ClipbotCore

final class SecureFilesTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipbot-tests-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func perms(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    }

    func testEnsureDirectoryIsPrivateAndExcludedFromBackup() throws {
        try SecureFiles.ensureDirectory(dir)
        XCTAssertEqual(try perms(dir), 0o700)
        XCTAssertEqual(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        // Idempotent and repairs loose permissions.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try SecureFiles.ensureDirectory(dir)
        XCTAssertEqual(try perms(dir), 0o700)
    }

    func testWriteAtomicallyIsOwnerOnlyAndLeavesNoTempFiles() throws {
        try SecureFiles.ensureDirectory(dir)
        let f = dir.appendingPathComponent("a.bin")
        try SecureFiles.writeAtomically(Data([1, 2, 3]), to: f)
        try SecureFiles.writeAtomically(Data([4, 5]), to: f)
        XCTAssertEqual(try Data(contentsOf: f), Data([4, 5]))
        XCTAssertEqual(try perms(f), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["a.bin"])
    }

    func testQuarantineMovesFilesIntoDatedFolder() throws {
        try SecureFiles.ensureDirectory(dir)
        try SecureFiles.writeAtomically(Data([1]), to: dir.appendingPathComponent("index.bin"))
        try SecureFiles.ensureDirectory(dir.appendingPathComponent("clips"))
        try SecureFiles.writeAtomically(Data([2]), to: dir.appendingPathComponent("clips/x.bin"))
        try SecureFiles.writeAtomically(Data([3]), to: dir.appendingPathComponent("snippets.bin"))
        let date = ISO8601DateFormatter().date(from: "2026-11-07T10:00:00Z")!
        let q = try SecureFiles.quarantine(["index.bin", "clips"], in: dir, date: date)
        XCTAssertEqual(q.lastPathComponent, "Unreadable-2026-11-07")
        XCTAssertTrue(FileManager.default.fileExists(atPath: q.appendingPathComponent("index.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: q.appendingPathComponent("clips/x.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("snippets.bin").path))
        // A second quarantine on the same day never overwrites the first.
        try SecureFiles.writeAtomically(Data([9]), to: dir.appendingPathComponent("index.bin"))
        let q2 = try SecureFiles.quarantine(["index.bin"], in: dir, date: date)
        XCTAssertNotEqual(q, q2)
        XCTAssertEqual(try Data(contentsOf: q.appendingPathComponent("index.bin")), Data([1]))
    }
}
