import Foundation
import Observation

/// Serializes a system-owned session, including cancellation racing connection.
/// A timeout requests shutdown; it never pretends an unreturned OS call finished.
@MainActor @Observable
final class XRConnectionGate {
    enum Phase: Equatable { case idle, connecting, connected, stopping }
    private(set) var phase = Phase.idle
    private(set) var error: String?
    var busy: Bool { phase != .idle }
    @ObservationIgnored private var connection: Task<Void, Never>?
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var disconnect: (@MainActor () async -> Void)?
    @ObservationIgnored private var ended: (@MainActor () -> Void)?
    private var mustDisconnectAgain = false

    @discardableResult
    func begin(timeout: Duration = .seconds(30),
               connect: @escaping @MainActor () async throws -> Void,
               disconnect: @escaping @MainActor () async -> Void,
               ended: @escaping @MainActor () -> Void) -> Bool {
        guard !busy else { return false }
        phase = .connecting; error = nil
        self.disconnect = disconnect; self.ended = ended
        connection = Task { [weak self] in
            do {
                try await connect()
                guard let self else { return }
                self.connection = nil
                self.deadline?.cancel(); self.deadline = nil
                if self.phase == .stopping {
                    // A successful late connect must be disconnected even if an
                    // earlier disconnect already returned while it was pending.
                    self.mustDisconnectAgain = true
                    self.startCleanup()
                } else { self.phase = .connected }
            } catch {
                guard let self else { return }
                self.connection = nil
                if self.phase != .stopping { self.error = "Could not connect to Immersive Mode." }
                self.stop()
            }
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.phase == .connecting else { return }
            self.error = "Immersive Mode connection timed out."
            self.stop()
        }
        return true
    }

    func stop() {
        guard busy else { return }
        phase = .stopping
        deadline?.cancel(); deadline = nil
        connection?.cancel()
        startCleanup()
    }

    private func startCleanup() {
        guard cleanup == nil, let disconnect else { return }
        mustDisconnectAgain = false
        cleanup = Task { [weak self] in
            await disconnect()
            guard let self else { return }
            self.cleanup = nil
            if self.mustDisconnectAgain { self.startCleanup(); return }
            guard self.connection == nil else { return }
            self.phase = .idle
            let ended = self.ended
            self.ended = nil; self.disconnect = nil
            ended?()
        }
    }
}
