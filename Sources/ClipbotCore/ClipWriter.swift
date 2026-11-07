import AppKit

/// Every pasteboard write Clipbot makes goes through here, marked current-host-only so
/// Universal Clipboard never syncs it to other devices.
public enum ClipWriter {
    static let contentsOptions: NSPasteboard.ContentsOptions = .currentHostOnly

    public static func write(_ payload: ClipPayload, to pb: NSPasteboard) {
        let fileType = NSPasteboard.PasteboardType.fileURL.rawValue
        var items: [NSPasteboardItem] = []
        let main = NSPasteboardItem()
        for rep in payload.representations {
            if rep.type == fileType {
                let item = NSPasteboardItem()
                item.setData(rep.data, forType: .fileURL)
                items.append(item)
            } else {
                main.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type))
            }
        }
        if !main.types.isEmpty { items.insert(main, at: 0) }
        pb.prepareForNewContents(with: contentsOptions)
        pb.writeObjects(items)
    }

    public static func writeText(_ text: String, to pb: NSPasteboard) {
        pb.prepareForNewContents(with: contentsOptions)
        pb.setString(text, forType: .string)
    }
}
