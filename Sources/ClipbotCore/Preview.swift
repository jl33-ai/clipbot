import Foundation

/// One-line display text for menu items.
public enum Preview {
    /// One line, whitespace runs collapsed, invisible control/format characters (bidi overrides,
    /// zero-width, NUL) removed, at most `limit` graphemes + "…". Scans only as far as it needs.
    public static func text(_ s: String, limit: Int = 60) -> String {
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
