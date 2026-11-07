import Foundation

/// Tracks `NSPasteboard.changeCount` so Clipbot never records its own writes.
public struct ChangeTracker: Sendable {
    private var last: Int
    public init(initial: Int) { last = initial }

    /// True when `count` is a new change made by someone else.
    public mutating func observe(_ count: Int) -> Bool {
        guard count != last else { return false }
        last = count
        return true
    }

    /// Call with the pasteboard's changeCount right after Clipbot writes to it.
    public mutating func noteOwnWrite(_ count: Int) { last = count }
}
