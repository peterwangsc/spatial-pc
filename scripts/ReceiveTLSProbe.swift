// Synthetic loopback TLS receive validation; never connects to a real desktop.
import Foundation
import Network
import Security
@main struct ReceiveTLSProbe {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 5, let port = UInt16(arguments[1]), let count = Int(arguments[4]), (1...10_000).contains(count) else { throw StreamWire.Invalid.length }
        let candidate = arguments[3] == "candidate"
        let certificate = try Data(contentsOf:URL(fileURLWithPath:arguments[2]))
        let queue = DispatchQueue(label:"SpatialPC.synthetic-network-probe")
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions,.TLSv13)
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions,"localhost")
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions,"spatialpc-network-bench/1")
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions,{ _, value, complete in
            let trust = sec_trust_copy_ref(value).takeRetainedValue()
            guard let anchor = SecCertificateCreateWithData(nil,certificate as CFData) else { complete(false); return }
            SecTrustSetAnchorCertificates(trust,[anchor] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust,true)
            SecTrustSetPolicies(trust,SecPolicyCreateSSL(true,"localhost" as CFString))
            complete(SecTrustEvaluateWithError(trust,nil))
        },queue)
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = candidate
        let connection = NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!,using:NWParameters(tls:tls,tcp:tcp))
        defer { connection.cancel() }
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: connection.stateUpdateHandler = nil; continuation.resume()
                case .waiting(let error), .failed(let error): connection.stateUpdateHandler = nil; continuation.resume(throwing:error)
                default: break
                }
            }
            connection.start(queue:queue)
        }
        func part(_ size:Int) async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength:size,maximumLength:size) { data,_,_,error in
                    if let error { continuation.resume(throwing:error) }
                    else if let data,!data.isEmpty { continuation.resume(returning:data) }
                    else { continuation.resume(throwing:ExactStreamReader.Failure.ended) }
                }
            }
        }
        func exact(_ size:Int) async throws -> Data {
            if candidate {
                var buffer = try ExactStreamReader(size)
                while buffer.remaining > 0 { try buffer.append(await part(buffer.remaining)) }
                return buffer.data
            }
            var data = Data(); data.reserveCapacity(size)
            while data.count < size { data.append(try await part(size-data.count)) }
            return data
        }
        var waits = [Double](), bytes = 0
        let began = ContinuousClock.now
        for index in 0..<count {
            let header = try await exact(4)
            let size = Int(StreamWire.unsigned(header))
            guard (8...StreamWire.maximumFrameBytes).contains(size) else { throw StreamWire.Invalid.length }
            let before = ContinuousClock.now
            let data = try await exact(size)
            let elapsed = before.duration(to:.now).components
            waits.append(Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15)
            guard StreamWire.unsigned(Data(data.prefix(8))) == UInt64(index),data.last == 0xA5 else { throw StreamWire.Invalid.header }
            bytes += size
        }
        let elapsed = began.duration(to:.now).components
        let seconds = Double(elapsed.seconds)+Double(elapsed.attoseconds)/1e18
        waits.sort()
        let report:[String:Any] = ["mode":arguments[3],"frames":count,"bytes":bytes,"seconds":seconds,
            "receiveP50MS":waits[count/2],"receiveP95MS":waits[count*95/100],"receiveP99MS":waits[count*99/100],
            "tls":"1.3 minimum, private fixture CA and localhost name verified","tcpNoDelay":candidate,
            "boundary":"Mac synthetic loopback TLS, ordered bounded payloads; no H264, Windows input, Wi-Fi or headset latency"]
        print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),encoding:.utf8)!)
    }
}
