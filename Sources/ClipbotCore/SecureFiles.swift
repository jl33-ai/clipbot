import Foundation

public enum SecureFiles {
    /// Creates (or repairs) a 0700 directory excluded from Time Machine.
    public static func ensureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try u.setResourceValues(values)
    }

    /// Writes to a 0600 temp file in the same directory, then renames over the target.
    public static func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let h = try FileHandle(forWritingTo: tmp)
            try h.write(contentsOf: data)
            try h.synchronize()
            try h.close()
            if rename(tmp.path, url.path) != 0 { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Moves the named entries of `dir` into a new `Unreadable-<yyyy-MM-dd>[-n]/` folder. Never deletes.
    @discardableResult
    public static func quarantine(_ names: [String], in dir: URL, date: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        let stem = "Unreadable-\(f.string(from: date))"
        var target = dir.appendingPathComponent(stem)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(stem)-\(n)")
            n += 1
        }
        try ensureDirectory(target)
        for name in names where fm.fileExists(atPath: dir.appendingPathComponent(name).path) {
            try fm.moveItem(at: dir.appendingPathComponent(name), to: target.appendingPathComponent(name))
        }
        return target
    }
}
