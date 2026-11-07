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

    /// One line, whitespace runs collapsed, invisible control/format characters (bidi overrides,
    /// zero-width, NUL) removed, at most `limit` graphemes + "…". Scans only as far as it needs.
    public static func previewText(_ s: String, limit: Int = 60) -> String {
        var out = ""
        var count = 0
        var pendingSpace = false
        for ch in s {
            if ch.isWhitespace || ch.isNewline {
                pendingSpace = count > 0
                continue
            }
            if ch.unicodeScalars.allSatisfy({ isInvisible($0) }) { continue }
            if pendingSpace {
                if count == limit { return out + "…" }
                out.append(" "); count += 1; pendingSpace = false
            }
            if count == limit { return out + "…" }
            out.append(ch); count += 1
        }
        return out
    }

    private static func isInvisible(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .control, .format, .unassigned, .privateUse, .surrogate, .lineSeparator, .paragraphSeparator: true
        default: false
        }
    }
}
