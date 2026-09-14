import Foundation
import Network
import Security
import CryptoKit
import Observation

private final class PeerCertificate: @unchecked Sendable {
    private let lock = NSLock()
    private var stored:Data?
    func set(_ data:Data) { lock.withLock { stored = data } }
    var data:Data? { lock.withLock { stored } }
}

@MainActor @Observable final class PairingClient {
    enum Phase:Equatable { case idle, connecting, verifying, approval, paired, failed }
    private(set) var phase = Phase.idle
    private(set) var error:String?
    @ObservationIgnored private var operation:Task<Void,Never>?
    @ObservationIgnored private var channel:PairingChannel?
    @ObservationIgnored private var generation = UUID()
    var busy:Bool { [.connecting,.verifying,.approval].contains(phase) }
    func cancel() {
        generation = UUID(); operation?.cancel(); operation = nil; channel?.cancel(); channel = nil
        phase = .idle; error = nil
    }
    func begin(endpoint:NWEndpoint,address:String,serviceName:String?,domain:String?,hostName:String,code:String,store:PairedHostStore) {
        cancel(); phase = .connecting
        guard store.error == nil else {
            phase = .failed; error = "Saved devices are unavailable. Unlock the headset and try again."
            return
        }
        let request = generation
        operation = Task { [weak self] in
            guard let self else { return }
            var key:DeviceKeychain.PendingIdentity?
            var committed = false
            var stage = "code"
            defer { if let key,!committed { DeviceKeychain.removeIdentity(keyTag:key.tag,certificate:nil) } }
            do {
                let secret = try PairingWire.code(code)
                let name = "Vision Pro"
                stage = "create-key"
                let identity = try DeviceKeychain.createIdentity(); key = identity
                let channel = PairingChannel(endpoint:endpoint); self.channel = channel
                defer { channel.cancel() }
                stage = "connect"
                try await channel.start()
                guard self.generation == request else { throw CancellationError() }
                stage = "proof"
                self.phase = .verifying
                guard case .challenge(let challenge) = try await channel.read(),let leaf = channel.peerCertificate else { throw PairingWire.Failure.invalidMessage }
                guard !store.hosts.contains(where:{ $0.id == challenge.hostID }) else { throw PairingWire.Failure.authentication }
                var nonce = Data(count:32)
                guard nonce.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault,32,$0.baseAddress!) }) == errSecSuccess else { throw PairingWire.Failure.authentication }
                let transcript = try PairingWire.transcript(challenge:challenge,leafSHA256:Data(SHA256.hash(data:leaf)),clientNonce:nonce,publicKey:identity.publicPoint,name:name)
                let proof = try PairingWire.proof(secret:secret,transcript:transcript,server:false)
                let signature = try identity.sign(PairingWire.signatureMessage(transcript))
                try await channel.send(PairingWire.encodeProof(clientNonce:nonce,publicKey:identity.publicPoint,name:name,proof:proof,signature:signature))
                guard case .pending(let serverProof) = try await channel.read() else { throw PairingWire.Failure.authentication }
                try PairingWire.verifyServer(serverProof,secret:secret,transcript:transcript)
                guard self.generation == request else { throw CancellationError() }
                stage = "approval-response"
                self.phase = .approval
                guard case .paired(let credentials) = try await channel.read(timeout:60) else { throw PairingWire.Failure.authentication }
                guard credentials.hostID == challenge.hostID, credentials.serverCertificate == leaf,
                      self.generation == request else { throw PairingWire.Failure.authentication }
                stage = "server-trust"
                try Self.validateServer(credentials)
                stage = "client-certificate"
                try DeviceKeychain.installCertificate(credentials.clientCertificate,identity:identity,ca:credentials.caCertificate)
                let displayName = hostName.trimmingCharacters(in:.whitespacesAndNewlines)
                let saved = SavedHost(id:credentials.hostID,deviceID:credentials.deviceID,name:displayName.isEmpty ? "Windows PC" : String(displayName.prefix(64)),address:address,serviceName:serviceName,serviceDomain:domain,port:credentials.streamPort,serverName:credentials.serverName,serverCertificate:credentials.serverCertificate,clientCertificate:credentials.clientCertificate,caCertificate:credentials.caCertificate,keyTag:identity.tag,pairedAt:Date())
                stage = "find-identity"
                _ = try DeviceKeychain.identity(for:saved)
                stage = "save-host"
                try store.add(saved); committed = true
                Self.recordResult(stage:"complete",keychainStatus:nil)
                self.phase = .paired; self.error = nil; self.channel = nil
            } catch {
                guard self.generation == request else { return }
                var keychainStatus:Int32?
                if case DeviceKeychain.Failure.status(let status) = error { keychainStatus = status }
                Self.recordResult(stage:stage,keychainStatus:keychainStatus)
                self.channel = nil; self.phase = .failed
                if let failure = error as? PairingWire.Failure, failure == .invalidCode {
                    self.error = "Enter the complete pairing code shown on your PC."
                } else {
                    self.error = "Pairing did not finish. Open a new pairing code on your PC and try again."
                }
            }
        }
    }
    /// Only a fixed stage and OSStatus are retained; no names, addresses, codes,
    /// proofs, keys or certificates enter diagnostic output.
    private static func recordResult(stage:String,keychainStatus:Int32?) {
        struct Result:Encodable { let stage:String; let keychainStatus:Int32? }
        let root = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        if let data = try? JSONEncoder().encode(Result(stage:stage,keychainStatus:keychainStatus)) {
            try? data.write(to:root.appendingPathComponent("pairing-diagnostics.json"),options:.atomic)
        }
    }
    private static func validateServer(_ credentials:PairingWire.Credentials) throws {
        guard let leaf = SecCertificateCreateWithData(nil,credentials.serverCertificate as CFData),
              let root = SecCertificateCreateWithData(nil,credentials.caCertificate as CFData) else { throw PairingWire.Failure.authentication }
        var trust:SecTrust?
        guard SecTrustCreateWithCertificates(leaf,SecPolicyCreateSSL(true,credentials.serverName as CFString),&trust) == errSecSuccess,let trust,
              SecTrustSetAnchorCertificates(trust,[root] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust,true) == errSecSuccess,
              SecTrustEvaluateWithError(trust,nil) else { throw PairingWire.Failure.authentication }
    }
}

