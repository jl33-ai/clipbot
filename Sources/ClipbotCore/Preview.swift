import Foundation

/// One-line display text for menu items.
public enum Preview {
    /// One line, whitespace runs collapsed, invisible control/format characters (bidi overrides,
    /// zero-width, NUL) removed, at most `limit` graphemes + "…". Scans only as far as it needs.
    public static func text(_ s: String, limit: Int = 60) -> String {
        var out = ""
        var count = 0
        var pendingSpace = false
        for raw in s {
            if raw.isWhitespace || raw.isNewline {
                pendingSpace = count > 0
                continue
            }
            // Strip invisible scalars from inside each character too (they can attach to a
            // visible one), keeping only the joiner that emoji sequences need.
            let kept = raw.unicodeScalars.filter { $0 == "\u{200D}" || !isInvisible($0) }
            guard kept.contains(where: { $0 != "\u{200D}" }) else { continue }
            if pendingSpace {
                if count == limit { return out + "…" }
                out.append(" "); count += 1; pendingSpace = false
            }
            if count == limit { return out + "…" }
            out.unicodeScalars.append(contentsOf: kept); count += 1
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
