import AppKit
import XCTest
@testable import ClipbotCore

func entry(_ preview: String, searchText: String? = nil, kind: ClipKind = .text) -> ClipEntry {
    ClipEntry(id: UUID(), lastUsed: Date(), kind: kind, preview: preview, thumbnail: nil, tag: Data(), searchText: searchText)
}

final class PopupSearchTests: XCTestCase {
    func m(_ q: String, _ t: String) -> Bool { PopupSearch.matches(q, in: t) }

    func testEmptyOrBlankQueryMatchesEverything() {
        XCTAssertTrue(m("", "anything"))
        XCTAssertTrue(m("   \n\t", "anything"))
        XCTAssertTrue(m("", ""))
    }

    func testIgnoresCaseAccentsAndWidth() {
        XCTAssertTrue(m("HELLO", "hello world"))
        XCTAssertTrue(m("cafe", "Café au lait"))
        XCTAssertTrue(m("café", "CAFE"))
        XCTAssertTrue(m("abc", "ＡＢＣ"), "full-width letters")
    }

    func testEveryWordMustMatchInAnyOrder() {
        XCTAssertTrue(m("world hello", "hello there world"))
        XCTAssertTrue(m("  hello   world  ", "hello world"), "extra spaces")
        XCTAssertFalse(m("hello moon", "hello world"))
    }

    func testWordsAreLiteralNotRegex() {
        XCTAssertFalse(m(".*", "anything"))
        XCTAssertTrue(m(".*", "a.*b"))
        XCTAssertTrue(m("(a|b)", "x(a|b)y"))
        XCTAssertTrue(m("[", "a[b"))
    }

    func testMatchesAcrossLinesAndScripts() {
        XCTAssertTrue(m("second", "first line\nsecond line"))
        XCTAssertTrue(m("日本", "こんにちは日本語"))
        XCTAssertTrue(m("👍🏽", "great 👍🏽 job"))
        XCTAssertTrue(m("שלום", "שלום עולם"))
    }

    func testHighlightRangesAreMergedAndSorted() {
        let title = "Hello hello world"
        let r = PopupSearch.ranges(of: "world hello", in: title)
        XCTAssertEqual(r.map { String(title[$0]) }, ["Hello", "world"], "first occurrence of each word, in title order")
        let overlap = PopupSearch.ranges(of: "abc bcd", in: "xabcdx")
        XCTAssertEqual(overlap.map { String("xabcdx"[$0]) }, ["abcd"])
        XCTAssertEqual(PopupSearch.ranges(of: "café", in: "Cafe time").map { String("Cafe time"[$0]) }, ["Cafe"])
        XCTAssertTrue(PopupSearch.ranges(of: "", in: "abc").isEmpty)
        XCTAssertTrue(PopupSearch.ranges(of: "zzz", in: "abc").isEmpty, "a word found only in the full text bolds nothing")
        let emoji = "a 👍🏽 b"
        XCTAssertEqual(PopupSearch.ranges(of: "👍🏽", in: emoji).map { String(emoji[$0]) }, ["👍🏽"])
    }

    func testSearchTextIsCapped() {
        let long = String(repeating: "é", count: PopupSearch.maxTextLength + 50)
        XCTAssertEqual(PopupSearch.text([long]).count, PopupSearch.maxTextLength)
        XCTAssertEqual(PopupSearch.text(["a", "b"]), "a\nb")
    }
}

final class PopupListTests: XCTestCase {
    let folders = [
        SnippetFolder(title: "Work", snippets: [
            Snippet(title: "Sig", content: "Best, Linus"),
            Snippet(title: "", content: "  untitled\nsnippet  "),
            Snippet(title: "Off", content: "hidden", enabled: false),
        ]),
        SnippetFolder(title: "Disabled", enabled: false, snippets: [Snippet(title: "Nope", content: "x")]),
    ]

    func list(_ previews: [String], mode: PopupMode = .history) -> PopupList {
        PopupList(mode: mode, history: previews.map { entry($0) }, folders: folders)
    }

    func testModesPickWhatIsShownAndHideDisabledSnippets() {
        let all = list(["a", "b"], mode: .all)
        XCTAssertEqual(all.results.map(\.title), ["a", "b", "Sig", "untitled snippet"])
        XCTAssertEqual(all.firstSnippetIndex, 2)
        XCTAssertEqual(list(["a"], mode: .history).results.map(\.title), ["a"])
        let snippets = list(["a"], mode: .snippets)
        XCTAssertEqual(snippets.results.map(\.title), ["Sig", "untitled snippet"])
        XCTAssertNil(snippets.firstSnippetIndex, "no header when snippets are the first rows")
        XCTAssertNil(list([], mode: .all).results.first(where: { !$0.isSnippet }))
    }

