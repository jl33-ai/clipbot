// SPIKE (Task 1): verifies a sandboxed app can synthesise ⌘V. Replaced in Task 7.
import AppKit
import ApplicationServices

let app = NSApplication.shared
let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(opts)
FileHandle.standardError.write("spike: AX trusted=\(trusted)\n".data(using: .utf8)!)
DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString("clipbot-spike", forType: .string)
    let src = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
    down?.flags = .maskCommand; up?.flags = .maskCommand
    down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
    FileHandle.standardError.write("spike: posted cmd-V, AX trusted=\(AXIsProcessTrusted())\n".data(using: .utf8)!)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
}
app.run()
