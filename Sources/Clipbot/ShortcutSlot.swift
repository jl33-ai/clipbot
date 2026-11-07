import ClipbotCore

/// The three global shortcuts, in one table: what each opens, its default, and where it's saved.
enum ShortcutSlot: UInt32, CaseIterable, Identifiable {
    case main = 1, history, snippets

    var id: UInt32 { rawValue }

    var title: String {
        switch self {
        case .main: "History & snippets"
        case .history: "History only"
        case .snippets: "Snippets only"
        }
    }

    var defaultValue: Shortcut {
        switch self {
        case .main: .mainDefault
        case .history: .historyDefault
        case .snippets: .snippetsDefault
        }
    }

    var menuMode: MenuMode {
        switch self {
        case .main: .all
        case .history: .history
        case .snippets: .snippets
        }
    }

    /// UserDefaults key (unchanged from the first release).
    var defaultsKey: String { "shortcut.\(self)" }
}
