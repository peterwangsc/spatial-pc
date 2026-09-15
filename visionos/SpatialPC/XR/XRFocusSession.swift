#if SPATIALPC_XR && canImport(FoveatedStreaming)
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

    func enter(model: AppModel, open: OpenImmersiveSpaceAction, close: DismissImmersiveSpaceAction) {
        guard !gate.busy, !model.isImmersed else { return }
        let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = UInt16(port), number != 0, let port = NWEndpoint.Port(rawValue: number) else {
            validationError = "Enter a valid port."; return
        }
        let endpoint: FoveatedStreamingSession.Endpoint
        if let ip = IPv4Address(host) { endpoint = .local(ipAddress: ip, port: port) }
        else if let ip = IPv6Address(host) { endpoint = .local(ipAddress: ip, port: port) }
        else { validationError = "Enter the PC’s IP address."; return }
        validationError = nil
        returnToDesktop = model.destination == .desktop || model.stream.active
        model.stream.stopControl()
        model.stream.disconnect() // Never run desktop capture beside the XR fixture.
        model.destination = .focus
        model.transitionPending = true
        session.immersivePresentationBehaviors = .automatic(open, close)
        // First-time system pairing includes looking at the PC's QR code.
        gate.begin(timeout: .seconds(180),
                   connect: { [session] in try await session.connect(endpoint: endpoint) },
                   disconnect: { [session] in await session.disconnect() },
                   ended: { [weak self, weak model] in
            guard let self, let model else { return }
            model.transitionPending = false
            model.destination = self.returnToDesktop ? .desktop : .devices
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
                    model.xrFocus.gate.stop()
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
