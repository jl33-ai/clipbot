// Adapted from Maccy's FloatingPanel and PopupPosition (https://github.com/p0deje/Maccy),
// MIT License, Copyright (c) 2025 Alex Rodionov. See docs/licenses/Maccy.txt.
import AppKit

/// A floating panel that takes keyboard focus without activating Clipbot, so the app you were in
/// stays in front and the pick pastes straight into it. Closes when it loses focus.
final class PopupPanel: NSPanel {
    /// Called when the panel closed because it lost focus (outside click, another app came forward).
    var onResignKey: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: PopupLayout.width, height: 300),
                   styleMask: [.nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        animationBehavior = .none
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isRestorable = false // never let window state be saved
        acceptsMouseMovedEvents = true
    }

    // Lets the search field take focus in a non-activating panel.
    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        if isVisible { onResignKey?() }
    }

    /// Rounded corners on the hosting view and its frame view, as Maccy does.
    func setContent(_ view: NSView) {
        contentView = view
        for v in [contentView, contentView?.superview].compactMap({ $0 }) {
            v.wantsLayer = true
            v.layer?.cornerRadius = PopupLayout.windowCornerRadius
            v.layer?.cornerCurve = .continuous
            v.layer?.masksToBounds = true
        }
    }

    /// Opens at the mouse cursor, or under the menu bar icon, kept on that screen.
    func open(height: CGFloat, below anchor: NSStatusBarButton?) {
        let size = NSSize(width: PopupLayout.width, height: height)
        setContentSize(size)
        setFrameOrigin(Self.origin(size: frame.size, below: anchor))
        orderFrontRegardless()
        makeKey()
    }

    /// Changes the height while keeping the top edge where it is.
    func setHeight(_ height: CGFloat) {
        guard abs(frame.height - height) > 0.5 else { return }
        var f = frame
        f.origin.y += f.height - height
        f.size.height = height
        setFrame(f, display: true)
    }

    private static func origin(size: NSSize, below anchor: NSStatusBarButton?) -> NSPoint {
        if let anchor, let window = anchor.window {
            let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            return constrained(NSPoint(x: rect.minX, y: rect.minY - size.height), size: size, to: window.screen ?? NSScreen.main)
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        return constrained(NSPoint(x: mouse.x, y: mouse.y - size.height), size: size, to: screen)
    }

    /// Keeps the panel from spilling onto an adjacent screen.
    private static func constrained(_ origin: NSPoint, size: NSSize, to screen: NSScreen?) -> NSPoint {
        guard let f = screen?.visibleFrame else { return origin }
        return NSPoint(x: min(max(origin.x, f.minX), f.maxX - size.width),
                       y: min(max(origin.y, f.minY), f.maxY - size.height))
    }
}
