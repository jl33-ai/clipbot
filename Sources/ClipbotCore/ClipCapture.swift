import AppKit
import ImageIO

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
           let size = imagePixelSize(imgRep.data) {
            return CapturedClip(payload: payload, kind: .image, preview: "Image \(size.width)×\(size.height)",
                                thumbnail: thumbnail(fromImageData: imgRep.data))
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

    /// Every text form in a clip: plain string, URL, and text extracted from RTF/RTFD.
    public static func allText(_ clip: CapturedClip) -> [String] {
        var out = clip.text.map { [$0] } ?? []
        for rep in clip.payload.representations {
            switch NSPasteboard.PasteboardType(rep.type) {
            case .string, .URL: if let s = String(data: rep.data, encoding: .utf8) { out.append(s) }
            case .rtf: if let s = NSAttributedString(rtf: rep.data, documentAttributes: nil)?.string { out.append(s) }
            case .rtfd: if let s = NSAttributedString(rtfd: rep.data, documentAttributes: nil)?.string { out.append(s) }
            default: break
            }
        }
        return out
    }

    /// Images declaring more pixels than this get no thumbnail (they'd need GBs to decode).
    static let maxThumbnailSourcePixels = 100_000_000

    /// Pixel size from the image header, without decoding the image.
    static func imagePixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// PNG no larger than 64 px on its long edge (32 pt @2x), made by ImageIO's downsampler so the
    /// full image is never decoded. nil for images whose declared size is unreasonable.
    public static func thumbnail(fromImageData data: Data) -> Data? {
        guard let size = imagePixelSize(data), size.width * size.height <= maxThumbnailSourcePixels,
              let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
