// Compile with StreamWire.swift and H264Decoder.swift. Reads SPC1 from stdin;
// reports timing only and never writes decoded pixels.
import Foundation
@main struct DecodeProbe {
    static func exact(_ count: Int) throws -> Data {
        var data = Data(); data.reserveCapacity(count)
        while data.count < count {
            guard let more = try FileHandle.standardInput.read(upToCount:count-data.count), !more.isEmpty else {
                throw CocoaError(.fileReadUnknown)
            }
            data.append(more)
        }
        return data
    }
    static func main() throws {
        let count = Int(CommandLine.arguments.dropFirst().first ?? "120") ?? 120
        guard (1...100_000).contains(count) else { throw CocoaError(.coderInvalidValue) }
        let length = try StreamWire.helloLength(exact(8))
        let caps = try StreamWire.capabilities(exact(length))
        let decoder = H264Decoder(width:caps.width,height:caps.height)
        var times = [Double](); var intervals = [Double](); var drift = [Double]()
        let start = ContinuousClock.now
        var firstArrival: ContinuousClock.Instant?, previousArrival: ContinuousClock.Instant?, firstTimestamp: Int64?
        func milliseconds(_ duration: Duration) -> Double {
            let value = duration.components
            return Double(value.seconds)*1000+Double(value.attoseconds)/1e15
        }
        for _ in 0..<count {
            let header = try StreamWire.frameHeader(exact(16))
            let payload = try exact(header.length)
            let arrival = ContinuousClock.now
            if let previousArrival { intervals.append(milliseconds(previousArrival.duration(to:arrival))) }
            if firstArrival == nil { firstArrival = arrival; firstTimestamp = header.timestamp }
            drift.append(milliseconds(firstArrival!.duration(to:arrival)) - (Double(header.timestamp)-Double(firstTimestamp!))/10000)
            previousArrival = arrival
            if let frame = try decoder.decode(payload,timestamp:header.timestamp) { times.append(frame.decodeMS) }
        }
        guard !times.isEmpty else { throw CocoaError(.coderReadCorrupt) }
        times.sort()
        let elapsed = start.duration(to:.now).components
        let seconds = Double(elapsed.seconds)+Double(elapsed.attoseconds)/1e18
        func summary(_ samples: [Double]) -> [String:Any] {
            guard !samples.isEmpty else { return ["count":0] }
            let ordered = samples.sorted()
            return ["count":ordered.count,"p50":ordered[ordered.count/2],"p95":ordered[min(ordered.count-1,ordered.count*95/100)],
                    "p99":ordered[min(ordered.count-1,ordered.count*99/100)],"min":ordered.first!,"max":ordered.last!]
        }
        let output: [String:Any] = ["decoded":times.count,"hardware":decoder.hardware,"elapsedSeconds":seconds,
            "decodeP50MS":times[times.count/2],"decodeP95MS":times[min(times.count-1,times.count*95/100)],
            "decodeP99MS":times[min(times.count-1,times.count*99/100)],"width":caps.width,"height":caps.height,
            "arrivalIntervalMS":summary(intervals),"relativeArrivalTimelineDriftMS":summary(drift),
            "boundary":"local receive plus decode; not headset display latency",
            "driftBoundary":"relative to first payload arrival and host timestamp; includes sender, network and pipe scheduling; not absolute one-way latency"]
        print(String(data:try JSONSerialization.data(withJSONObject:output,options:.sortedKeys),encoding:.utf8)!)
    }
}