@MainActor private final class PairingChannel {
    private let connection:NWConnection
    private let leaf = PeerCertificate()
    private var ready:CheckedContinuation<Void,Error>?
    var peerCertificate:Data? { leaf.data }
    init(endpoint:NWEndpoint) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions,.TLSv13)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions,"spatialpc-pair/1")
        let leaf = self.leaf
        // This exception exists ONLY for enrollment. The 128-bit-code proof binds
        // this exact leaf before accepting credentials; streams never use it.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions,{ _,wrapped,complete in
            let trust = sec_trust_copy_ref(wrapped).takeRetainedValue()
            guard let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { complete(false); return }
            let data = SecCertificateCopyData(certificate) as Data
            guard !data.isEmpty,data.count <= 8192 else { complete(false); return }
            leaf.set(data); complete(true)
        },.global(qos:.userInitiated))
        connection = NWConnection(to:endpoint,using:NWParameters(tls:tls,tcp:NWProtocolTCP.Options()))
    }
    func cancel() { connection.cancel(); ready?.resume(throwing:CancellationError()); ready = nil }
    func start() async throws {
        try await deadline(5) {
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                self.ready = continuation
                self.connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self,let pending = self.ready else { return }
                        switch state {
                        case .ready:
                            self.ready = nil
                            guard let metadata = self.connection.metadata(definition:NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
                                  let protocolName = sec_protocol_metadata_get_negotiated_protocol(metadata.securityProtocolMetadata),
                                  String(cString:protocolName) == "spatialpc-pair/1" else { pending.resume(throwing:PairingWire.Failure.authentication); self.cancel(); return }
                            pending.resume()
                        case .failed(let error): self.ready = nil; pending.resume(throwing:error)
                        case .cancelled: self.ready = nil; pending.resume(throwing:CancellationError())
                        default: break
                        }
                    }
                }
                self.connection.start(queue:.global(qos:.userInitiated))
            }
        }
    }
    private func deadline<T>(_ seconds:UInt64,operation:() async throws -> T) async throws -> T {
        let timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds:seconds*1_000_000_000) } catch { return }
            self?.cancel()
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler(operation:operation,onCancel:{ [connection] in connection.cancel() })
    }
    func read(timeout:UInt64 = 5) async throws -> PairingWire.Message {
        try await deadline(timeout) {
            let length = try PairingWire.payloadLength(await self.exact(8))
            return try PairingWire.decode(await self.exact(length))
        }
    }
    private func exact(_ count:Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            let amount = count-result.count
            let part:Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength:amount,maximumLength:amount) { data,_,finished,error in
                    if let error { continuation.resume(throwing:error) }
                    else if let data,!data.isEmpty { continuation.resume(returning:data) }
                    else { continuation.resume(throwing:PairingWire.Failure.invalidMessage) }
                }
            }
            result.append(part)
        }
        return result
    }
    func send(_ data:Data) async throws {
        try await deadline(5) {
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                self.connection.send(content:data,completion:.contentProcessed { error in
                    if let error { continuation.resume(throwing:error) } else { continuation.resume() }
                })
            }
        }
    }
}
