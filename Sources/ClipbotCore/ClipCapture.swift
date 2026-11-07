import AppKit

public struct CapturedClip: Sendable, Equatable {
    public let payload: ClipPayload
    public let kind: ClipKind
    public let preview: String
    public let thumbnail: Data?
    /// Full text of the clip (plain, URL, or extracted from RTF/RTFD), for secret checks. Not stored.
    public var text: String? = nil
}

/// Turns the current pasteboard contents into a clip. Call only after `SecretFilter` has passed
/// on the pasteboard's types — this reads data.
public enum ClipCapture {
    /// Clipy's stored types: string, RTF, RTFD, PDF, images (TIFF/PNG), file names, URL.
    public static let storedTypes: [NSPasteboard.PasteboardType] = [.string, .rtf, .rtfd, .pdf, .tiff, .png, .URL]
    public static let maxBytes = 20 * 1024 * 1024
    static let thumbnailPixels = 64

    public static func capture(from pb: NSPasteboard) -> CapturedClip? {
        capture(items: pb.pasteboardItems ?? [])
    }

    /// Reads from exactly these item objects, so the data matches the types that were checked.
    public static func capture(items: [NSPasteboardItem]) -> CapturedClip? {
        guard let first = items.first else { return nil }
        var reps: [ClipRepresentation] = []
        var total = 0

        func take(_ type: NSPasteboard.PasteboardType, from item: NSPasteboardItem) -> Bool {
            guard let data = item.data(forType: type) else { return true }
            total += data.count
            guard total <= maxBytes else { return false }
            reps.append(ClipRepresentation(type: type.rawValue, data: data))
            return true
        }

        // Every file URL (multi-file copies put one per item); other types from the first item.
        let fileItems = items.filter { $0.types.contains(.fileURL) }
        for item in fileItems { guard take(.fileURL, from: item) else { return nil } }
        if fileItems.isEmpty {
            for type in storedTypes where first.types.contains(type) {
                guard take(type, from: first) else { return nil }
            }
        }
        guard !reps.isEmpty else { return nil }
        let payload = ClipPayload(representations: reps)
        let has = Set(reps.map(\.type))
        func string(_ t: NSPasteboard.PasteboardType) -> String? {
            reps.first { $0.type == t.rawValue }.flatMap { String(data: $0.data, encoding: .utf8) }
        }

        if !fileItems.isEmpty {
            let names = reps.compactMap { URL(dataRepresentation: $0.data, relativeTo: nil)?.lastPathComponent }
            guard let name = names.first else { return nil }
            let preview = names.count > 1 ? "\(name) + \(names.count - 1) more" : name
            return CapturedClip(payload: payload, kind: .file, preview: MenuModel.previewText(preview), thumbnail: nil)
        }
        if let imgRep = reps.first(where: { $0.type == NSPasteboard.PasteboardType.png.rawValue || $0.type == NSPasteboard.PasteboardType.tiff.rawValue }),
           let image = NSImage(data: imgRep.data) {
            let px = image.representations.first.map { "\($0.pixelsWide)×\($0.pixelsHigh)" } ?? ""
            return CapturedClip(payload: payload, kind: .image, preview: px.isEmpty ? "Image" : "Image \(px)", thumbnail: thumbnail(image))
        }
        if has.contains(NSPasteboard.PasteboardType.pdf.rawValue), !has.contains(NSPasteboard.PasteboardType.string.rawValue) {
            return CapturedClip(payload: payload, kind: .pdf, preview: "PDF document", thumbnail: nil)
        }
        if let url = string(.URL), string(.string).map({ $0 == url }) ?? true {
            return CapturedClip(payload: payload, kind: .url, preview: MenuModel.previewText(url), thumbnail: nil, text: url)
        }
        var text = string(.string)
        if text == nil, let rtf = reps.first(where: { $0.type == NSPasteboard.PasteboardType.rtf.rawValue }) {
            text = NSAttributedString(rtf: rtf.data, documentAttributes: nil)?.string
        }
        if text == nil, let rtfd = reps.first(where: { $0.type == NSPasteboard.PasteboardType.rtfd.rawValue }) {
            text = NSAttributedString(rtfd: rtfd.data, documentAttributes: nil)?.string
        }
        let preview = MenuModel.previewText(text ?? "")
        if preview.isEmpty {
            // Whitespace-only text with nothing else worth keeping.
            if has.contains(NSPasteboard.PasteboardType.pdf.rawValue) {
                return CapturedClip(payload: payload, kind: .pdf, preview: "PDF document", thumbnail: nil)
            }
            return nil
        }
        let rich = has.contains(NSPasteboard.PasteboardType.rtf.rawValue) || has.contains(NSPasteboard.PasteboardType.rtfd.rawValue)
        return CapturedClip(payload: payload, kind: rich ? .richText : .text, preview: preview, thumbnail: nil, text: text)
    }

    /// PNG no larger than 64 px on its long edge (32 pt @2x).
    static func thumbnail(_ image: NSImage) -> Data? {
        guard let src = image.representations.first, src.pixelsWide > 0, src.pixelsHigh > 0 else { return nil }
        let scale = min(1, Double(thumbnailPixels) / Double(max(src.pixelsWide, src.pixelsHigh)))
        let w = max(1, Int(Double(src.pixelsWide) * scale)), h = max(1, Int(Double(src.pixelsHigh) * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
