import Foundation

public enum MenuModel {
    /// Splits items into fixed slots: "1 - 10", "11 - 20", … (titled by slot range, not item count).
    public static func groups<T>(_ items: [T], size: Int = 10) -> [(title: String, items: [T])] {
        stride(from: 0, to: items.count, by: size).map { start in
            ("\(start + 1) - \(start + size)", Array(items[start..<min(start + size, items.count)]))
        }
    }

    /// "1"…"9", "0" for the ten items of a group, like Clipy.
    public static func keyEquivalent(forIndexInGroup i: Int) -> String {
        switch i {
        case 0..<9: String(i + 1)
        case 9: "0"
        default: ""
        }
    }

    /// One line, whitespace runs collapsed, at most `limit` characters (graphemes) + "…".
    public static func previewText(_ s: String, limit: Int = 60) -> String {
        let collapsed = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }
}
