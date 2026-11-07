import AppKit

/// The complete record-or-drop decision for one pasteboard change, in the order that keeps secrets
/// from ever being read: marker types and source apps (metadata) first, then data, then patterns.
/// Secure-input and changeCount checks happen in the app before this is called.
public enum ClipGate {
    public enum Result: Equatable, Sendable {
        case record(CapturedClip)
        case dropped(SecretFilter.Reason)
        case skipped
    }

    public static func evaluate(items: [NSPasteboardItem], sourceBundleIDs: Set<String>, filter: SecretFilter) -> Result {
        let types = items.flatMap { $0.types.map(\.rawValue) }
        if let reason = filter.dropReason(types: types, sourceBundleIDs: sourceBundleIDs) { return .dropped(reason) }
        guard let clip = ClipCapture.capture(items: items) else { return .skipped }
        // Every text form in the payload, whichever kind won (an image or PDF can carry text too).
        if ClipCapture.allText(clip).contains(where: SecretFilter.looksLikeSecret) { return .dropped(.secretPattern) }
        return .record(clip)
    }
}
