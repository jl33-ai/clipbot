import ClipbotCore
import Foundation

/// Non-secret settings only (UserDefaults). Clip and snippet content never goes here.
@MainActor
final class Preferences: ObservableObject {
    private let d = UserDefaults.standard

    @Published var shortcuts: [ShortcutSlot: Shortcut] {
        didSet { for (slot, s) in shortcuts where oldValue[slot] != s { d.set(try? JSONEncoder().encode(s), forKey: slot.defaultsKey) } }
    }
    @Published var ignoredBundleIDs: [String] { didSet { d.set(ignoredBundleIDs, forKey: "ignoredBundleIDs") } }
    @Published var showMenuBarIcon: Bool { didSet { d.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }

    var hasConfiguredLoginItem: Bool {
        get { d.bool(forKey: "didConfigureLoginItem") }
        set { d.set(newValue, forKey: "didConfigureLoginItem") }
    }
    /// Where the app was when launch at login was last registered.
    var loginItemPath: String? {
        get { d.string(forKey: "loginItemPath") }
        set { d.set(newValue, forKey: "loginItemPath") }
    }
    var hasPromptedAccessibility: Bool {
        get { d.bool(forKey: "didPromptAccessibility") }
        set { d.set(newValue, forKey: "didPromptAccessibility") }
    }
    var hasShownAccessibilityHelp: Bool {
        get { d.bool(forKey: "didShowAccessibilityHelp") }
        set { d.set(newValue, forKey: "didShowAccessibilityHelp") }
    }

    init() {
        let d = UserDefaults.standard
        shortcuts = Dictionary(uniqueKeysWithValues: ShortcutSlot.allCases.map { slot in
            (slot, d.data(forKey: slot.defaultsKey).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? slot.defaultValue)
        })
        ignoredBundleIDs = d.stringArray(forKey: "ignoredBundleIDs") ?? SecretFilter.defaultIgnoredBundleIDs.sorted()
        showMenuBarIcon = d.object(forKey: "showMenuBarIcon") as? Bool ?? true
    }

    var filter: SecretFilter { SecretFilter(ignoredBundleIDs: Set(ignoredBundleIDs)) }

}
