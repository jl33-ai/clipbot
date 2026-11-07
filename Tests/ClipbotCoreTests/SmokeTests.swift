import XCTest
@testable import ClipbotCore

final class SmokeTests: XCTestCase {
    func testCoreLinks() {
        XCTAssertNotNil(MenuModel.self)
    }
}
