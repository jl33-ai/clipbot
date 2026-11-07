import XCTest
import CryptoKit
@testable import ClipbotCore

final class SealerTests: XCTestCase {
    let sealer = Sealer(key: SymmetricKey(size: .bits256))
    let data = Data("hello clipbot".utf8)

    func testRoundTrip() throws {
        XCTAssertEqual(try sealer.open(try sealer.seal(data, context: "t"), context: "t"), data)
    }

    func testTamperedCiphertextThrows() throws {
        var box = try sealer.seal(data, context: "t")
        box[box.count / 2] ^= 0x01
        XCTAssertThrowsError(try sealer.open(box, context: "t"))
    }

    func testWrongKeyThrows() throws {
        let box = try sealer.seal(data, context: "t")
        XCTAssertThrowsError(try Sealer(key: SymmetricKey(size: .bits256)).open(box, context: "t"))
    }

    func testWrongContextThrows() throws {
        let box = try sealer.seal(data, context: "clip/A")
        XCTAssertThrowsError(try sealer.open(box, context: "clip/B"))
    }

    func testSealsAreRandomised() throws {
        XCTAssertNotEqual(try sealer.seal(data, context: "t"), try sealer.seal(data, context: "t"))
    }

    func testCiphertextDoesNotContainPlaintext() throws {
        let box = try sealer.seal(data, context: "t")
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
