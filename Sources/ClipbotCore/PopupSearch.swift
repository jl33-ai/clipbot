import Foundation

/// How the popup's search box matches: every word of the query must appear somewhere in the
/// item's text, in any order, ignoring case, accents and character width. Words are literal
/// (no regex or fuzzy matching), so ".*" finds a literal ".*".
public enum PopupSearch {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    public static func words(_ query: String) -> [Substring] {
        query.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
    }

    public static func matches(_ query: String, in text: String) -> Bool {
        words(query).allSatisfy { text.range(of: $0, options: options) != nil }
    }

    /// Where the query's words appear in a title, for bolding: the first occurrence of each word,
    /// sorted and merged where they overlap.
    public static func ranges(of query: String, in title: String) -> [Range<String.Index>] {
        let found = words(query).compactMap { title.range(of: $0, options: options) }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for r in found {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// Longest text kept per clip for searching (it lives in the encrypted index).
    public static let maxTextLength = 2_000

    /// The text a clip is searched by: its text forms, capped.
    public static func text(_ parts: [String]) -> String {
        String(parts.joined(separator: "\n").prefix(maxTextLength))
    }
}
