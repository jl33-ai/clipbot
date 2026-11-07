import AppKit
import Carbon.HIToolbox
import ClipbotCore
import IOKit

/// Polls the general pasteboard (macOS has no change notification) and records allowed clips.
/// Order: own-write check → secure input → ClipGate (metadata filter → read → secret patterns) →
/// re-check changeCount (nothing changed mid-read) → store.
@MainActor
final class PasteboardWatcher {
    private let pb = NSPasteboard.general
    private let store: HistoryStore
    private let filter: () -> SecretFilter
    private var tracker: ChangeTracker
    private var timer: Timer?
    /// Every app that was frontmost since the last processed change — the copy came from one of them.
    private var sources: Set<String> = []
    private var activationObserver: NSObjectProtocol?
    private var secureInputDrops = 0
    private var warnedSecureInput = false

    var onChange: (() -> Void)?
    /// Called once per launch when secure input keeps blocking recording. Argument: holder app name.
    var onSecureInputStuck: ((String?) -> Void)?

    init(store: HistoryStore, filter: @escaping () -> SecretFilter) {
        self.store = store
        self.filter = filter
        tracker = ChangeTracker(initial: NSPasteboard.general.changeCount)
    }

    func start() {
        resetSources()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { if let id { self?.sources.insert(id) } }
        }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func noteOwnWrite() { tracker.noteOwnWrite(pb.changeCount) }

    private func resetSources() {
        sources = Set([NSWorkspace.shared.frontmostApplication?.bundleIdentifier].compactMap { $0 })
    }

    private func tick() {
        let count = pb.changeCount
        guard tracker.observe(count) else { return }
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier { sources.insert(front) }
        defer { resetSources() }

        // A password field has keyboard focus somewhere: never record.
        if IsSecureEventInputEnabled() {
            Log.app.info("clip dropped: secure input")
            secureInputDrops += 1
            if secureInputDrops >= 3, !warnedSecureInput {
                warnedSecureInput = true
                onSecureInputStuck?(Self.secureInputHolder())
            }
            return
        }
        secureInputDrops = 0

        // One snapshot of the items: the types checked are the types read.
        let items = pb.pasteboardItems ?? []
        let result = ClipGate.evaluate(items: items, sourceBundleIDs: sources, filter: filter())
        guard pb.changeCount == count else {
            Log.app.info("clip dropped: pasteboard changed during read")
            return
        }
        switch result {
        case .dropped(let reason):
            Log.app.info("clip dropped: \(String(describing: reason), privacy: .public)")
        case .skipped:
            Log.app.info("clip skipped: empty, unsupported or too large")
        case .record(let clip):
            do {
                try store.add(clip.payload, kind: clip.kind, preview: clip.preview, thumbnail: clip.thumbnail)
                Log.app.info("clip recorded: \(clip.kind.rawValue, privacy: .public), history=\(self.store.entries.count, privacy: .public)")
                onChange?()
            } catch {
                Log.app.error("clip store failed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    /// Best effort: the app holding secure keyboard input, from the IORegistry console session.
    static func secureInputHolder() -> String? {
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

    static var secureInputOn: Bool { IsSecureEventInputEnabled() }
}
