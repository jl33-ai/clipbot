import AppKit
import Carbon.HIToolbox
import IOKit

/// Secure keyboard input: on while any password field (or "Secure Keyboard Entry") holds focus.
enum SecureInput {
    static var isOn: Bool { IsSecureEventInputEnabled() }

    /// Best effort: the app holding it, from the IORegistry console session.
    static func holder() -> String? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]] else { return nil }
        for u in users {
            if let pid = u["kCGSSessionSecureInputPID"] as? Int32, pid > 0 {
                return NSRunningApplication(processIdentifier: pid)?.localizedName
            }
        }
        return nil
    }
}