    func testStartsOnFirstRowAndEmptyHasNoSelection() {
        XCTAssertEqual(list(["a", "b"]).selection, 0)
        XCTAssertEqual(list(["a", "b"]).selected?.title, "a")
        let empty = PopupList(mode: .history, history: [], folders: [])
        XCTAssertNil(empty.selection)
        XCTAssertNil(empty.selected)
    }

    func testMovingStopsAtTheEnds() {
        var l = list(["a", "b", "c"])
        l.moveUp(); XCTAssertEqual(l.selection, 0)
        l.moveDown(); l.moveDown(); XCTAssertEqual(l.selection, 2)
        l.moveDown(); XCTAssertEqual(l.selection, 2)
        l.moveToFirst(); XCTAssertEqual(l.selection, 0)
        l.moveToLast(); XCTAssertEqual(l.selection, 2)
    }

    func testMovingInAnEmptyListDoesNothing() {
        var l = PopupList(mode: .history, history: [], folders: [])
        l.moveDown(); l.moveUp(); l.moveToFirst(); l.moveToLast()
        XCTAssertNil(l.selection)
        XCTAssertNil(l.item(atShortcutRow: 0))
    }

    func testTypingFiltersAndReselectsTheFirstMatch() {
        var l = list(["apple pie", "banana", "apple tart"])
        l.moveToLast()
        l.query = "apple"
        XCTAssertEqual(l.results.map(\.title), ["apple pie", "apple tart"])
        XCTAssertEqual(l.selection, 0)
        l.query = "zzz"
        XCTAssertTrue(l.results.isEmpty)
        XCTAssertNil(l.selection)
        l.moveDown()
        XCTAssertNil(l.selection)
        l.query = "   "
        XCTAssertEqual(l.results.count, 3, "a blank query shows everything")
    }

    func testSettingTheSameQueryKeepsTheSelection() {
        var l = list(["ab", "abc"])
        l.query = "ab"
        l.moveDown()
        l.query = "ab"
        XCTAssertEqual(l.selection, 1)
    }

    func testSearchesFullTextNotJustTheTitle() {
        let e = entry("short preview…", searchText: "short preview and the rest of the long text")
        var l = PopupList(mode: .history, history: [e, entry("other")], folders: [])
        l.query = "long text"
        XCTAssertEqual(l.results.map(\.id), [e.id])
    }

    func testOldClipsWithoutSearchTextAreSearchedByPreview() {
        var l = PopupList(mode: .history, history: [entry("legacy clip", searchText: nil)], folders: [])
        l.query = "legacy"
        XCTAssertEqual(l.results.count, 1)
    }

    func testSnippetsAreSearchedByTitleAndContent() {
        var l = list([], mode: .snippets)
        l.query = "linus"
        XCTAssertEqual(l.results.map(\.title), ["Sig"])
        l.query = "sig"
        XCTAssertEqual(l.results.map(\.title), ["Sig"])
        l.query = "hidden"
        XCTAssertTrue(l.results.isEmpty, "disabled snippets never match")
    }

