#if canImport(FoveatedStreaming)
import SwiftUI
import FoveatedStreaming
import Network
import RealityKit

@MainActor @Observable
final class XRFocusSession {
    let session = FoveatedStreamingSession()
    let gate = XRConnectionGate()
    // Development configuration only; no saved desktop pairing is reused or changed.
    var address = ""
    var port = "55000"
    private(set) var validationError: String?
    var configured: Bool { !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var returnToDesktop = false

    init() { observeStatus() }

    private func observeStatus() {
        // The controls window may be closed; session cleanup must outlive views.
        let status = withObservationTracking {
            session.status
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStatus() }
        }
        // Track only the framework status. Reading gate state inside the tracking
        // closure would also observe begin() and could cancel a fresh connection.
        if case .disconnected = status { gate.stop() }
    }

    @ObservationIgnored private var control: FocusControlClient?
    private var stoppedCleanly = false
    private(set) var stage = "Connecting"

    func stop(returnToDesktop: Bool = false) {
        self.returnToDesktop = returnToDesktop
        gate.stop()
    }

    /// The same saved PC opens its desktop first. Its control connection owns
    /// the switch to Apple's separate system-paired XR session.
    func enterPaired(model: AppModel, open: OpenImmersiveSpaceAction, close: DismissImmersiveSpaceAction) {
        guard !gate.busy,!model.isImmersed,let host = model.devices.selected else { return }
        stoppedCleanly = false; returnToDesktop = false
        validationError = nil; stage = "Connecting"
        model.transitionPending = true
        model.cancelDesktopRestoration()
        let client = FocusControlClient(); control = client
        client.onFailure = { [weak self] in
            guard let self,self.gate.busy else { return }
            self.returnToDesktop = false
            self.validationError = "Focus disconnected. Reconnect to your PC."
            self.gate.stop()
        }
        client.onProgress = { [weak self] state in
            guard let self else { return }
            switch state {
            case "awaitingPermission": self.stage = "Approve on your PC"
            case "waitingForSystem", "qrPresented": self.stage = "Scan the code on your PC"
            case "startingMedia", "mediaReady": self.stage = "Starting Focus"
            case "stopped", "failed":
                if self.gate.phase != .stopping { self.returnToDesktop = false; self.gate.stop() }
            default: break
            }
        }
        session.immersivePresentationBehaviors = .automatic(open,close)
        gate.begin(timeout:.seconds(300),connect: { [weak self,weak model] in
            guard let self,let model else { throw CancellationError() }
            do {
                try await client.connect(host:host)
                let capabilities = try await client.request("capabilities")
                guard capabilities["runtimeConfigured"] as? Bool == true,
                      capabilities["accessEnabled"] as? Bool == true else { throw FocusControlClient.Failure.rejected("unsupported") }
                if capabilities["focusAllowed"] as? Bool != true {
                    self.stage = "Approve on your PC"
                    let permission = try await client.request("focus.requestPermission",timeout:65)
                    guard permission["granted"] as? Bool == true else { throw FocusControlClient.Failure.rejected("permissionRequired") }
                }
                try Task.checkCancellation()
                model.stream.stopControl(); model.stream.disconnect()
                model.destination = .focus
                self.stage = "Starting Focus"
                let prepared = try await client.request("focus.prepare",parameters:["intent":"enter"],timeout:32)
                let hostAddress = try client.appleAddress(from:prepared)
                try Task.checkCancellation()
                let endpoint = try self.endpoint(address:hostAddress,port:55000)
                self.stage = "Scan the code on your PC"
                try await self.session.connect(endpoint:endpoint)
            } catch {
                if !Task.isCancelled { self.validationError = Self.message(for:error) }
                throw error
            }
        },disconnect: { [weak self] in
            guard let self else { return }
            // This cleanup task survives cancellation of connect. The host must
            // confirm its media owner is idle before automatic desktop return.
            if client.connected {
                do {
                    let result = try await client.request("focus.stop",parameters:["sessionId":NSNull(),"returnToDesktop":self.returnToDesktop],timeout:14)
                    self.stoppedCleanly = result["stopped"] as? Bool == true && result["desktopAllowed"] as? Bool == true
                } catch { self.stoppedCleanly = false }
            }
            client.onFailure = nil; client.close()
            await self.session.disconnect()
        },ended: { [weak self,weak model] in
            guard let self,let model else { return }
            self.control = nil; model.transitionPending = false
            // Back may already have opened My Devices while cleanup awaited.
            guard model.destination != .devices else { return }
            model.destination = .desktop
            if self.returnToDesktop && self.stoppedCleanly { model.restoreDesktopAfterXR() }
            else if let error = self.validationError ?? self.gate.error { model.error = error }
        })
    }

