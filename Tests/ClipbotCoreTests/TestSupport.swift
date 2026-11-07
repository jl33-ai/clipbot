import Foundation
@testable import ClipbotCore

func makeTempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("clipbot-tests-\(UUID().uuidString)")
}

func textPayload(_ s: String) -> ClipPayload {
    ClipPayload(representations: [ClipRepresentation(type: "public.utf8-plain-text", data: Data(s.utf8))])
}

/// Every byte of every file under `dir`, for "no plaintext on disk" checks.
func allFileBytes(under dir: URL) -> [(URL, Data)] {
    let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])!
    return e.compactMap { item in
        guard let u = item as? URL, (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return (u, (try? Data(contentsOf: u)) ?? Data())
    }
}
