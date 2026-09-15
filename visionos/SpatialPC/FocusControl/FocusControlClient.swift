import Foundation
import Network
import Security
import CryptoKit

/// One authenticated, non-resumable control connection. Desktop and Apple
/// protocols never share this reader or its request IDs.
@MainActor final class FocusControlClient {
    enum Failure: Error { case unavailable, authentication, protocolViolation, timeout, closed, rejected(String) }
    struct Credentials {
        let root: Data
        let certificate: Data
        let serverName: String
        let identity: sec_identity_t
    }
    private struct Pending {
        let operation: String
        let continuation: CheckedContinuation<Data, Error>
        let deadline: Task<Void,Never>
    }
    var onProgress: ((String) -> Void)?
    var onFailure: (() -> Void)?
    private(set) var address: String = ""
    private(set) var connected = false
    private var connection: NWConnection?
    private var pending: [Int:Pending] = [:]
    private var origins: [Int:String] = [:]
    private var nextID = 1
    private var generation = UUID()
    private var ready: CheckedContinuation<Void,Error>?
    private var reader: Task<Void,Never>?
    private var heartbeat: Task<Void,Never>?
    private var startupDeadline: Task<Void,Never>?

    func connect(host: SavedHost) async throws {
        let candidates = try await FocusHostResolver().resolve(address:host.address,serviceName:host.serviceName,serviceDomain:host.serviceDomain)
        try Task.checkCancellation()
        guard let address = candidates.first else { throw Failure.unavailable }
        // One explicit attempt. Never fail over after TLS/authentication failure.
        try await connect(address:address,credentials:Credentials(root:host.caCertificate,certificate:host.serverCertificate,
            serverName:host.serverName,identity:try DeviceKeychain.identity(for:host)))
    }

