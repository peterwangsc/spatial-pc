import Foundation
import Network
import Security
import CryptoKit
import Observation
import CoreVideo

@MainActor @Observable
final class DesktopStreamClient {
    private(set) var status = "Add a PC to get started." { didSet { if oldValue != status { saveDiagnostics() } } }
    private(set) var userMessage: String?
    private(set) var available = false
    private(set) var connected = false
    private(set) var active = false
    private(set) var hasFrames = false
    private(set) var inputAvailable = false
    private(set) var textAvailable = false
    @ObservationIgnored private var keyPressEvents = 0
    @ObservationIgnored private var navigationKeyCommands = 0
    @ObservationIgnored private var committedTextCallbacks = 0
    @ObservationIgnored private var keyboardFirstResponder = false
    @ObservationIgnored private var keyboardPresentationRequested = false
    @ObservationIgnored private(set) var controlling = false
    @ObservationIgnored private var inputOutbox = InputWire.Outbox()
    @ObservationIgnored private var inputWriter: Task<Void,Never>?
    @ObservationIgnored private var inputHeartbeat: Task<Void,Never>?
    @ObservationIgnored private var inputWriteStarted: ContinuousClock.Instant?
    @ObservationIgnored private(set) var receivedFrames = 0
    @ObservationIgnored private(set) var decodeMS = 0.0
    @ObservationIgnored private(set) var hardwareDecoder = false
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let diagnosticsQueue = DispatchQueue(label:"SpatialPC.connection-metrics",qos:.utility)
    @ObservationIgnored private let queue = DispatchQueue(label:"SpatialPC.secure-stream",qos:.userInteractive)
    @ObservationIgnored private let decoderQueue = DispatchQueue(label:"SpatialPC.decode",qos:.userInteractive)
    @ObservationIgnored private let renderer: SyntheticRenderer
    @ObservationIgnored private let devices: PairedHostStore
    @ObservationIgnored private var retryTask:Task<Void,Never>?
    @ObservationIgnored private var startupDeadline:Task<Void,Never>?
    @ObservationIgnored private var requested = false
    @ObservationIgnored private var retryCount = 0