    private func endpoint(address:String,port:UInt16) throws -> FoveatedStreamingSession.Endpoint {
        guard let port = NWEndpoint.Port(rawValue:port) else { throw FocusControlClient.Failure.protocolViolation }
        if let ip = IPv4Address(address) { return .local(ipAddress:ip,port:port) }
        if let ip = IPv6Address(address) { return .local(ipAddress:ip,port:port) }
        throw FocusControlClient.Failure.protocolViolation
    }

    private static func message(for error:Error) -> String {
        guard let failure = error as? FocusControlClient.Failure else { return "Could not start Focus. Try again." }
        switch failure {
        case .rejected("busy"): return "This PC is already in use."
        case .rejected("permissionRequired"): return "Focus was not allowed on your PC."
        case .rejected("unsupported"): return "Enable Focus in the Windows host."
        case .authentication: return "Could not verify this PC."
        default: return "Could not start Focus. Check the Windows host."
        }
    }

    // Retained only for the explicit manual development fixture.
    func enter(model: AppModel, open: OpenImmersiveSpaceAction, close: DismissImmersiveSpaceAction) {
        guard !gate.busy,!model.isImmersed else { return }
        guard let number = UInt16(port),let endpoint = try? endpoint(address:address.trimmingCharacters(in:.whitespacesAndNewlines),port:number) else {
            validationError = "Enter the PC’s IP address and port."; return
        }
        validationError = nil; returnToDesktop = true
        model.stream.stopControl(); model.stream.disconnect()
        model.destination = .focus; model.transitionPending = true
        session.immersivePresentationBehaviors = .automatic(open,close)
        gate.begin(timeout:.seconds(180),connect:{ [session] in try await session.connect(endpoint:endpoint) },
                   disconnect:{ [session] in await session.disconnect() },ended:{ [weak self,weak model] in
            guard let self,let model else { return }
            model.transitionPending = false
            guard model.destination != .devices else { return }
            model.destination = .desktop
            if self.returnToDesktop { model.restoreDesktopAfterXR() }
        })
    }

}

/// This exists only in the XR validation configuration of the same app target.
/// The final product will select the host's supported Focus path automatically.
struct XRFocusSetup: View {
    @Bindable var model: AppModel
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var closeSpace
    var body: some View {
        Section("Focus validation") {
            if let host = model.devices.selected {
                Button("Use Selected PC") { model.xrFocus.address = host.address }
                    .disabled(model.xrFocus.gate.busy)
            }
            TextField("PC IP address", text: Binding(get: { model.xrFocus.address }, set: { model.xrFocus.address = $0 }))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(model.xrFocus.gate.busy)
            TextField("Port", text: Binding(get: { model.xrFocus.port }, set: { model.xrFocus.port = $0 }))
                .keyboardType(.numberPad).disabled(model.xrFocus.gate.busy)
            Button(model.xrFocus.gate.busy ? "Cancel Focus" : "Connect in Focus") {
                if model.xrFocus.gate.busy { model.xrFocus.gate.stop() }
                else { model.xrFocus.enter(model: model, open: openSpace, close: closeSpace) }
            }
            if let error = model.xrFocus.validationError ?? model.xrFocus.gate.error {
                Text(error).foregroundStyle(.orange)
            }
        }.disabled(model.isImmersed)
    }
}

struct XRFocusSurface: View {
    @Bindable var model: AppModel
    var body: some View {
        RealityView { content, attachments in
            if let controls = attachments.entity(for: "return") {
                controls.position = [0, -0.25, -1.2]
                content.add(controls)
            }
        } attachments: {
            Attachment(id: "return") {
                Button("Return to Window", systemImage: "arrow.down.right.and.arrow.up.left") {
                    model.xrFocus.stop(returnToDesktop:true)
                }
                .labelStyle(.iconOnly)
                .padding(12).glassBackgroundEffect()
            }
        }
        .onAppear { model.isImmersed = true; model.transitionPending = false }
        .onDisappear {
            model.isImmersed = false
            model.xrFocus.gate.stop()
        }
    }
}
#endif