    func connect(address: String, credentials: Credentials, port: UInt16 = 47994) async throws {
        guard connection == nil, let endpointPort = NWEndpoint.Port(rawValue:port),
              let root = SecCertificateCreateWithData(nil,credentials.root as CFData) else { throw Failure.authentication }
        try Task.checkCancellation()
        generation = UUID(); let token = generation
        self.address = address; nextID = 1; origins.removeAll()
        let tls = NWProtocolTLS.Options(), tcp = NWProtocolTCP.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options,.TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options,.TLSv13)
        sec_protocol_options_set_tls_tickets_enabled(options,false)
        sec_protocol_options_set_local_identity(options,credentials.identity)
        sec_protocol_options_set_tls_server_name(options,credentials.serverName)
        sec_protocol_options_add_tls_application_protocol(options,"spatialpc-control/1")
        sec_protocol_options_set_verify_block(options,{ _,wrappedTrust,complete in
            let trust = sec_trust_copy_ref(wrappedTrust).takeRetainedValue()
            guard SecTrustSetAnchorCertificates(trust,[root] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust,true) == errSecSuccess,
                  SecTrustSetPolicies(trust,SecPolicyCreateSSL(true,credentials.serverName as CFString)) == errSecSuccess,
                  SecTrustEvaluateWithError(trust,nil),
                  let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
                  SecCertificateCopyData(leaf) as Data == credentials.certificate else { complete(false); return }
            complete(true)
        },.main)
        tcp.noDelay = true
        let connection = NWConnection(to:.hostPort(host:.init(address),port:endpointPort),using:NWParameters(tls:tls,tcp:tcp))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self,self.generation == token else { return }
                switch state {
                case .ready:
                    guard !self.connected else { return }
                    guard let metadata = connection.metadata(definition:NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
                          let negotiated = sec_protocol_metadata_get_negotiated_protocol(metadata.securityProtocolMetadata),
                          String(cString:negotiated) == "spatialpc-control/1" else { self.fail(Failure.authentication); return }
                    self.connected = true
                    self.startupDeadline?.cancel(); self.startupDeadline = nil
                    let ready = self.ready; self.ready = nil; ready?.resume()
                    self.reader = Task { [weak self] in await self?.readLoop(connection,token:token) }
                    self.heartbeat = Task { [weak self] in
                        while !Task.isCancelled {
                            do {
                                try await Task.sleep(for:.seconds(5))
                                guard let self,self.generation == token else { return }
                                _ = try await self.request("heartbeat",timeout:8)
                            } catch { return }
                        }
                    }
                case .failed: self.fail(Failure.unavailable)
                case .cancelled: self.fail(Failure.closed)
                default: break
                }
            }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                startupDeadline = Task { [weak self] in
                    do { try await Task.sleep(for:.seconds(6)) } catch { return }
                    guard let self,self.generation == token else { return }; self.fail(Failure.timeout)
                }
                connection.start(queue:.main)
            }
        } onCancel: { Task { @MainActor [weak self] in
            guard let self,self.generation == token else { return }; self.close()
        } }
    }

    func request(_ operation: String, parameters: [String:Any] = [:], timeout: Double = 8) async throws -> [String:Any] {
        guard connected,let connection,pending.count < 8,nextID <= 4096 else { throw Failure.closed }
        try Task.checkCancellation()
        let id = nextID
        let data = try FocusControlWire.request(id:id,operation:operation,parameters:parameters)
        nextID += 1
        if operation == "focus.prepare" || operation == "focus.requestPermission" {
            origins[id] = operation
            if origins.count > 8,let oldest = origins.keys.min() { origins.removeValue(forKey:oldest) }
        }
        let token = generation
        let payload:Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for:.seconds(timeout)) } catch { return }
                    guard let self,self.generation == token,self.pending[id] != nil else { return }
                    self.fail(Failure.timeout)
                }
                pending[id] = Pending(operation:operation,continuation:continuation,deadline:deadline)
                connection.send(content:data,completion:.contentProcessed { [weak self] error in
                    if error != nil { Task { @MainActor in
                        guard let self,self.generation == token else { return }; self.fail(Failure.unavailable)
                    } }
                })
            }
        } onCancel: { Task { @MainActor [weak self] in
            guard let self,self.generation == token else { return }; self.close()
        } }
        let reply = try FocusControlWire.decode(payload,expectedOperation:operation)
        if let code = reply["code"] as? String { throw Failure.rejected(code) }
        guard let result = reply["result"] as? [String:Any] else { throw Failure.protocolViolation }
        return result
    }

    func close() { finish(Failure.closed,notify:false) }
    private func fail(_ error: Error) { finish(error,notify:true) }
    private func finish(_ error: Error, notify: Bool) {
        guard connection != nil || ready != nil || !pending.isEmpty else { return }
        generation = UUID(); connected = false
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        startupDeadline?.cancel(); startupDeadline = nil
        heartbeat?.cancel(); heartbeat = nil; reader?.cancel(); reader = nil
        let waiter = ready; ready = nil; waiter?.resume(throwing:error)
        let waiting = pending; pending.removeAll(); origins.removeAll()
        for item in waiting.values { item.deadline.cancel(); item.continuation.resume(throwing:error) }
        if notify { onFailure?() }
    }

    private func receive(_ count:Int,from connection:NWConnection) async throws -> Data {
        var result = Data(); result.reserveCapacity(count)
        while result.count < count {
            try Task.checkCancellation()
            let remaining = count-result.count
            let chunk:Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength:1,maximumLength:remaining) { data,_,complete,error in
                    if let error { continuation.resume(throwing:error) }
                    else if let data,!data.isEmpty { continuation.resume(returning:data) }
                    else { continuation.resume(throwing:Failure.closed) }
                }
            }
            guard chunk.count <= remaining else { throw Failure.protocolViolation }
            result.append(chunk)
        }
        return result
    }

    private func readLoop(_ connection:NWConnection,token:UUID) async {
        do {
            while !Task.isCancelled,generation == token {
                let first = try await receive(1,from:connection)
                let frameDeadline = Task { [weak self] in
                    do { try await Task.sleep(for:.seconds(5)) } catch { return }
                    guard let self,self.generation == token else { return }; self.fail(Failure.timeout)
                }
                defer { frameDeadline.cancel() }
                var header = first
                header.append(try await receive(3,from:connection))
                let size = try FocusControlWire.payloadLength(header)
                let payload = try await receive(size,from:connection)
                guard generation == token else { return }
                let envelope = try FocusControlWire.decode(payload)
                guard let id = envelope["id"] as? Int,let type = envelope["type"] as? String else { throw Failure.protocolViolation }
                if type == "progress" {
                    guard let operation = origins[id],let state = envelope["state"] as? String else { throw Failure.protocolViolation }
                    _ = try FocusControlWire.decode(payload,expectedOperation:operation)
                    onProgress?(state)
                } else {
                    guard let item = pending[id] else { throw Failure.protocolViolation }
                    _ = try FocusControlWire.decode(payload,expectedOperation:item.operation)
                    pending.removeValue(forKey:id); item.deadline.cancel()
                    item.continuation.resume(returning:payload)
                }
            }
        } catch { if generation == token { fail(error) } }
    }

    func appleAddress(from result:[String:Any]) throws -> String {
        guard let endpoint = result["endpoint"] as? [String:Any],let remote = endpoint["address"] as? String,
              endpoint["port"] as? Int == 55000 else { throw Failure.protocolViolation }
        let localIP = address.split(separator:"%").first.map(String.init) ?? address
        guard (IPv4Address(localIP)?.rawValue == IPv4Address(remote)?.rawValue && IPv4Address(remote) != nil)
            || (IPv6Address(localIP)?.rawValue == IPv6Address(remote)?.rawValue && IPv6Address(remote) != nil) else { throw Failure.authentication }
        return address // Keep the Mac's local IPv6 interface scope, never the PC's.
    }
}
