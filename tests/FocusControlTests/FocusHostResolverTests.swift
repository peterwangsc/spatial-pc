import Foundation
import Darwin
import Testing
@testable import FocusControlCore

@MainActor private final class FakeFocusDNS: FocusDNSService {
    var starts = 0
    var stops = 0
    var resolved: (@MainActor ([Data]) -> Void)?
    var failed: (@MainActor (Int) -> Void)?
    func start(resolved: @escaping @MainActor ([Data]) -> Void, failed: @escaping @MainActor (Int) -> Void) {
        starts += 1; self.resolved = resolved; self.failed = failed
    }
    func stop() { stops += 1 }
}

private func ipv4Record(_ text: String, port: UInt16 = 47991) -> Data {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    _ = inet_pton(AF_INET, text, &address.sin_addr)
    return withUnsafeBytes(of: address) { Data($0) }
}

private func ipv6Record(_ text: String, scope: UInt32) -> Data {
    var address = sockaddr_in6()
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    address.sin6_family = sa_family_t(AF_INET6)
    address.sin6_port = UInt16(47991).bigEndian
    address.sin6_scope_id = scope
    _ = inet_pton(AF_INET6, text, &address.sin6_addr)
    return withUnsafeBytes(of: address) { Data($0) }
}

@MainActor private func resolverEventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition() {
        if ContinuousClock.now >= deadline { throw CancellationError() }
        await Task.yield()
    }
}

@Suite @MainActor struct FocusHostResolverTests {
    @Test func manualAddressesDoNotStartDNS() async throws {
        var created = 0
        let resolver = FocusHostResolver { _, _ in created += 1; return FakeFocusDNS() }
        #expect(try await resolver.resolve(address: " 192.168.86.20 ", serviceName: nil, serviceDomain: nil) == ["192.168.86.20"])
        #expect(try await resolver.resolve(address: "[2001:db8::1]", serviceName: nil, serviceDomain: nil) == ["2001:db8::1"])
        #expect(try await resolver.resolve(address: "fe80::1%4", serviceName: nil, serviceDomain: nil) == ["fe80::1%4"])
        #expect(created == 0)
    }

    @Test func invalidManualInputNeverFallsBackToBonjour() async {
        var created = 0
        let resolver = FocusHostResolver { _, _ in created += 1; return FakeFocusDNS() }
        for input in ["pc.local", "https://192.168.1.2", "192.168.1.2:47991", "[::1]:47994", "fe80::1", "fe80::1%", "::", "0.0.0.0", "224.0.0.1", "ff02::1", "::1\0extra"] {
            await #expect(throws: FocusHostResolutionError.invalidAddress) {
                try await resolver.resolve(address: input, serviceName: "PC", serviceDomain: "local.")
            }
        }
        #expect(created == 0)
    }

    @Test func sockaddrAnswersStripAdvertisedPortsAndPreserveScope() {
        let records = [ipv4Record("192.168.1.2"), ipv4Record("192.168.1.2", port: 1234), ipv6Record("fe80::abcd", scope: 7), ipv6Record("2001:db8::2", scope: 0), Data([1]), Data(repeating: 0, count: 128), ipv6Record("fe80::1", scope: 0)]
        #expect(FocusHostResolver.addresses(from: records) == ["192.168.1.2", "fe80::abcd%7", "2001:db8::2"])
        #expect(FocusHostResolver.addresses(from: (1...20).map { ipv4Record("192.168.1.\($0)") }).count == 8)
    }

    @Test func serviceResolutionUsesOnlyAnswerAddressesAndCleansUp() async throws {
        let dns = FakeFocusDNS()
        var seen: [String] = []
        let resolver = FocusHostResolver { name, domain in seen = [name, domain]; return dns }
        let task = Task { try await resolver.resolve(address: "", serviceName: "Gaming PC", serviceDomain: "local.") }
        try await resolverEventually { dns.starts == 1 }
        dns.resolved?([ipv4Record("192.168.1.2")])
        #expect(try await task.value == ["192.168.1.2"])
        #expect(seen == ["Gaming PC", "local."])
        #expect(FocusHostResolver.serviceType == "_spatialpc._tcp.")
        #expect(dns.stops == 1)
        dns.failed?(-1) // A late callback cannot resume an already completed caller.
        #expect(dns.stops == 1)
    }

    @Test func cancellationStopsResolutionAndIgnoresLateAnswer() async throws {
        let dns = FakeFocusDNS()
        let resolver = FocusHostResolver { _, _ in dns }
        let task = Task { try await resolver.resolve(address: "", serviceName: "PC", serviceDomain: "local.") }
        try await resolverEventually { dns.starts == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(dns.stops == 1)
        dns.resolved?([ipv4Record("192.168.1.2")])
        #expect(dns.stops == 1)
    }

    @Test func timeoutStopsResolutionWithoutAnAnswer() async {
        let dns = FakeFocusDNS()
        let resolver = FocusHostResolver(timeout: .milliseconds(5)) { _, _ in dns }
        await #expect(throws: FocusHostResolutionError.timedOut) {
            try await resolver.resolve(address: "", serviceName: "PC", serviceDomain: "local.")
        }
        #expect(dns.starts == 1 && dns.stops == 1)
    }

    @Test func malformedAnswerAndDNSFailureCleanUp() async throws {
        for failure in [false, true] {
            let dns = FakeFocusDNS()
            let resolver = FocusHostResolver { _, _ in dns }
            let task = Task { try await resolver.resolve(address: "", serviceName: "PC", serviceDomain: "local.") }
            try await resolverEventually { dns.starts == 1 }
            if failure { dns.failed?(-72000) } else { dns.resolved?([Data([0])]) }
            await #expect(throws: failure ? FocusHostResolutionError.dnsFailure(-72000) : .noAddresses) { try await task.value }
            #expect(dns.stops == 1)
        }
    }
}
