import AppKit

/// What a key press in the popup does. Keys not listed here go to the search box.
public enum PopupCommand: Equatable, Sendable {
    case moveDown, moveUp, moveToFirst, moveToLast
    case paste
    /// ⌘1…⌘9, ⌘0: paste the row with that number (0-based).
    case pasteRow(Int)
    case escape
    case deleteItem
    case clearHistory
    case settings
    case quit
}

/// Maccy's popup keys, by physical key code so they work on every keyboard layout.
public enum PopupKeys {
    enum Code {
        static let returnKey: UInt16 = 36, keypadEnter: UInt16 = 76, escape: UInt16 = 53, delete: UInt16 = 51
        static let up: UInt16 = 126, down: UInt16 = 125
        static let n: UInt16 = 45, p: UInt16 = 35, comma: UInt16 = 43, q: UInt16 = 12
        /// The number row, 1…9 then 0.
        static let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
    }

    public static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> PopupCommand? {
        // Arrow keys also carry .numericPad and .function, and Caps Lock adds .capsLock: only the
        // four modifiers a person chooses count.
        let m = modifiers.intersection([.command, .option, .control, .shift])
        switch (keyCode, m) {
        case (Code.down, []), (Code.n, .control): return .moveDown
        case (Code.up, []), (Code.p, .control): return .moveUp
        case (Code.up, .command): return .moveToFirst
        case (Code.down, .command): return .moveToLast
        case (Code.returnKey, _), (Code.keypadEnter, _): return .paste
        case (Code.escape, []): return .escape
        case (Code.delete, .option): return .deleteItem
        case (Code.delete, [.option, .command]): return .clearHistory
        case (Code.comma, .command): return .settings
        case (Code.q, .command): return .quit
        case (_, .command):
            return Code.digits.firstIndex(of: keyCode).map(PopupCommand.pasteRow)
        default:
            return nil
        }
    }
}
