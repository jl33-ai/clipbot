import AppKit

/// Every modal dialog in Clipbot.
@MainActor
enum Alert {
    /// Shows the alert and returns true when the first button was chosen.
    @discardableResult
    static func run(_ title: String, _ detail: String? = nil, buttons: [String] = [], destructive: Bool = false) -> Bool {
        let a = NSAlert()
        a.messageText = title
        if let detail { a.informativeText = detail }
        for b in buttons { a.addButton(withTitle: b) }
        if destructive { a.buttons.first?.hasDestructiveAction = true }
        NSApp.activate()
        return a.runModal() == .alertFirstButtonReturn
    }
}
