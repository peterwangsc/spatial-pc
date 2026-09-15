import Testing
import Foundation
@testable import XRCore

@MainActor private final class FakeSession {
    var wasCancelledOnReturn = false
    var connectCalls = 0
    var disconnectCalls = 0
    var pending: CheckedContinuation<Void, Error>?
    var holdDisconnect = false
    var pendingDisconnect: CheckedContinuation<Void, Never>?
    func connect() async throws {
        connectCalls += 1
        try await withCheckedThrowingContinuation { pending = $0 }
        wasCancelledOnReturn = Task.isCancelled
    }
    func disconnect() async {
        disconnectCalls += 1
        if holdDisconnect { await withCheckedContinuation { pendingDisconnect = $0 } }
    }
    func complete() { pending?.resume(); pending = nil }
    func fail() { pending?.resume(throwing: CancellationError()); pending = nil }
}

@MainActor private func eventually(_ condition: () -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(2)
    while !condition() {
        if ContinuousClock.now >= end { throw CancellationError() }
        await Task.yield()
    }
}

@Suite @MainActor struct XRConnectionGateTests {
    @Test func doubleConnectAndNormalStop() async throws {
        let gate = XRConnectionGate(), session = FakeSession()
        var endings = 0
        let accepted1 = gate.begin(connect: session.connect, disconnect: session.disconnect, ended: { endings += 1 })
        #expect(accepted1)
        let accepted2 = gate.begin(connect: session.connect, disconnect: session.disconnect, ended: {})
        #expect(!accepted2)
        try await eventually { session.pending != nil }
        session.complete()
        try await eventually { gate.phase == .connected }
        #expect(session.connectCalls == 1)
        gate.stop()
        try await eventually { !gate.busy }
        #expect(session.disconnectCalls == 1 && endings == 1)
        gate.stop()
        #expect(endings == 1)
    }

    @Test func cancellationThenLateSuccessRequiresAnotherDisconnect() async throws {
        let gate = XRConnectionGate(), session = FakeSession()
        var endings = 0
        gate.begin(connect: session.connect, disconnect: session.disconnect, ended: { endings += 1 })
        try await eventually { session.pending != nil }
        gate.stop()
        try await eventually { session.disconnectCalls == 1 }
        #expect(gate.busy && endings == 0)
        let accepted3 = gate.begin(connect: session.connect, disconnect: session.disconnect, ended: {})
        #expect(!accepted3)
        session.complete() // Simulate OS connection ignoring task cancellation.
        try await eventually { !gate.busy }
        #expect(session.disconnectCalls == 2 && endings == 1)
    }

    @Test func lateSuccessDuringDisconnectCannotEscapeCleanup() async throws {
        let gate = XRConnectionGate(), session = FakeSession()
        session.holdDisconnect = true
        gate.begin(connect: session.connect, disconnect: session.disconnect, ended: {})
        try await eventually { session.pending != nil }
        gate.stop()
        try await eventually { session.pendingDisconnect != nil }
        session.complete()
        // Let the pending connect continuation execute before releasing cleanup.
        for _ in 0..<20 { await Task.yield() }
        session.holdDisconnect = false
        session.pendingDisconnect?.resume(); session.pendingDisconnect = nil
        try await eventually { !gate.busy }
        #expect(session.disconnectCalls == 2)
    }

    @Test func failedConnectCleansUpAndAllowsManualRetry() async throws {
        let gate = XRConnectionGate(), session = FakeSession()
        var endings = 0
        gate.begin(connect: session.connect, disconnect: session.disconnect, ended: { endings += 1 })
        try await eventually { session.pending != nil }
        session.fail()
        try await eventually { !gate.busy }
        #expect(gate.error != nil && session.disconnectCalls == 1 && endings == 1)
        let accepted4 = gate.begin(connect: session.connect, disconnect: session.disconnect, ended: { endings += 1 })
        #expect(accepted4)
        try await eventually { session.pending != nil }
        #expect(gate.error == nil)
        gate.stop(); session.fail()
        try await eventually { !gate.busy }
        #expect(endings == 2)
    }

    @Test func terminalStatusDuringConnectDoesNotCancelItsContinuation() async throws {
        let gate = XRConnectionGate(), session = FakeSession()
        var endings = 0
        gate.begin(connect:session.connect,disconnect:session.disconnect,ended:{ endings += 1 })
        try await eventually { session.pending != nil }
        gate.sessionDisconnected()
        for _ in 0..<10 { await Task.yield() }
        #expect(gate.phase == .connecting && session.disconnectCalls == 0)
        session.fail()
        try await eventually { !gate.busy }
        #expect(endings == 1 && session.disconnectCalls == 1)
    }

    @Test func explicitStopDisconnectsWithoutCancelingSystemConnect() async throws {
        let gate = XRConnectionGate(), session = FakeSession()
        var endings = 0
        gate.begin(connect:{
            try await XRSystemConnection.connect(while:{ gate.phase == .connecting },operation:session.connect)
        },disconnect:session.disconnect,ended:{ endings += 1 })
        try await eventually { session.pending != nil }
        gate.stop()
        try await eventually { session.disconnectCalls == 1 }
        #expect(gate.busy && endings == 0)
        session.complete()
        try await eventually { !gate.busy }
        #expect(!session.wasCancelledOnReturn)
        #expect(session.disconnectCalls == 2 && endings == 1)
    }

    @Test func canceledAdmissionDoesNotStartSystemConnect() async throws {
        let session = FakeSession()
        do {
            try await XRSystemConnection.connect(while:{ false },operation:session.connect)
            Issue.record("Rejected system connection began")
        } catch is CancellationError {} catch { Issue.record("Unexpected error") }
        #expect(session.connectCalls == 0)
    }

    @Test func terminalStatusAfterConnectedCleansUp() async throws {
        let gate = XRConnectionGate(), session = FakeSession()
        gate.begin(connect:session.connect,disconnect:session.disconnect,ended:{})
        try await eventually { session.pending != nil };session.complete()
        try await eventually { gate.phase == .connected }
        gate.sessionDisconnected()
        try await eventually { !gate.busy }
        #expect(session.disconnectCalls == 1)
    }

    @Test func timeoutRetainsBusyUntilOSCallReturns() async throws {
        let gate = XRConnectionGate(), session = FakeSession()
        var endings = 0
        gate.begin(timeout: .milliseconds(5), connect: session.connect,
                   disconnect: session.disconnect, ended: { endings += 1 })
        try await eventually { session.pending != nil && session.disconnectCalls == 1 }
        #expect(gate.phase == .stopping && gate.error != nil && endings == 0)
        let accepted5 = gate.begin(connect: session.connect, disconnect: session.disconnect, ended: {})
        #expect(!accepted5)
        session.fail()
        try await eventually { !gate.busy }
        #expect(endings == 1)
    }
}
