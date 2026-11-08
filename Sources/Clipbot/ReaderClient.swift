import ClipbotCore
import Foundation

/// Talks to the isolated ClipReader helper. Dclip never reads clipboard data itself.
/// If the helper hangs, crashes or doesn't answer in time, the copy is dropped and the connection
/// is thrown away; launchd starts a fresh helper on the next request.
@MainActor
final class ReaderClient {
    /// Backstop only. The helper kills itself after 2 s on a hung read, but launchd can take ~10 s to
    /// start its replacement after that; waiting this long means the next copy isn't lost.
    static let timeout: TimeInterval = 15

    enum Outcome { case response(ReadResponse), failed(String) }

    private let serviceName = (Bundle.main.bundleIdentifier ?? "io.linus.clipbot") + ".ClipReader"
    private var connection: NSXPCConnection?
    private var pending: [UUID: (Outcome) -> Void] = [:]

    func read(_ request: ReadRequest, completion: @escaping (Outcome) -> Void) {
        guard let body = try? request.encoded() else { completion(.failed("encode")); return }
        let id = UUID()
        pending[id] = completion
        let conn = currentConnection()
        let token = ObjectIdentifier(conn)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            MainActor.assumeIsolated { self?.finish(id, .failed("timed out"), drop: token) }
        }
        // XPC calls these on its own queue: they must not inherit this class's main-actor isolation.
        let proxy = conn.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
            let code = (error as NSError).code
            Task { @MainActor in self?.finish(id, .failed("helper exited (\(code))"), drop: token) }
        } as? ClipReading
        guard let proxy else { finish(id, .failed("no proxy"), drop: token); return }
        proxy.read(body) { @Sendable [weak self] data in
            let decoded = data.flatMap { try? ReadResponse.decode($0) }
            Task { @MainActor in self?.finish(id, decoded.map(Outcome.response) ?? .failed("bad response"), drop: nil) }
        }
    }

    /// Completes a request once; a failure also discards the connection so the next read gets a
    /// fresh helper process.
    private func finish(_ id: UUID, _ outcome: Outcome, drop: ObjectIdentifier?) {
        guard let completion = pending.removeValue(forKey: id) else { return }
        if case .failed = outcome, let drop, let c = connection, ObjectIdentifier(c) == drop {
            c.invalidate()
            connection = nil
        }
        completion(outcome)
    }

    private func currentConnection() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(serviceName: serviceName)
        c.remoteObjectInterface = NSXPCInterface(with: ClipReading.self)
        let token = ObjectIdentifier(c)
        let forget: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                if let self, let current = self.connection, ObjectIdentifier(current) == token { self.connection = nil }
            }
        }
        c.interruptionHandler = forget
        c.invalidationHandler = forget
        c.resume()
        connection = c
        return c
    }
}
