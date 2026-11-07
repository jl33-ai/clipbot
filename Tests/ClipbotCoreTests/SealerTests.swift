import XCTest
import CryptoKit
@testable import ClipbotCore

final class SealerTests: XCTestCase {
    let sealer = Sealer(key: SymmetricKey(size: .bits256))
    let data = Data("hello clipbot".utf8)

    func testRoundTrip() throws {
        XCTAssertEqual(try sealer.open(try sealer.seal(data)), data)
    }

    func testTamperedCiphertextThrows() throws {
        var box = try sealer.seal(data)
        box[box.count / 2] ^= 0x01
        XCTAssertThrowsError(try sealer.open(box))
    }

    func testWrongKeyThrows() throws {
        let box = try sealer.seal(data)
        XCTAssertThrowsError(try Sealer(key: SymmetricKey(size: .bits256)).open(box))
    }

    func testSealsAreRandomised() throws {
        XCTAssertNotEqual(try sealer.seal(data), try sealer.seal(data))
    }

    func testCiphertextDoesNotContainPlaintext() throws {
        let box = try sealer.seal(data)
        XCTAssertNil(box.range(of: data))
    }

    func testTagStableForKeyAndDiffersAcrossKeys() {
        XCTAssertEqual(sealer.tag(data), sealer.tag(data))
        XCTAssertEqual(sealer.tag(data).count, 32)
        XCTAssertNotEqual(sealer.tag(data), sealer.tag(Data("other".utf8)))
        XCTAssertNotEqual(sealer.tag(data), Sealer(key: SymmetricKey(size: .bits256)).tag(data))
        // Not a plain hash of the content.
        XCTAssertNotEqual(sealer.tag(data), Data(SHA256.hash(data: data)))
    }
}
