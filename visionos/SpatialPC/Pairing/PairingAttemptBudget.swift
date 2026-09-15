import Foundation

/// Independent of untrusted host/window/discovery fields and view lifetime.
/// Cancel, failure, retyping, and changing servers never refund an exposure.
struct PairingAttemptBudget {
    enum Failure: Error { case exhausted }
    private var began: TimeInterval?
    private var used = 0
    mutating func consume(now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        if began == nil || now - began! >= 180 {
            began = now
            used = 0
        }
        guard used < 3 else { throw Failure.exhausted }
        used += 1
    }
    mutating func completed() { began = nil; used = 0 }
}
