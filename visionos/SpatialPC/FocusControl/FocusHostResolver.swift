import Foundation
import Network
import Darwin

enum FocusHostResolutionError: Error, Equatable {
    case invalidAddress
    case missingService
    case invalidService
    case noAddresses
    case timedOut
    case dnsFailure(Int)
}

/// Resolves addresses only. It never connects to the advertised desktop port.
/// The caller must use the resulting addresses with its fixed control port.
@MainActor final class FocusHostResolver {
    static let serviceType = "_spatialpc._tcp."
    static let maximumCandidates = 8
    private let makeService: (String, String) -> any FocusDNSService
    private let timeout: Duration

    init() {
        makeService = { name, domain in FoundationFocusDNSService(name: name, domain: domain) }
        timeout = .seconds(5)
    }

    // Deterministic tests supply DNS answers without browsing or opening a socket.
    init(timeout: Duration = .seconds(5), makeService: @escaping (String, String) -> any FocusDNSService) {
        self.timeout = timeout
        self.makeService = makeService
    }

    func resolve(address: String, serviceName: String?, serviceDomain: String?) async throws -> [String] {
        try Task.checkCancellation()
        let manual = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return [try Self.numericAddress(manual)] }
        guard let name = serviceName, let domain = serviceDomain else {
            throw FocusHostResolutionError.missingService
        }
        guard !name.isEmpty, name.utf8.count <= 63, !name.contains("\0"),
              !domain.isEmpty, domain.utf8.count <= 253, !domain.contains("\0"),
              !domain.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw FocusHostResolutionError.invalidService
        }
        let operation = FocusDNSResolution(service: makeService(name, domain), timeout: timeout)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await operation.run()
        } onCancel: {
            Task { @MainActor in operation.cancel() }
        }
    }

    /// Numeric literals only: no hostnames, embedded port, URL, or DNS fallback.
    static func numericAddress(_ input: String) throws -> String {
        guard !input.isEmpty, input.utf8.count <= 128, !input.contains("\0") else {
            throw FocusHostResolutionError.invalidAddress
        }
        var literal = input
        if literal.first == "[", literal.last == "]" {
            literal.removeFirst(); literal.removeLast()
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, literal, &v4) == 1 {
            guard v4.s_addr != 0, (UInt32(bigEndian: v4.s_addr) & 0xf0000000) != 0xe0000000,
                  v4.s_addr != UInt32.max else { throw FocusHostResolutionError.invalidAddress }
            return render(AF_INET, &v4)
        }
        let pieces = literal.split(separator: "%", omittingEmptySubsequences: false)
        guard pieces.count <= 2, let first = pieces.first else { throw FocusHostResolutionError.invalidAddress }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, String(first), &v6) == 1 else { throw FocusHostResolutionError.invalidAddress }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        guard bytes.contains(where: { $0 != 0 }), bytes[0] != 0xff else { throw FocusHostResolutionError.invalidAddress }
        let linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
        var zone: String?
        if pieces.count == 2 {
            let supplied = String(pieces[1])
            guard !supplied.isEmpty, supplied.utf8.count < Int(IF_NAMESIZE) else { throw FocusHostResolutionError.invalidAddress }
            if let index = UInt32(supplied), index > 0 { zone = String(index) }
            else if supplied.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 }),
                    if_nametoindex(supplied) != 0 { zone = supplied }
            else { throw FocusHostResolutionError.invalidAddress }
        }
        guard !linkLocal || zone != nil else { throw FocusHostResolutionError.invalidAddress }
        let rendered = render(AF_INET6, &v6)
        return zone.map { rendered + "%" + $0 } ?? rendered
    }

    static func addresses(from records: [Data]) -> [String] {
        var candidates: [String] = []
        // NetService returns a finite answer set. Bound parsing as well as output.
        for record in records.prefix(64) {
            guard record.count >= 2 else { continue }
            let family = record[record.startIndex + 1]
            let candidate: String?
            if family == UInt8(AF_INET), record.count >= MemoryLayout<sockaddr_in>.size {
                var value = record.withUnsafeBytes { $0.loadUnaligned(as: sockaddr_in.self) }
                guard value.sin_len >= MemoryLayout<sockaddr_in>.size else { continue }
                candidate = try? numericAddress(render(AF_INET, &value.sin_addr))
            } else if family == UInt8(AF_INET6), record.count >= MemoryLayout<sockaddr_in6>.size {
                var value = record.withUnsafeBytes { $0.loadUnaligned(as: sockaddr_in6.self) }
                guard value.sin6_len >= MemoryLayout<sockaddr_in6>.size else { continue }
                let suffix = value.sin6_scope_id == 0 ? "" : "%\(value.sin6_scope_id)"
                candidate = try? numericAddress(render(AF_INET6, &value.sin6_addr) + suffix)
            } else { candidate = nil }
            if let candidate, !candidates.contains(candidate) { candidates.append(candidate) }
            if candidates.count == maximumCandidates { break }
        }
        return candidates
    }

    private static func render<T>(_ family: Int32, _ address: inout T) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let result = withUnsafePointer(to: &address) { inet_ntop(family, $0, &buffer, socklen_t(buffer.count)) }
        guard result != nil else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

@MainActor protocol FocusDNSService: AnyObject {
    func start(resolved: @escaping @MainActor ([Data]) -> Void, failed: @escaping @MainActor (Int) -> Void)
    func stop()
}

/// NetService resolution requests SRV/address records only. No getInputStream,
/// getOutputStream, NWConnection, or socket connect is used.
@MainActor private final class FoundationFocusDNSService: NSObject, FocusDNSService, @preconcurrency NetServiceDelegate {
    private let service: NetService
    private var resolved: (@MainActor ([Data]) -> Void)?
    private var failed: (@MainActor (Int) -> Void)?

    init(name: String, domain: String) {
        service = NetService(domain: domain, type: FocusHostResolver.serviceType, name: name)
        super.init()
    }
    func start(resolved: @escaping @MainActor ([Data]) -> Void, failed: @escaping @MainActor (Int) -> Void) {
        self.resolved = resolved; self.failed = failed
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 5)
    }
    func stop() {
        service.delegate = nil
        service.stop()
        service.remove(from: .main, forMode: .common)
        service.remove(from: .main, forMode: .default)
        resolved = nil; failed = nil
    }
    func netServiceDidResolveAddress(_ sender: NetService) { resolved?(sender.addresses ?? []) }
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        failed?(errorDict[NetService.errorCode]?.intValue ?? -1)
    }
}

@MainActor private final class FocusDNSResolution {
    private let service: any FocusDNSService
    private let timeout: Duration
    private var continuation: CheckedContinuation<[String], Error>?
    private var timer: Task<Void, Never>?
    private var completed = false

    init(service: any FocusDNSService, timeout: Duration) { self.service = service; self.timeout = timeout }
    func run() async throws -> [String] {
        if completed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timer = Task { [weak self, timeout] in
                do { try await Task.sleep(for: timeout) } catch { return }
                self?.finish(.failure(FocusHostResolutionError.timedOut))
            }
            service.start { [weak self] records in
                let addresses = FocusHostResolver.addresses(from: records)
                self?.finish(addresses.isEmpty ? .failure(FocusHostResolutionError.noAddresses) : .success(addresses))
            } failed: { [weak self] code in
                self?.finish(.failure(FocusHostResolutionError.dnsFailure(code)))
            }
        }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<[String], Error>) {
        guard !completed else { return }
        completed = true
        timer?.cancel(); timer = nil
        service.stop()
        let pending = continuation; continuation = nil
        pending?.resume(with: result)
    }
}