    enum Failure: Error { case unpaired, ended, trust, protocolMismatch }
    init(renderer: SyntheticRenderer,devices:PairedHostStore) {
        self.renderer = renderer; self.devices = devices
        refreshPairing()
    }
    private func saveDiagnostics(filename:String = "connection-diagnostics.json") {
        let root = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        struct Snapshot: Encodable, Sendable {
            let status: String
            let frames: Int
            let decodeMS: Double
            let hardwareDecoder: Bool
            let inputAvailable: Bool
            let controlling: Bool
            let queuedInputEvents: Int
            let textAvailable: Bool
            let keyPressEvents: Int
            let navigationKeyCommands: Int
            let committedTextCallbacks: Int
            let keyboardFirstResponder: Bool
            let keyboardPresentationRequested: Bool
        }
        let snapshot = Snapshot(status:status,frames:receivedFrames,decodeMS:decodeMS,hardwareDecoder:hardwareDecoder,
                                inputAvailable:inputAvailable,controlling:controlling,queuedInputEvents:inputOutbox.events.count,
                                textAvailable:textAvailable,keyPressEvents:keyPressEvents,navigationKeyCommands:navigationKeyCommands,
                                committedTextCallbacks:committedTextCallbacks,keyboardFirstResponder:keyboardFirstResponder,
                                keyboardPresentationRequested:keyboardPresentationRequested)
        diagnosticsQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to:root.appendingPathComponent(filename),options:.atomic)
            }
        }
    }
    func refreshPairing() {
        available = devices.selected != nil
        #if DEBUG
        if !available { available = (try? LabPairing.load()) != nil }
        #endif
        status = available ? "Ready to connect" : "Add a PC to get started."
    }
    private struct Credentials {
        let endpoint:NWEndpoint
        let rootDER:Data
        let serverName:String
        let serverSHA256:String
        let identity:sec_identity_t
    }
    private func credentials() throws -> Credentials {
        if let host = devices.selected {
            return Credentials(endpoint:host.endpoint,rootDER:host.caCertificate,serverName:host.serverName,
                               serverSHA256:host.serverSHA256,identity:try DeviceKeychain.identity(for:host))
        }
        #if DEBUG
        if let pair = try LabPairing.load(),let port = NWEndpoint.Port(rawValue:pair.port) {
            return Credentials(endpoint:.hostPort(host:.init(pair.host),port:port),rootDER:pair.rootDER,
                               serverName:pair.serverName,serverSHA256:pair.serverSHA256,identity:try pair.identity())
        }
        #endif
        throw Failure.unpaired
    }
    func disconnect() {
        requested = false; retryTask?.cancel(); retryTask = nil; retryCount = 0
        endConnection()
    }
    private func recover(_ message:String, retry:Bool) {
        endConnection()
        guard requested,retry,retryCount < 5 else { requested = false; userMessage = message; status = message; return }
        retryCount += 1; active = true; status = "Reconnecting…"; userMessage = nil
        let delay = min(8,1 << (retryCount-1))
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for:.seconds(delay)) } catch { return }
            guard let self,self.requested else { return }
            self.connectAttempt()
        }
    }
    private func endConnection() {
        if connection != nil { saveDiagnostics(filename:"last-session-diagnostics.json") }
        startupDeadline?.cancel(); startupDeadline = nil

        controlling = false; inputAvailable = false; textAvailable = false
        keyPressEvents = 0; navigationKeyCommands = 0; committedTextCallbacks = 0; keyboardFirstResponder = false; keyboardPresentationRequested = false
        inputHeartbeat?.cancel(); inputHeartbeat = nil
        inputWriter?.cancel(); inputWriter = nil; inputWriteStarted = nil
        inputOutbox = InputWire.Outbox()
        generation = UUID(); connection?.cancel(); connection = nil; connected = false; active = false; hasFrames = false
        renderer.endVideo(); status = "Disconnected"; userMessage = nil
    }
    func connect() {
        guard connection == nil else { return }
        requested = true; retryCount = 0; retryTask?.cancel(); retryTask = nil
        connectAttempt()
    }
    private func connectAttempt() {
        guard requested,connection == nil else { return }
        userMessage = nil
        do {
            let pair = try credentials()
            guard let root = SecCertificateCreateWithData(nil,pair.rootDER as CFData) else { throw Failure.unpaired }
            let tls = NWProtocolTLS.Options()
            let options = tls.securityProtocolOptions
            sec_protocol_options_set_min_tls_protocol_version(options,.TLSv13)
            sec_protocol_options_set_local_identity(options,pair.identity)
            sec_protocol_options_set_tls_server_name(options,pair.serverName)
            sec_protocol_options_add_tls_application_protocol(options,"spatialpc/1")
            sec_protocol_options_set_verify_block(options, { _, wrappedTrust, complete in
                let trust = sec_trust_copy_ref(wrappedTrust).takeRetainedValue()
                guard SecTrustSetAnchorCertificates(trust,[root] as CFArray) == errSecSuccess,
                      SecTrustSetAnchorCertificatesOnly(trust,true) == errSecSuccess,
                      SecTrustSetPolicies(trust,SecPolicyCreateSSL(true,pair.serverName as CFString)) == errSecSuccess,
                      SecTrustEvaluateWithError(trust,nil),
                      let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
                    complete(false); return
                }
                let digest = SHA256.hash(data:SecCertificateCopyData(leaf) as Data).map { String(format:"%02x",$0) }.joined()
                complete(digest == pair.serverSHA256)
            },queue)
            let tcp = NWProtocolTCP.Options()
            // Reverse input records are small and latency-sensitive; do not wait
            // for another record to fill an outbound TCP segment.
            tcp.noDelay = true
            tcp.enableKeepalive = true; tcp.keepaliveIdle = 10; tcp.keepaliveInterval = 5; tcp.keepaliveCount = 3
            let parameters = NWParameters(tls:tls,tcp:tcp)
            let connection = NWConnection(to:pair.endpoint,using:parameters)
            self.connection = connection; active = true; let sessionID = UUID(); generation = sessionID
            status = "Authenticating paired PC…"; receivedFrames = 0; hasFrames = false
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.generation == sessionID else { return }
                    switch state {
                    case .ready:
                        guard let metadata = connection.metadata(definition:NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
                              let negotiated = sec_protocol_metadata_get_negotiated_protocol(metadata.securityProtocolMetadata),
                              String(cString:negotiated) == "spatialpc/1" else {
                            self.recover("This PC uses an incompatible connection protocol. Update Spatial PC on both devices.",retry:false)
                            return
                        }
                        self.connected = true; self.userMessage = nil; self.status = "Encrypted session · waiting for desktop"
                        Task { await self.receiveStream(connection,sessionID:sessionID) }
                    case .failed(let error):
                        if case .tls = error { self.recover("This PC could not be verified. Check its pairing or pair again.",retry:false) }
                        else { self.recover("Could not reach your PC. Check that its host is enabled on the same network.",retry:true) }
                    case .waiting(let error):
                        if case .tls = error {
                            self.recover("This PC could not be verified. Check its pairing or pair again.",retry:false)
                        } else { self.status = "Waiting for the paired PC: \(error)"; self.userMessage = "Waiting for your PC. Check the host and your local network, or cancel to try again." }
                    default: break
                    }
                }
            }
            startupDeadline = Task { [weak self] in
                do { try await Task.sleep(for:.seconds(15)) } catch { return }
                guard let self,self.generation == sessionID,!self.hasFrames else { return }
                self.recover("The PC did not send a desktop. Check its host and try again.",retry:true)
            }
            connection.start(queue:queue)
        } catch { recover("Could not use this saved pairing. Set up the PC again.",retry:false) }
    }
    @discardableResult func startControl() -> Bool {
        guard inputAvailable,hasFrames,connection != nil else { return false }
        if controlling { return true }
        controlling = true; enqueueInput(.start)
        guard controlling else { return false }
        saveDiagnostics()
        let sessionID = generation
        inputHeartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.milliseconds(500)) } catch { return }
                guard let self,self.generation == sessionID,self.controlling else { return }
                if let began = self.inputWriteStarted,began.duration(to:.now) > .milliseconds(1500) {
                    self.failInput(); return
                }
                self.enqueueInput(.heartbeat)
            }
        }
        return controlling
    }
    func stopControl() {
        guard controlling else { return }
        controlling = false; inputHeartbeat?.cancel(); inputHeartbeat = nil
        enqueueInput(.stop); saveDiagnostics()
    }
    func sendInput(_ event:InputWire.Event) {
        guard controlling,inputAvailable else { return }
        guard event.type != 8 || textAvailable else { return }
        enqueueInput(event)
    }
    func recordKeyboardFocus(_ focused:Bool) { keyboardFirstResponder = focused; saveDiagnostics() }
    func recordKeyboardPresentation(_ requested:Bool) { keyboardPresentationRequested = requested; saveDiagnostics() }
    func recordKeyPresses(_ count:Int) { keyPressEvents += count }
    func recordNavigationKeyCommand() { navigationKeyCommands += 1 }
    func recordTextCallback() { committedTextCallbacks += 1 }
    private func failInput() {
        disconnect(); status = "Input session ended safely."
        userMessage = "The input connection ended. Reconnect to your PC."
    }
    private func enqueueInput(_ event:InputWire.Event) {
        guard inputAvailable,let connection else { return }
        do { try inputOutbox.append(event) } catch { failInput(); return }
        guard inputWriter == nil else { return }
        let sessionID = generation
        inputWriter = Task { [weak self] in
            guard let self else { return }
            do {
                while self.generation == sessionID,!Task.isCancelled,!self.inputOutbox.events.isEmpty {
                    let packet = try self.inputOutbox.take(2)
                    self.inputWriteStarted = .now
                    try await self.send(packet,on:connection)
                    guard self.generation == sessionID else { return }
                    self.inputWriteStarted = nil
                    // At most two records per 1/120 second, matching the host's
                    // 240/s limit. Adjacent pointer motion is coalesced in Outbox.
                    try await Task.sleep(for:.nanoseconds(8_333_334))
                }
                if self.generation == sessionID { self.inputWriter = nil }
            } catch {
                if self.generation == sessionID { self.failInput() }
            }
        }
    }
    nonisolated private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            connection.send(content:data,completion:.contentProcessed { error in
                if let error { continuation.resume(throwing:error) } else { continuation.resume() }
            })
        }
    }
    nonisolated private func receive(_ size: Int, on connection: NWConnection) async throws -> Data {
        var buffer = try ExactStreamReader(size)
        while buffer.remaining > 0 {
            try Task.checkCancellation()
            let remaining = buffer.remaining
            let part:Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength:remaining,maximumLength:remaining) { data, _, _, error in
                    if let error { continuation.resume(throwing:error) }
                    else if let data, !data.isEmpty { continuation.resume(returning:data) }
                    else { continuation.resume(throwing:Failure.ended) }
                }
            }
            try buffer.append(part)
        }
        return buffer.data
    }

    private func receiveStream(_ connection: NWConnection, sessionID: UUID) async {
        do {
            let payload = Data("{\"version\":1,\"codecs\":[\"h264-annexb\"],\"maxWidth\":8192,\"maxHeight\":8192,\"input\":{\"version\":1,\"textVersion\":1}}".utf8)
            var hello = Data("SPC1".utf8); var length = UInt32(payload.count).bigEndian
            withUnsafeBytes(of:&length) { hello.append(contentsOf:$0) }; hello.append(payload)
            try await send(hello,on:connection)
            let count = try StreamWire.helloLength(await receive(8,on:connection))
            let capabilities = try StreamWire.capabilities(await receive(count,on:connection))
            guard generation == sessionID else { return }
            inputAvailable = capabilities.input?.supported == true
            textAvailable = capabilities.input?.supportsText == true
            let decoder = H264Decoder(width:capabilities.width,height:capabilities.height)
            await renderer.prepareVideo(width:capabilities.width,height:capabilities.height)
            guard generation == sessionID else {
                if self.connection == nil { renderer.endVideo() }
                return
            }
            while generation == sessionID {
                let header = try StreamWire.frameHeader(await receive(16,on:connection))
                let data = try await receive(header.length,on:connection)
                let frame: H264Decoder.Frame? = try await withCheckedThrowingContinuation { continuation in
                    decoderQueue.async {
                        do { continuation.resume(returning:try decoder.decode(data,timestamp:header.timestamp)) }
                        catch { continuation.resume(throwing:error) }
                    }
                }
                guard generation == sessionID else { return }
                if let frame {
                    renderer.presentVideo(frame.pixel)
                    if !hasFrames { hasFrames = true; retryCount = 0; startupDeadline?.cancel(); startupDeadline = nil }
                    receivedFrames += 1; decodeMS = frame.decodeMS; hardwareDecoder = frame.hardware
                    if receivedFrames % 60 == 0 { saveDiagnostics() }
                    status = "Live PC · encrypted · " + (hardwareDecoder ? "hardware decode" : "simulator decode")
                }
            }
        } catch {
            guard generation == sessionID else { return }
            if error is StreamWire.Invalid || error is DecodingError {
                recover("This PC sent an incompatible desktop stream. Update Spatial PC on both devices.",retry:false)
            } else {
                recover("The desktop connection ended. Check your PC, then reconnect.",retry:true)
            }
        }
    }
}
