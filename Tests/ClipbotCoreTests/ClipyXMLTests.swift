import XCTest
@testable import ClipbotCore

final class ClipyXMLTests: XCTestCase {
    let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <folders><folder><title>code</title><snippets><snippet><title>consolidation</title><content>Any more consolidation you would do?</content></snippet></snippets></folder><folder><title>Learning</title><snippets><snippet><title>Long</title><content>&lt;paste 5-10+ reference links&gt;
    I would like you to teach me about &lt;topic&gt; &amp; more</content></snippet><snippet><title>Short</title><content>Teach me this paper.</content></snippet></snippets></folder><folder><title>empty</title><snippets/></folder></folders>
    """

    func strip(_ f: [SnippetFolder]) -> [[String]] {
        f.map { [$0.title] + $0.snippets.flatMap { [$0.title, $0.content] } }
    }

    func testParsesClipyExport() throws {
        let folders = try ClipyXML.parse(Data(sample.utf8))
        XCTAssertEqual(strip(folders), [
            ["code", "consolidation", "Any more consolidation you would do?"],
            ["Learning", "Long", "<paste 5-10+ reference links>\nI would like you to teach me about <topic> & more", "Short", "Teach me this paper."],
            ["empty"],
        ])
        XCTAssertTrue(folders.allSatisfy { $0.enabled && $0.snippets.allSatisfy(\.enabled) })
    }

    func testExportRoundTrips() throws {
        let folders = try ClipyXML.parse(Data(sample.utf8))
        XCTAssertEqual(strip(try ClipyXML.parse(ClipyXML.export(folders))), strip(folders))
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try ClipyXML.parse(Data("not xml <".utf8)))
        XCTAssertThrowsError(try ClipyXML.parse(Data("<plist></plist>".utf8)))
    }
}
