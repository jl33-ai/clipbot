import Foundation

/// Clipy's snippet export format: <folders><folder><title/><snippets><snippet><title/><content/>…
public enum ClipyXML {
    public struct FormatError: Error {}

    public static func parse(_ data: Data) throws -> [SnippetFolder] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        // Imported files are untrusted: never fetch or expand external entities.
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.sawRoot else { throw parser.parserError ?? FormatError() }
        return delegate.folders
    }

    public static func export(_ folders: [SnippetFolder]) -> Data {
        func esc(_ raw: String) -> String {
            // XML 1.0 forbids most C0 controls and U+FFFE/FFFF; drop them so the file re-imports.
            let s = String(String.UnicodeScalarView(raw.unicodeScalars.filter { u in
                u == "\t" || u == "\n" || u == "\r" || (u.value >= 0x20 && u.value != 0xFFFE && u.value != 0xFFFF)
            }))
            return s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<folders>"
        for f in folders {
            out += "<folder><title>\(esc(f.title))</title><snippets>"
            for s in f.snippets { out += "<snippet><title>\(esc(s.title))</title><content>\(esc(s.content))</content></snippet>" }
            out += "</snippets></folder>"
        }
        out += "</folders>\n"
        return Data(out.utf8)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var folders: [SnippetFolder] = []
        var sawRoot = false
        private var path: [String] = []
        private var text = ""
        private var folder: SnippetFolder?
        private var snippet: Snippet?

        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if path.isEmpty { sawRoot = name == "folders" }
            path.append(name)
            text = ""
            if name == "folder" { folder = SnippetFolder(title: "") }
            if name == "snippet" { snippet = Snippet(title: "", content: "") }
        }

        func parser(_ p: XMLParser, foundCharacters s: String) { text += s }

        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let parent = path.dropLast().last
            switch (name, parent) {
            case ("title", "folder"): folder?.title = text
            case ("title", "snippet"): snippet?.title = text
            case ("content", "snippet"): snippet?.content = text
            case ("snippet", _): if let s = snippet { folder?.snippets.append(s) }; snippet = nil
            case ("folder", _): if let f = folder { folders.append(f) }; folder = nil
            default: break
            }
            path.removeLast()
            text = ""
        }
    }
}
