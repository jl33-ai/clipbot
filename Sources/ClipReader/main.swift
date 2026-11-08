// ClipReader: Dclip's isolated clipboard reader (XPC service).
//
// The only process that touches untrusted clipboard data. It reads the general pasteboard, runs
// the full record-or-drop gate (marker types, ignored apps, secret patterns), builds previews and
// thumbnails, and returns a checked result. Any system parser that hangs or crashes takes down
// only this process: the watchdog exits it, launchd starts a fresh one on the next request, and
// Dclip drops that one copy.
import AppKit
import ClipbotCore

/// How long one read may take before this process gives up on itself.
let readDeadline: TimeInterval = 2

final class Reader: NSObject, ClipReading {
    private let watchdog = Watchdog(timeout: readDeadline) {
        // A parser never returned. Exit now; the stuck thread can't be stopped any other way.
        // _exit, not exit: atexit/teardown handlers can block behind the stuck thread.
        _exit(EXIT_SUCCESS)
    }

    func read(_ request: Data, reply: @escaping @Sendable (Data?) -> Void) {
        guard let req = try? ReadRequest.decode(request) else { reply(nil); return }
        let watchdog = self.watchdog
        DispatchQueue.main.async {
            watchdog.arm()
            let response = ClipReaderCore.handle(req, pasteboard: .general)
            watchdog.disarm()
            reply(try? response.encoded())
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let reader = Reader()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // Only Dclip itself may connect: same team, same app.
        guard c.processIdentifier > 0 else { return false }
        c.setCodeSigningRequirement(Self.requirement)
        c.exportedInterface = NSXPCInterface(with: ClipReading.self)
        c.exportedObject = reader
        c.resume()
        return true
    }

    /// The connecting app must be signed by this helper's own team with a Dclip bundle id.
    static let requirement: String = {
        var code: SecCode?
        var info: CFDictionary?
        SecCodeCopySelf([], &code)
        var staticCode: SecStaticCode?
        if let code { SecCodeCopyStaticCode(code, [], &staticCode) }
        if let staticCode { SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) }
        let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String ?? "none"
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (identifier \"io.linus.clipbot\" or identifier \"io.linus.clipbot.debug\")"
    }()
}

let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
