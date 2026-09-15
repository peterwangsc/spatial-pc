// Synthetic record-assembly microbenchmark, not network or headset latency.
// swiftc -O StreamWire.swift ExactStreamReader.swift ReceiveBufferBenchmark.swift -o /tmp/receive-bench
import Foundation
@main struct ReceiveBufferBenchmark {
    @inline(never) static func baseline(_ size:Int,next:(Int) async throws -> Data) async throws -> Data {
        var result = Data(); result.reserveCapacity(size)
        while result.count < size { result.append(try await next(size-result.count)) }
        return result
    }
    @inline(never) static func candidate(_ size:Int,next:(Int) async throws -> Data) async throws -> Data {
        var buffer = try ExactStreamReader(size)
        while buffer.remaining > 0 { try buffer.append(await next(buffer.remaining)) }
        return buffer.data
    }
    static func main() async throws {
        var reports = [[String:Any]]()
        for size in [16_384,65_536,262_144,1_048_576] {
            var payload = Data(repeating:0xA5,count:size)
            payload[0] = UInt8(truncatingIfNeeded:ProcessInfo.processInfo.processIdentifier)
            for fragmented in [false,true] {
                let pieces = fragmented ? [Data(payload.prefix(size/2)),Data(payload.suffix(size/2))] : [payload]
                for mode in ["baseline","candidate","candidate","baseline"] {
                    var checksum = 0, matchingStorage = 0
                    let iterations = 2_000
                    let begin = ContinuousClock.now
                    for _ in 0..<iterations {
                        var index = 0
                        let next:(Int) async throws -> Data = { count in
                            let value = pieces[index]; index += 1
                            precondition(value.count <= count); return value
                        }
                        let data = try await (mode == "baseline" ? baseline(size,next:next) : candidate(size,next:next))
                        precondition(data.count == size)
                        checksum += Int(data.first!) + Int(data.last!)
                        payload.withUnsafeBytes { original in data.withUnsafeBytes { result in
                            if original.baseAddress == result.baseAddress { matchingStorage += 1 }
                        }}
                    }
                    let elapsed = begin.duration(to:.now).components
                    let ns = Double(elapsed.seconds)*1e9+Double(elapsed.attoseconds)/1e9
                    reports.append(["mode":mode,"bytes":size,"fragments":pieces.count,"iterations":iterations,
                        "meanAssemblyMicroseconds":ns/Double(iterations)/1000,"sourceStorageReused":matchingStorage,"checksum":checksum])
                }
            }
        }
        let report:[String:Any] = ["boundary":"Synthetic Mac Data assembly, including async callback overhead; no sockets, decode, or headset. Pointer identity observes this Foundation build only.","runs":reports]
        print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]),encoding:.utf8)!)
    }
}
