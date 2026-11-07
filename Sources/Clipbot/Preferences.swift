import ClipbotCore
import Foundation

/// Non-secret settings only (UserDefaults). Clip and snippet content never goes here.
@MainActor
final class Preferences: ObservableObject {
    private let d = UserDefaults.standard

    @Published var mainShortcut: Shortcut { didSet { save(mainShortcut, "shortcut.main") } }
    @Published var historyShortcut: Shortcut { didSet { save(historyShortcut, "shortcut.history") } }
    @Published var snippetsShortcut: Shortcut { didSet { save(snippetsShortcut, "shortcut.snippets") } }
    @Published var ignoredBundleIDs: [String] { didSet { d.set(ignoredBundleIDs, forKey: "ignoredBundleIDs") } }

    var hasConfiguredLoginItem: Bool {
        get { d.bool(forKey: "didConfigureLoginItem") }
        set { d.set(newValue, forKey: "didConfigureLoginItem") }
    }
    var hasPromptedAccessibility: Bool {
        get { d.bool(forKey: "didPromptAccessibility") }
        set { d.set(newValue, forKey: "didPromptAccessibility") }
    }
    /// Shortcuts that failed to register (taken by another app or each other). Not persisted.
    @Published var shortcutConflicts: Set<String> = []
    var hasShownAccessibilityHelp: Bool {
        get { d.bool(forKey: "didShowAccessibilityHelp") }
        set { d.set(newValue, forKey: "didShowAccessibilityHelp") }
    }

    init() {
        let d = UserDefaults.standard
        func load(_ key: String, _ fallback: Shortcut) -> Shortcut {
            d.data(forKey: key).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? fallback
        }
        mainShortcut = load("shortcut.main", .mainDefault)
        historyShortcut = load("shortcut.history", .historyDefault)
        snippetsShortcut = load("shortcut.snippets", .snippetsDefault)
        ignoredBundleIDs = d.stringArray(forKey: "ignoredBundleIDs") ?? SecretFilter.defaultIgnoredBundleIDs.sorted()
    }

    var filter: SecretFilter { SecretFilter(ignoredBundleIDs: Set(ignoredBundleIDs)) }

    private func save(_ s: Shortcut, _ key: String) {
        d.set(try? JSONEncoder().encode(s), forKey: key)
    }
}
