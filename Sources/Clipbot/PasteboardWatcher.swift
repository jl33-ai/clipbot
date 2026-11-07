import AppKit
import ClipbotCore

/// Polls the general pasteboard (macOS has no change notification) and records allowed clips.
/// Order: own-write check → ClipGate (secure input → metadata filter → read → secret patterns) →
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

        // One snapshot of the items: the types checked are the types read.
        let items = pb.pasteboardItems ?? []
        let result = ClipGate.evaluate(items: items, secureInput: SecureInput.isOn, sourceBundleIDs: sources, filter: filter())
        noteSecureInput(result == .dropped(.secureInput))
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
            } catch {
                Log.app.error("clip store failed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    /// Warns once per launch when secure input keeps blocking recording (stuck, or an app with
    /// "Secure Keyboard Entry" always on).
    private func noteSecureInput(_ dropped: Bool) {
        secureInputDrops = dropped ? secureInputDrops + 1 : 0
        guard secureInputDrops >= 3, !warnedSecureInput else { return }
        warnedSecureInput = true
        onSecureInputStuck?(SecureInput.holder())
    }
}
