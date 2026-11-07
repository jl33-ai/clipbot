import AppKit
import Carbon.HIToolbox
import XCTest
@testable import ClipbotCore

final class ClipWriterTests: PasteboardTestCase {

    func testWritePayloadRoundTripsThroughCapture() throws {
        let item = NSPasteboardItem()
        item.setString("bold", forType: .string)
        item.setData(Data("{\\rtf1 bold}".utf8), forType: .rtf)
        pb.writeObjects([item])
        let original = try XCTUnwrap(capture()).payload
        pb.clearContents()
        ClipWriter.write(original, to: pb)
        XCTAssertEqual(capture()?.payload, original)
    }

    func testMultipleFilesBecomeSeparateItems() throws {
        pb.writeObjects([URL(fileURLWithPath: "/tmp/a") as NSURL, URL(fileURLWithPath: "/tmp/b") as NSURL])
        let original = try XCTUnwrap(capture()).payload
        pb.clearContents()
        ClipWriter.write(original, to: pb)
        XCTAssertEqual(pb.pasteboardItems?.count, 2)
        XCTAssertEqual(capture()?.payload, original)
    }

    func testWriteTextIsPlainOnly() {
        ClipWriter.writeText("snippet body", to: pb)
        XCTAssertEqual(pb.string(forType: .string), "snippet body")
        let types = Set(pb.types ?? [])
        XCTAssertTrue(types.contains(.string))
        XCTAssertTrue(types.isDisjoint(with: [.rtf, .rtfd, .html]), "snippets paste as plain text")
    }

    func testWritesAreLocalOnly() {
        // .currentHostOnly marks contents so Universal Clipboard never syncs them to other devices.
        ClipWriter.writeText("x", to: pb)
        XCTAssertFalse(pb.types?.contains(NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")) ?? false)
        XCTAssertEqual(ClipWriter.contentsOptions, .currentHostOnly)
    }
}

final class ShortcutTests: XCTestCase {
    func testDefaultsMatchClipy() {
        XCTAssertEqual(Shortcut.mainDefault, Shortcut(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | shiftKey)))
        XCTAssertEqual(Shortcut.historyDefault, Shortcut(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | controlKey)))
        XCTAssertEqual(Shortcut.snippetsDefault, Shortcut(keyCode: UInt32(kVK_ANSI_B), carbonModifiers: UInt32(cmdKey | shiftKey)))
    }

    func testDisplay() {
        XCTAssertEqual(Shortcut.mainDefault.display, "⇧⌘V")
        XCTAssertEqual(Shortcut.historyDefault.display, "⌃⌘V")
        XCTAssertEqual(Shortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey)).display, "⌥Space")
    }

    func testFromCocoaModifiers() {
        let s = Shortcut(keyCode: 9, modifierFlags: [.command, .shift])
        XCTAssertEqual(s, Shortcut.mainDefault)
        XCTAssertFalse(Shortcut(keyCode: 9, modifierFlags: []).isValid, "a bare key would hijack typing")
        XCTAssertFalse(Shortcut(keyCode: 9, modifierFlags: [.shift]).isValid)
        XCTAssertTrue(Shortcut.mainDefault.isValid)
    }

    func testCodableRoundTrip() throws {
        let d = try JSONEncoder().encode(Shortcut.snippetsDefault)
        XCTAssertEqual(try JSONDecoder().decode(Shortcut.self, from: d), Shortcut.snippetsDefault)
    }
}