    func testShortcutKeysAreOneToNineThenZero() {
        XCTAssertEqual((0..<10).compactMap(PopupList.shortcutKey(forRow:)), ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
        XCTAssertNil(PopupList.shortcutKey(forRow: 10))
        XCTAssertNil(PopupList.shortcutKey(forRow: -1))
    }

    func testShortcutRowsFollowTheFilteredList() {
        var l = list((1...15).map { "clip \($0)" })
        XCTAssertEqual(l.item(atShortcutRow: 9)?.title, "clip 10")
        XCTAssertNil(l.item(atShortcutRow: 10), "only ten rows have shortcuts")
        XCTAssertNil(l.item(atShortcutRow: -1))
        l.query = "clip 1"
        XCTAssertEqual(l.results.map(\.title), ["clip 1", "clip 10", "clip 11", "clip 12", "clip 13", "clip 14", "clip 15"])
        XCTAssertEqual(l.item(atShortcutRow: 1)?.title, "clip 10")
        XCTAssertNil(l.item(atShortcutRow: 7), "beyond the results")
    }

    func testEscapeClearsTheSearchBeforeClosing() {
        var l = list(["a", "b"])
        l.query = "b"
        XCTAssertFalse(l.escape())
        XCTAssertEqual(l.query, "")
        XCTAssertEqual(l.results.count, 2)
        XCTAssertTrue(l.escape())
    }

    func testRemovingKeepsTheSelectionOnTheSameRow() {
        var l = list(["a", "b", "c"])
        l.moveDown()
        l.remove(id: l.results[1].id)
        XCTAssertEqual(l.results.map(\.title), ["a", "c"])
        XCTAssertEqual(l.selected?.title, "c")
    }

    func testRemovingTheLastRowMovesUp() {
        var l = list(["a", "b"])
        l.moveToLast()
        l.remove(id: l.results[1].id)
        XCTAssertEqual(l.selected?.title, "a")
    }

    func testRemovingARowAboveKeepsTheSameItemSelected() {
        var l = list(["a", "b", "c"])
        l.moveToLast()
        l.remove(id: l.results[0].id)
        XCTAssertEqual(l.selected?.title, "c")
    }

    func testRemovingTheOnlyRowLeavesNoSelection() {
        var l = list(["a"])
        l.remove(id: l.results[0].id)
        XCTAssertTrue(l.results.isEmpty)
        XCTAssertNil(l.selection)
    }

    func testRemovingAFilteredOutItemDropsItFromLaterSearches() {
        var l = list(["apple", "banana"])
        let banana = l.items[1].id
        l.query = "apple"
        l.remove(id: banana)
        XCTAssertEqual(l.selected?.title, "apple")
        l.query = ""
        XCTAssertEqual(l.results.map(\.title), ["apple"])
    }

    func testRemovingAnUnknownIdChangesNothing() {
        var l = list(["a", "b"])
        l.moveDown()
        let before = l
        l.remove(id: UUID())
        XCTAssertEqual(l, before)
    }

    func testSelectById() {
        var l = list(["a", "b", "c"])
        l.select(id: l.results[2].id)
        XCTAssertEqual(l.selection, 2)
        l.select(id: UUID())
        XCTAssertEqual(l.selection, 2, "unknown id is ignored")
    }
}

final class PopupKeysTests: XCTestCase {
    func c(_ code: UInt16, _ m: NSEvent.ModifierFlags = []) -> PopupCommand? { PopupKeys.command(keyCode: code, modifiers: m) }

    func testNavigation() {
        XCTAssertEqual(c(125), .moveDown)
        XCTAssertEqual(c(126), .moveUp)
        XCTAssertEqual(c(45, .control), .moveDown, "⌃N")
        XCTAssertEqual(c(35, .control), .moveUp, "⌃P")
        XCTAssertEqual(c(126, .command), .moveToFirst)
        XCTAssertEqual(c(125, .command), .moveToLast)
    }

    func testArrowKeysIgnoreTheirOwnFlagsAndCapsLock() {
        XCTAssertEqual(c(125, [.numericPad, .function]), .moveDown)
        XCTAssertEqual(c(126, [.numericPad, .function, .capsLock]), .moveUp)
        XCTAssertEqual(c(126, [.command, .numericPad, .function]), .moveToFirst)
        XCTAssertEqual(c(18, [.command, .capsLock]), .pasteRow(0))
    }

    func testShiftArrowsAndOtherCombosStayWithTheSearchField() {
        XCTAssertNil(c(125, .shift), "⇧↓ selects text")
        XCTAssertNil(c(126, .option))
        XCTAssertNil(c(45), "plain n types")
        XCTAssertNil(c(51), "plain ⌫ deletes a character")
        XCTAssertNil(c(51, .command), "⌘⌫ deletes the line")
        XCTAssertNil(c(0, .command), "⌘A selects all")
    }

    func testPasteAndEscape() {
        XCTAssertEqual(c(36), .paste)
        XCTAssertEqual(c(76), .paste, "keypad enter")
        XCTAssertEqual(c(36, .shift), .paste)
        XCTAssertEqual(c(53), .escape)
        XCTAssertNil(c(53, .command))
    }

    func testCommandDigitsPasteRowsByPhysicalKey() {
        let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        XCTAssertEqual(codes.map { c($0, .command) }, (0..<10).map { .pasteRow($0) })
        XCTAssertNil(c(18), "a plain digit types into the search")
        XCTAssertNil(c(18, [.command, .shift]))
        XCTAssertNil(c(18, [.command, .option]))
        XCTAssertNil(c(83, .command), "keypad 1 is not the number row")
    }

