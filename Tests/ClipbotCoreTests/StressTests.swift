import AppKit
import XCTest
@testable import ClipbotCore

/// Hostile and oversized input on every path data can enter Clipbot. Each test must finish fast,
/// without crashing, hanging or exploding memory. Randomness is seeded so failures reproduce.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 { // splitmix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func randomData(_ n: Int, _ rng: inout SeededRNG) -> Data {
    Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
}

func mutate(_ d: Data, _ rng: inout SeededRNG) -> Data {
    var b = [UInt8](d)
    guard !b.isEmpty else { return d }
    switch Int.random(in: 0..<4, using: &rng) {
    case 0: for _ in 0..<Int.random(in: 1...8, using: &rng) { b[Int.random(in: 0..<b.count, using: &rng)] = .random(in: 0...255, using: &rng) }
    case 1: b = Array(b.prefix(Int.random(in: 0..<b.count, using: &rng)))
    case 2: b.insert(contentsOf: [UInt8](randomData(Int.random(in: 1...64, using: &rng), &rng)), at: Int.random(in: 0..<b.count, using: &rng))
    default: let i = Int.random(in: 0..<b.count, using: &rng); b.removeSubrange(i..<min(b.count, i + Int.random(in: 1...32, using: &rng)))
    }
    return Data(b)
}

func assertFast(_ limit: TimeInterval, _ what: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) rethrows {
    let t0 = Date()
    try body()
    let dt = Date().timeIntervalSince(t0)
    XCTAssertLessThan(dt, limit, "\(what) took \(String(format: "%.2f", dt))s", file: file, line: line)
}

// MARK: - Snippet import (untrusted XML file)

