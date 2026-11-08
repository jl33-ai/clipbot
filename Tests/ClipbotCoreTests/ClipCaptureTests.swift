import AppKit
import XCTest
@testable import ClipbotCore

final class ClipCaptureTests: PasteboardTestCase {

    func types(_ c: CapturedClip) -> [String] { c.payload.representations.map(\.type) }

    func testPlainText() throws {
        pb.setString("hello\n  world", forType: .string)
        let c = try XCTUnwrap(capture())
        XCTAssertEqual(c.kind, .text)
        XCTAssertEqual(c.preview, "hello world")
        XCTAssertEqual(types(c), ["public.utf8-plain-text"])
        XCTAssertNil(c.thumbnail)
    }

    func testRichTextKeepsAllRepresentations() throws {
        let rtf = try rtfData("bold")
        let item = NSPasteboardItem()
        item.setString("bold", forType: .string)
        item.setData(rtf, forType: .rtf)
        item.setString("<b>bold</b>", forType: .html) // not a stored type
        pb.writeObjects([item])
        let c = try XCTUnwrap(capture())
        XCTAssertEqual(c.kind, .richText)
        XCTAssertEqual(Set(types(c)), ["public.utf8-plain-text", "public.rtf"])
        XCTAssertEqual(c.preview, "bold")
    }

    func testImageGetsThumbnail() throws {
        let img = NSImage(size: NSSize(width: 400, height: 200), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
        let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        pb.setData(png, forType: .png)
        let c = try XCTUnwrap(capture())
        XCTAssertEqual(c.kind, .image)
        let thumb = try XCTUnwrap(c.thumbnail.flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertLessThanOrEqual(max(thumb.pixelsWide, thumb.pixelsHigh), 64)
        XCTAssertTrue(c.preview.hasPrefix("Image"))
    }

    func testFilesKeepEveryURL() throws {
        let a = URL(fileURLWithPath: "/tmp/report.pdf"), b = URL(fileURLWithPath: "/tmp/notes.txt")
        pb.writeObjects([a as NSURL, b as NSURL])
        let c = try XCTUnwrap(capture())
        XCTAssertEqual(c.kind, .file)
        XCTAssertEqual(c.payload.representations.filter { $0.type == "public.file-url" }.count, 2)
        XCTAssertEqual(c.preview, "report.pdf + 1 more")
    }

    func testWebURL() throws {
        let item = NSPasteboardItem()
        item.setString("https://cal.com/x", forType: .URL)
        item.setString("https://cal.com/x", forType: .string)
        pb.writeObjects([item])
        let c = try XCTUnwrap(capture())
        XCTAssertEqual(c.kind, .url)
        XCTAssertEqual(c.preview, "https://cal.com/x")
    }

    func testWhitespaceOnlyIgnored() {
        pb.setString(" \n\t ", forType: .string)
        XCTAssertNil(capture())
    }

    func testUnstoredTypesIgnored() {
        pb.setString("<b>x</b>", forType: .html)
        XCTAssertNil(capture())
    }

    func testOversizedClipIgnored() {
        pb.setData(Data(count: ClipCapture.maxBytes + 1), forType: .tiff)
        XCTAssertNil(capture())
        XCTAssertEqual(ClipCapture.maxBytes, 20 * 1024 * 1024)
    }
}

final class ChangeTrackerTests: XCTestCase {
    func testOwnWriteIgnoredByChangeCount() {
        var t = ChangeTracker(initial: 5)
        XCTAssertFalse(t.observe(5), "no change")
        XCTAssertTrue(t.observe(6), "external copy")
        XCTAssertFalse(t.observe(6), "same change seen twice")
        t.noteOwnWrite(7)
        XCTAssertFalse(t.observe(7), "Clipbot's own paste write")
        XCTAssertTrue(t.observe(8), "user copies again afterwards")
    }
}

final class PreviewTests: XCTestCase {
    func testPreviewCollapsesAndTruncates() {
        XCTAssertEqual(Preview.text("  a\n\n\tb   c  "), "a b c")
        let long = String(repeating: "x", count: 59) + "👍🏽" + "yyyy"
        let p = Preview.text(long)
        XCTAssertEqual(p, String(repeating: "x", count: 59) + "👍🏽…")
        XCTAssertEqual(Preview.text(String(repeating: "z", count: 60)), String(repeating: "z", count: 60))
        XCTAssertEqual(Preview.text("שלום עולם"), "שלום עולם")
    }
}
