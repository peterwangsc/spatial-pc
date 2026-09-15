import Foundation

/// Bounded record assembly without an extra async layer around the receive loop.
/// A complete first delivery keeps the framework's Data storage. Only fragmented
/// records allocate an assembly buffer; callers still request exactly remaining.
struct ExactStreamReader {
    enum Failure: Error { case ended }
    private let size:Int
    private(set) var data = Data()
    var remaining:Int { size-data.count }
    init(_ size:Int) throws {
        guard (1...StreamWire.maximumFrameBytes).contains(size) else { throw StreamWire.Invalid.length }
        self.size = size
    }
    mutating func append(_ part:Data) throws {
        guard !part.isEmpty else { throw Failure.ended }
        guard part.count <= remaining else { throw StreamWire.Invalid.length }
        if data.isEmpty {
            data = part
            if remaining > 0 { data.reserveCapacity(size) }
        } else { data.append(part) }
    }
}