final class XMLStressTests: XCTestCase {
    let valid = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <folders><folder><title>code</title><snippets><snippet><title>a</title><content>x &amp; y</content></snippet></snippets></folder></folders>
    """.utf8)

    func testMalformedAndMutatedXMLNeverCrashes() {
        var rng = SeededRNG(1)
        assertFast(5, "2000 mutated imports") {
            for _ in 0..<2000 { _ = try? ClipyXML.parse(mutate(valid, &rng)) }
            for _ in 0..<200 { _ = try? ClipyXML.parse(randomData(Int.random(in: 0...4096, using: &rng), &rng)) }
        }
    }

    func testEntityExpansionBombIsBounded() {
        // "Billion laughs": 10 levels × 10 = 10^10 copies if expanded naively.
        var dtd = "<!ENTITY l0 \"lol\">"
        for i in 1...10 { dtd += "<!ENTITY l\(i) \"" + String(repeating: "&l\(i - 1);", count: 10) + "\">" }
        let doc = "<?xml version=\"1.0\"?><!DOCTYPE folders [\(dtd)]><folders><folder><title>&l10;</title><snippets/></folder></folders>"
        assertFast(2, "entity bomb") {
            let folders = try? ClipyXML.parse(Data(doc.utf8))
            let total = folders?.reduce(0) { $0 + $1.title.utf8.count } ?? 0
            XCTAssertLessThan(total, 1_000_000, "entities must not expand without bound")
        }
    }

    func testExternalEntitiesAreNeverResolved() throws {
        let secret = FileManager.default.temporaryDirectory.appendingPathComponent("clipbot-xxe-\(UUID().uuidString).txt")
        try "XXE-CANARY-SECRET".write(to: secret, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secret) }
        let doc = """
        <?xml version="1.0"?><!DOCTYPE folders [<!ENTITY x SYSTEM "\(secret.absoluteString)">]>
        <folders><folder><title>&x;</title><snippets/></folder></folders>
        """
        let titles = (try? ClipyXML.parse(Data(doc.utf8)))?.map(\.title) ?? []
        XCTAssertFalse(titles.joined().contains("XXE-CANARY"), "a local file was read through an external entity")
    }

    func testDeepNestingDoesNotOverflow() {
        let depth = 50_000
        let doc = "<folders>" + String(repeating: "<folder>", count: depth) + String(repeating: "</folder>", count: depth) + "</folders>"
        assertFast(5, "deep nesting") { _ = try? ClipyXML.parse(Data(doc.utf8)) }
    }

    func testHugeFolderCount() {
        let one = "<folder><title>f</title><snippets><snippet><title>t</title><content>c</content></snippet></snippets></folder>"
        let doc = "<folders>" + String(repeating: one, count: 20_000) + "</folders>"
        assertFast(5, "20k folders") { XCTAssertEqual(try? ClipyXML.parse(Data(doc.utf8)).count, 20_000) }
    }
}

// MARK: - Clipboard capture (untrusted data from any app)

final class CaptureStressTests: PasteboardTestCase {
    // .fileURL is left out: a malformed file URL written and read by the same test process stalls
    // the pasteboard server's sandbox-extension lookup. Follow-up: reproduce across two processes.
    let types: [NSPasteboard.PasteboardType] = [.rtf, .rtfd, .pdf, .tiff, .png, .string, .URL]

    func seeds() throws -> [NSPasteboard.PasteboardType: Data] {
        let img = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { r in NSColor.green.setFill(); r.fill(); return true }
        let tiff = try XCTUnwrap(img.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let attr = NSAttributedString(string: "hello rich")
        let rtfd = try XCTUnwrap(attr.rtfd(from: NSRange(location: 0, length: attr.length), documentAttributes: [:]))
        let pdfData = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 50, height: 50)
        let ctx = try XCTUnwrap(CGContext(consumer: CGDataConsumer(data: pdfData)!, mediaBox: &box, nil))
        ctx.beginPDFPage(nil); ctx.fill(box); ctx.endPDFPage(); ctx.closePDF()
        return [.rtf: try rtfData("hello rich"), .rtfd: rtfd, .pdf: pdfData as Data, .tiff: tiff, .png: png,
                .string: Data("plain".utf8), .URL: Data("https://example.com".utf8),
                .fileURL: URL(fileURLWithPath: "/tmp/x").dataRepresentation]
    }

    func testMutatedPayloadsOfEveryTypeNeverCrash() throws {
        var rng = SeededRNG(2)
        let base = try seeds()
        assertFast(20, "mutated captures") {
            for i in 0..<800 {
                let type = types[i % types.count]
                let item = NSPasteboardItem()
                item.setData(mutate(base[type]!, &rng), forType: type)
                if i % 3 == 0 { item.setData(mutate(base[.string]!, &rng), forType: .string) }
                pb.clearContents()
                pb.writeObjects([item])
                let filter = SecretFilter(ignoredBundleIDs: [])
                _ = ClipGate.evaluate(items: pb.pasteboardItems ?? [], secureInput: false, sourceBundleIDs: [], filter: filter)
            }
        }
    }

    func testRandomBytesUnderImageAndDocumentTypesNeverCrash() {
        var rng = SeededRNG(3)
        assertFast(10, "random-byte captures") {
            for i in 0..<400 {
                let item = NSPasteboardItem()
                item.setData(randomData(Int.random(in: 0...8192, using: &rng), &rng), forType: types[i % 5])
                pb.clearContents()
                pb.writeObjects([item])
                _ = capture()
            }
        }
    }

    func testThousandsOfItemsAreHandledQuickly() {
        let items = (0..<3000).map { i -> NSPasteboardItem in
            let it = NSPasteboardItem()
            it.setString("item \(i)", forType: .string)
            if i % 2 == 0 { it.setData(URL(fileURLWithPath: "/tmp/f\(i)").dataRepresentation, forType: .fileURL) }
            return it
        }
        pb.writeObjects(items)
        assertFast(3, "3000-item copy") { _ = capture() }
    }

    func testOversizedTextIsRejectedWithoutHanging() {
        pb.setString(String(repeating: "x", count: ClipCapture.maxBytes + 10), forType: .string)
        assertFast(3, "oversized text") { XCTAssertNil(capture()) }
    }

    func testClaimedHugeTIFFGetsNoThumbnail() {
        // Minimal little-endian TIFF header with ImageWidth/ImageLength = 100000.
        var t = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, 0x02, 0x00])
        t.append(contentsOf: [0x00, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0xA0, 0x86, 0x01, 0x00])
        t.append(contentsOf: [0x01, 0x01, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0xA0, 0x86, 0x01, 0x00])
        t.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        assertFast(1, "huge TIFF header") { XCTAssertNil(ClipCapture.thumbnail(fromImageData: t)) }
    }
}

// MARK: - Secret scanning and previews (untrusted text)

final class TextStressTests: XCTestCase {
    func testSecretScanStaysFastOnAdversarialText() {
        let cases = [
            String(repeating: "a", count: 200_000),                       // one giant token
            String(repeating: "sk-", count: 66_000),                      // prefix spam
            String(repeating: "ghp_aaaa ", count: 22_000),                // near-miss tokens
            String(repeating: "AKIA", count: 50_000),
            String(repeating: "=:\"'`,;()[]{}<>", count: 13_000),         // separators only
            String(repeating: "x", count: 5_000_000) + "-----BEGIN RSA PRIVATE KEY-----",
        ]
        assertFast(3, "adversarial secret scans") {
            for c in cases { _ = SecretFilter.looksLikeSecret(c) }
        }
        XCTAssertTrue(SecretFilter.looksLikeSecret(cases[5]), "PEM header still found at the end of huge text")
    }

    func testPreviewOfRandomUnicodeIsSafeAndBounded() {
        var rng = SeededRNG(4)
        for _ in 0..<2000 {
            let scalars = (0..<Int.random(in: 0...300, using: &rng)).compactMap { _ in
                Unicode.Scalar(UInt32.random(in: 0...0x10FFFF, using: &rng))
            }
            let p = Preview.text(String(String.UnicodeScalarView(scalars)))
            XCTAssertLessThanOrEqual(p.count, 61)
            XCTAssertFalse(p.unicodeScalars.contains { $0 != "\u{200D}" && [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) },
                           "invisible or control characters leaked into a menu title")
        }
    }
}

// MARK: - Encrypted storage under damage and load

final class StorageStressTests: TempDirTestCase {
    func testStoreSurvivesRandomDamageToItsFiles() throws {
        var rng = SeededRNG(5)
        let keys = InMemoryKeyStore()
        let fm = FileManager.default
        for round in 0..<60 {
            let s = try HistoryStore(directory: dir, keys: keys)
            for i in 0..<5 { try s.add(textPayload("r\(round)-\(i)"), kind: .text, preview: "p", thumbnail: nil) }
            // Damage something at random: flip bytes, truncate, empty, replace with garbage, or delete.
            let files = (fm.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { !$0.hasDirectoryPath && !$0.path.contains("Unreadable-") }
            if let f = files.randomElement(using: &rng), let d = try? Data(contentsOf: f) {
                switch Int.random(in: 0..<5, using: &rng) {
                case 0: try mutate(d, &rng).write(to: f)
                case 1: try d.prefix(d.count / 2).write(to: f)
                case 2: try Data().write(to: f)
                case 3: try randomData(Int.random(in: 1...512, using: &rng), &rng).write(to: f)
                default: try fm.removeItem(at: f)
                }
            }
            // Reopening must never crash; every listed entry must be readable or cleanly dropped.
            let r = try HistoryStore(directory: dir, keys: keys)
            for e in r.entries { _ = try? r.payload(for: e.id) }
            try r.add(textPayload("after damage \(round)"), kind: .text, preview: "ok", thumbnail: nil)
            XCTAssertEqual(try HistoryStore(directory: dir, keys: keys).entries.first?.preview, "ok")
        }
    }

    func testGiantGarbageIndexIsQuarantinedQuickly() throws {
        var rng = SeededRNG(6)
        let keys = InMemoryKeyStore()
        _ = try HistoryStore(directory: dir, keys: keys)
        try randomData(30 * 1024 * 1024, &rng).write(to: dir.appendingPathComponent("index.bin"))
        try assertFast(3, "30 MB garbage index") {
            let s = try HistoryStore(directory: dir, keys: keys)
            XCTAssertTrue(s.recoveredFromMissingKey)
            XCTAssertTrue(s.entries.isEmpty)
        }
    }

    func testHeavyChurnKeepsExactlyCapacityFiles() throws {
        let s = try HistoryStore(directory: dir, keys: InMemoryKeyStore())
        try assertFast(30, "3000 adds") {
            for i in 0..<3000 { try s.add(textPayload("churn \(i)"), kind: .text, preview: "c\(i)", thumbnail: nil) }
        }
        XCTAssertEqual(s.entries.count, 100)
        XCTAssertEqual(s.entries.first?.preview, "c2999")
        let clips = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("clips").path)
        XCTAssertEqual(clips.count, 100, "evicted clips must be deleted from disk")
    }

    @MainActor
    func testSnippetStoreSurvivesGarbageFile() throws {
        var rng = SeededRNG(7)
        let keys = InMemoryKeyStore()
        try SnippetStore(directory: dir, keys: keys).folders = [SnippetFolder(title: "keep me")]
        for _ in 0..<30 {
            let f = dir.appendingPathComponent("snippets.bin")
            if let d = try? Data(contentsOf: f) { try mutate(d, &rng).write(to: f) }
            let s = try SnippetStore(directory: dir, keys: keys)
            s.folders = [SnippetFolder(title: "keep me")]
        }
        XCTAssertEqual(try SnippetStore(directory: dir, keys: keys).folders.map(\.title), ["keep me"])
    }
}
