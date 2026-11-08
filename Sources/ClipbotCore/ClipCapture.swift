import AppKit
import ImageIO

public struct CapturedClip: Sendable, Equatable {
    public let payload: ClipPayload
    public let kind: ClipKind
    public let preview: String
    public let thumbnail: Data?
    /// Every text form of the clip (plain, URL, extracted from RTF/RTFD), each extracted once.
    /// Used for secret checks; never stored.
    public let texts: [String]
}

/// Turns pasteboard items into a clip. Call only after `SecretFilter` has passed on the items'
/// types — this reads data.
public enum ClipCapture {
    /// Clipy's stored types: string, RTF, RTFD, PDF, images (TIFF/PNG), file names, URL.
    public static let storedTypes: [NSPasteboard.PasteboardType] = [.string, .rtf, .rtfd, .pdf, .tiff, .png, .URL]
    public static let maxBytes = 20 * 1024 * 1024
    static let thumbnailPixels = 64

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
        let byType = Dictionary(reps.map { (NSPasteboard.PasteboardType($0.type), $0.data) }, uniquingKeysWith: { a, _ in a })
        let plain = byType[.string].flatMap { String(data: $0, encoding: .utf8) }
        let url = byType[.URL].flatMap { String(data: $0, encoding: .utf8) }
        let rich = byType[.rtf].flatMap { NSAttributedString(rtf: $0, documentAttributes: nil)?.string }
        // RTFD is never parsed: AppKit's RTFD reader raises an Objective-C exception on malformed
        // data (uncatchable in Swift — one bad copy would crash Clipbot). Its text can't be checked
        // for secrets, so a copy whose only text is RTFD is not recorded (fail closed).
        if byType[.rtfd] != nil, plain == nil, rich == nil { return nil }
        var texts: [String] = []
        for t in [plain, url, rich].compactMap({ $0 }) where !texts.contains(t) { texts.append(t) }

        func clip(_ kind: ClipKind, _ preview: String, thumbnail: Data? = nil) -> CapturedClip {
            CapturedClip(payload: payload, kind: kind, preview: preview, thumbnail: thumbnail, texts: texts)
        }

        if !fileItems.isEmpty {
            let names = reps.compactMap { URL(dataRepresentation: $0.data, relativeTo: nil)?.lastPathComponent }
            guard let name = names.first else { return nil }
            return clip(.file, Preview.text(names.count > 1 ? "\(name) + \(names.count - 1) more" : name))
        }
        if let image = byType[.png] ?? byType[.tiff], let size = imagePixelSize(image) {
            return clip(.image, "Image \(size.width)×\(size.height)", thumbnail: thumbnail(fromImageData: image))
        }
        let hasPDF = byType[.pdf] != nil
        if hasPDF, plain == nil { return clip(.pdf, "PDF document") }
        if let url, plain.map({ $0 == url }) ?? true { return clip(.url, Preview.text(url)) }

        let preview = Preview.text(plain ?? rich ?? "")
        // Whitespace-only text with nothing else worth keeping.
        if preview.isEmpty { return hasPDF ? clip(.pdf, "PDF document") : nil }
        let isRich = byType[.rtf] != nil || byType[.rtfd] != nil
        return clip(isRich ? .richText : .text, preview)
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