    func testCommands() {
        XCTAssertEqual(c(51, .option), .deleteItem)
        XCTAssertEqual(c(51, [.option, .command]), .clearHistory)
        XCTAssertEqual(c(43, .command), .settings)
        XCTAssertEqual(c(12, .command), .quit)
        XCTAssertNil(c(12), "plain q types")
    }
}

final class HistorySearchTextTests: TempDirTestCase {
    func testSearchTextPersistsEncryptedAndCapped() throws {
        let keys = InMemoryKeyStore()
        let canary = "searchable-canary-\(UUID().uuidString)"
        let s = try HistoryStore(directory: dir, keys: keys)
        try s.add(textPayload("x"), kind: .text, preview: "x", thumbnail: nil, searchText: canary + String(repeating: "y", count: 5_000))
        let r = try HistoryStore(directory: dir, keys: keys)
        XCTAssertEqual(r.entries.first?.searchText?.count, PopupSearch.maxTextLength)
        XCTAssertTrue(r.entries.first?.searchText?.hasPrefix(canary) ?? false)
        for (url, bytes) in allFileBytes(under: dir) {
            XCTAssertNil(bytes.range(of: Data(canary.utf8)), "plaintext search text in \(url.lastPathComponent)")
        }
    }

    func testIndexFromBeforeSearchStillDecodes() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","lastUsed":0,"kind":"text","preview":"old","tag":""}]"#
        let entries = try JSONDecoder().decode([ClipEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.first?.preview, "old")
        XCTAssertNil(entries.first?.searchText)
        XCTAssertEqual(PopupItem(clip: entries[0]).searchText, "old")
    }

    func testDeleteRemovesOneClipAndItsFile() throws {
        let keys = InMemoryKeyStore()
        let s = try HistoryStore(directory: dir, keys: keys)
        try s.add(textPayload("keep"), kind: .text, preview: "keep", thumbnail: nil)
        try s.add(textPayload("drop"), kind: .text, preview: "drop", thumbnail: nil)
        let drop = try XCTUnwrap(s.entries.first)
        try s.delete(drop.id)
        XCTAssertEqual(s.entries.map(\.preview), ["keep"])
        let clips = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("clips").path)
        XCTAssertFalse(clips.contains("\(drop.id.uuidString).bin"))
        XCTAssertEqual(try HistoryStore(directory: dir, keys: keys).entries.map(\.preview), ["keep"], "persists")
        try s.delete(UUID()) // unknown id: no-op, no throw
        XCTAssertEqual(s.entries.count, 1)
        try s.add(textPayload("drop"), kind: .text, preview: "drop", thumbnail: nil)
        XCTAssertEqual(s.entries.map(\.preview), ["drop", "keep"], "a deleted clip can be recorded again")
    }
}

final class CaptureSearchTextTests: PasteboardTestCase {
    func testTextKeepsMoreThanThePreview() throws {
        let long = "start " + String(repeating: "word ", count: 30) + "needle at the end"
        pb.setString(long, forType: .string)
        let c = try XCTUnwrap(capture())
        XCTAssertFalse(c.preview.contains("needle"))
        XCTAssertTrue(c.searchText.contains("needle"))
    }

    func testFilesAreSearchedByEveryName() throws {
        pb.writeObjects([URL(fileURLWithPath: "/tmp/first.txt") as NSURL, URL(fileURLWithPath: "/tmp/second.pdf") as NSURL])
        let c = try XCTUnwrap(capture())
        XCTAssertEqual(c.kind, .file)
        XCTAssertFalse(c.preview.contains("second"))
        XCTAssertTrue(c.searchText.contains("second.pdf"))
    }

    func testURLIsSearchable() throws {
        pb.setString("https://example.com/path", forType: .URL)
        let c = try XCTUnwrap(capture())
        XCTAssertEqual(c.kind, .url)
        XCTAssertEqual(c.searchText, "https://example.com/path")
    }

    func testImageIsSearchedByItsLabel() throws {
        let img = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in NSColor.blue.setFill(); r.fill(); return true }
        pb.setData(img.tiffRepresentation!, forType: .tiff)
        let c = try XCTUnwrap(capture())
        XCTAssertEqual(c.kind, .image)
        XCTAssertTrue(PopupSearch.matches("image", in: c.searchText))
    }
}
