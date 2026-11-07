import AppKit
import Carbon.HIToolbox
import ClipbotCore

/// Polls the general pasteboard (macOS has no change notification) and records allowed clips.
/// Order: own-write check → secure input → metadata filter → read data → secret patterns → store.
@MainActor
final class PasteboardWatcher {
    private let pb = NSPasteboard.general
    private let store: HistoryStore
    private let filter: () -> SecretFilter
    private var tracker: ChangeTracker
    private var timer: Timer?
    var onChange: (() -> Void)?

    init(store: HistoryStore, filter: @escaping () -> SecretFilter) {
        self.store = store
        self.filter = filter
        tracker = ChangeTracker(initial: NSPasteboard.general.changeCount)
    }

    func start() {
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func noteOwnWrite() { tracker.noteOwnWrite(pb.changeCount) }

    private func tick() {
        guard tracker.observe(pb.changeCount) else { return }
        // A password field has keyboard focus somewhere: never record.
        if IsSecureEventInputEnabled() { Log.app.info("clip dropped: secure input"); return }
        let types = pb.types?.map(\.rawValue) ?? []
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if filter().shouldDropBeforeRead(types: types, frontmostBundleID: front) { Log.app.info("clip dropped: marker type or ignored app"); return }
        guard let clip = ClipCapture.capture(from: pb) else { Log.app.info("clip skipped: empty, unsupported or too large"); return }
        if containsSecretText(clip.payload) { Log.app.info("clip dropped: secret pattern"); return }
        do {
            try store.add(clip.payload, kind: clip.kind, preview: clip.preview, thumbnail: clip.thumbnail)
            Log.app.info("clip recorded: \(clip.kind.rawValue, privacy: .public), history=\(self.store.entries.count, privacy: .public)")
        } catch {
            Log.app.error("clip store failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        onChange?()
    }

    private func containsSecretText(_ payload: ClipPayload) -> Bool {
        let textTypes: Set<String> = [NSPasteboard.PasteboardType.string.rawValue, NSPasteboard.PasteboardType.URL.rawValue]
        return payload.representations.contains { rep in
            textTypes.contains(rep.type) && String(data: rep.data, encoding: .utf8).map(SecretFilter.looksLikeSecret) == true
        }
    }
}
