import AppKit

/// Everything Dclip and its isolated `ClipReader` helper exchange. The helper is the only process
/// that reads clipboard data: macOS's own type converters (RTF, PDF, images) run in whichever
/// process asks for a converted type, and some of them hang on hostile input. Isolating them means
/// a bad copy can only take down the helper, never Dclip.

/// The XPC interface. Requests and responses are JSON-encoded `ReadRequest` / `ReadResponse`.
@objc public protocol ClipReading {
    func read(_ request: Data, reply: @escaping @Sendable (Data?) -> Void)
}

public struct ReadRequest: Codable, Equatable, Sendable {
    /// The change Dclip saw; the helper refuses to read if the clipboard has moved on.
    public let changeCount: Int
    public let secureInput: Bool
    public let sourceBundleIDs: [String]
    public let ignoredBundleIDs: [String]

    public init(changeCount: Int, secureInput: Bool, sourceBundleIDs: [String], ignoredBundleIDs: [String]) {
        self.changeCount = changeCount
        self.secureInput = secureInput
        self.sourceBundleIDs = sourceBundleIDs
        self.ignoredBundleIDs = ignoredBundleIDs
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ d: Data) throws -> ReadRequest { try JSONDecoder().decode(ReadRequest.self, from: d) }
}

public struct ReadResponse: Codable, Equatable, Sendable {
    /// nil when the clipboard changed before or during the read.
    public let result: ClipGate.Result?
    public var changed: Bool { result == nil }

    public init(result: ClipGate.Result?) { self.result = result }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ d: Data) throws -> ReadResponse { try JSONDecoder().decode(ReadResponse.self, from: d) }
}

public enum ClipReaderCore {
    /// The helper's whole job for one change.
    public static func handle(_ req: ReadRequest, pasteboard pb: NSPasteboard) -> ReadResponse {
        guard pb.changeCount == req.changeCount else { return ReadResponse(result: nil) }
        let items = pb.pasteboardItems ?? []
        let result = ClipGate.evaluate(items: items, secureInput: req.secureInput,
                                       sourceBundleIDs: Set(req.sourceBundleIDs),
                                       filter: SecretFilter(ignoredBundleIDs: Set(req.ignoredBundleIDs)))
        // Changed mid-read: the data may not match the types that were checked.
        guard pb.changeCount == req.changeCount else { return ReadResponse(result: nil) }
        return ReadResponse(result: result)
    }
}

/// Runs `onTimeout` on its own queue if not disarmed in time — independent of whatever thread is
/// stuck. The helper uses it to exit when a system parser never returns.
public final class Watchdog: @unchecked Sendable {
    private let timeout: TimeInterval
    private let onTimeout: @Sendable () -> Void
    private let queue = DispatchQueue(label: "io.linus.clipbot.watchdog")
    private var generation = 0
    private var armedGeneration: Int?

    public init(timeout: TimeInterval, onTimeout: @escaping @Sendable () -> Void) {
        self.timeout = timeout
        self.onTimeout = onTimeout
    }

    public func arm() {
        queue.sync {
            generation += 1
            let g = generation
            armedGeneration = g
            queue.asyncAfter(deadline: .now() + timeout) { [self] in
                if armedGeneration == g { onTimeout() }
            }
        }
    }

    public func disarm() { queue.sync { armedGeneration = nil } }
}
