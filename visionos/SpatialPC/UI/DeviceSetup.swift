import SwiftUI
import Network

struct DeviceSetup: View {
    @Bindable var model: AppModel
    var onConnect: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.prepare
    @State private var selected: DiscoveredHost?
    @State private var manual = false
    @State private var address = ""
    @State private var code = ""
    @State private var designError: String?
    @FocusState private var focusedField: Field?

    private enum Step { case prepare, choose, address, code, pairing, approval, complete }
    private enum Field { case address, code }
    private var manualAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validAddress: Bool {
        !manualAddress.isEmpty && manualAddress.utf8.count <= 253 &&
        !manualAddress.contains("/") && !manualAddress.contains(where: \.isWhitespace)
    }
    private var hostName: String { manual ? manualAddress : selected?.name ?? "your PC" }
    private var canGoBack: Bool { [.choose, .address, .code].contains(step) }
    private var title: String {
        switch step {
        case .prepare: "Get your PC ready"
        case .choose: "Choose your PC"
        case .address: "Enter your PC’s address"
        case .code: "Pairing code"
        case .pairing: model.pairing.phase == .verifying ? "Confirming code" : "Connecting"
        case .approval: "Approve on your PC"
        case .complete: "PC added"
        }
    }
    private var symbol: String {
        switch step {
        case .code: "number"
        case .approval: "checkmark.shield"
        case .complete: "checkmark.circle.fill"
        default: "desktopcomputer"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if step == .choose {
                    heading
                    content
                } else {
                    ScrollView {
                        VStack(spacing: 24) { heading; content }
                            .frame(maxWidth: .infinity)
                    }
                }
                primaryAction
            }
            .padding(32)
            .navigationTitle("Add Device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if canGoBack {
                        Button("Back", systemImage: "chevron.left", action: back)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(step == .complete ? "Close" : "Cancel") { close() }
                }
            }
            .task { configureDesignPreview() }
            .onDisappear {
                model.discovery.stop()
                model.pairing.cancel()
                code = ""
            }
            .onChange(of: model.pairing.phase) { _, phase in
                switch phase {
                case .connecting, .verifying: step = .pairing
                case .approval: step = .approval
                case .failed:
                    step = .code
                    focusedField = .code
                case .paired:
                    code = ""
                    // Adding a host selects it. Do not retain a stream to the old PC.
                    model.stream.disconnect()
                    model.stream.refreshPairing()
                    step = .complete
                case .idle: break
                }
            }
        }
        .frame(width: 600, height: 560)
    }

    private var heading: some View {
        VStack(spacing: 14) {
            if step != .code {
                Image(systemName: symbol).font(.system(size: 44))
                    .foregroundStyle(step == .complete ? Color.mint : Color.primary)
                    .accessibilityHidden(true)
            }
            Text(title).font(.largeTitle.bold()).multilineTextAlignment(.center)
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .prepare:
            Text("Open Spatial PC on Windows and choose Pair a new device.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Link("Install the Windows host", destination: URL(string: "https://peterwang.tech/spatial-pc")!)
        case .choose:
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.discovery.hosts) { host in
                        Button {
                            selected = host
                            manual = false
                            showCode()
                        } label: {
                            HStack {
                                Label(host.name, systemImage: "desktopcomputer")
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                Spacer()
                                Image(systemName: "chevron.right").accessibilityHidden(true)
                            }.frame(maxWidth: .infinity).padding(12)
                        }.buttonStyle(.bordered)
                    }
                    if model.discovery.hosts.isEmpty {
                        Text(model.discovery.status)
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .padding(.vertical, 20)
                        Button("Search Again", systemImage: "arrow.clockwise") { model.discovery.start() }
                    }
                }
            }
            Button("Enter address manually") {
                model.discovery.stop()
                manual = true
                step = .address
                focusedField = .address
            }
        case .address:
            Text("Use the address shown in Spatial PC on Windows.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            TextField("PC address", text: $address)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textFieldStyle(.roundedBorder).focused($focusedField, equals: .address)
                .submitLabel(.continue).onSubmit { if validAddress { showCode() } }
        case .code:
            Text(hostName)
                .foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
            confirmationCode
            if let error = model.pairing.error ?? designError {
                Text(error).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
        case .pairing:
            ProgressView().controlSize(.large)
        case .approval:
            Text("Choose Allow this device in Spatial PC on Windows.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            ProgressView().accessibilityLabel("Waiting for PC approval")
        case .complete:
            Text(model.devices.selected?.name ?? hostName)
                .font(.title2).multilineTextAlignment(.center).lineLimit(3)
        }
    }

    private var confirmationCode: some View {
        let characters = Array(code)
        let activeIndex = focusedField == .code ? min(characters.count, 3) : -1
        return ZStack {
            HStack(spacing: 12) {
                ForEach(0..<4) { index in
                    let active = index == activeIndex
                    Text(index < characters.count ? String(characters[index]) : "·")
                        .font(.system(size: 56, weight: .medium, design: .monospaced))
                        .foregroundStyle(index < characters.count ? Color.primary : Color.secondary)
                        .frame(width: 76, height: 94)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(active ? Color.mint : Color.primary.opacity(0.2), lineWidth: 1.5)
                        }
                        .shadow(color: active ? Color.mint.opacity(0.3) : .clear, radius: 4)
                }
            }
            .accessibilityHidden(true).allowsHitTesting(false)
            // One real input retains paste, deletion, keyboard and accessibility behavior.
            TextField("", text: $code)
                .font(.system(size: 56, design: .monospaced))
                .foregroundStyle(.clear).tint(.clear).textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .keyboardType(.numberPad).textContentType(.oneTimeCode)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .accessibilityLabel("Four-digit confirmation code")
                .focused($focusedField, equals: .code)
                .onChange(of: code) { _, value in
                    code = String(value.unicodeScalars.filter { (48...57).contains($0.value) }.prefix(4))
                }
        }
        .frame(width: 340, height: 94)
        .contentShape(Rectangle())
        .onTapGesture { focusedField = .code }
    }

    @ViewBuilder private var primaryAction: some View {
        switch step {
        case .prepare:
            primaryButton("Continue") { showChoices() }
        case .address:
            primaryButton("Continue") { showCode() }.disabled(!validAddress)
        case .code:
            primaryButton("Confirm Code") { pair() }
                .disabled((try? PairingV2Wire.code(code)) == nil || (manual ? !validAddress : selected == nil))
        case .complete:
            primaryButton("Connect") {
                guard !designPreview else { return }
                dismiss()
                onConnect()
            }.disabled(!model.desktopConnectionAllowed)
        default: EmptyView()
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent).tint(.mint).controlSize(.large)
            .frame(maxWidth: .infinity)
    }
    private func showChoices() {
        code = ""
        focusedField = nil
        step = .choose
        model.discovery.start()
    }
    private func showCode() {
        model.discovery.stop()
        model.pairing.cancel() // Keeps the AppModel-owned attempt budget intact.
        code = ""
        step = .code
        focusedField = .code
    }
    private func back() {
        let previous = step
        model.pairing.cancel()
        code = ""
        focusedField = nil
        switch previous {
        case .choose:
            model.discovery.stop()
            step = .prepare
        case .code where manual:
            step = .address
            focusedField = .address
        case .address, .code: showChoices()
        default: break
        }
    }
    private func close() {
        code = ""
        model.pairing.cancel()
        dismiss()
    }
    // Simulator-only public fixtures never enroll or start a desktop connection.
    private var designPreview: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--device-setup-preview")
        #else
        false
        #endif
    }
    private func configureDesignPreview() {
        #if DEBUG && targetEnvironment(simulator)
        guard designPreview else { return }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--setup-page"), arguments.indices.contains(index + 1) else { return }
        selected = DiscoveredHost(name: "Gaming PC", domain: "local.")
        switch arguments[index + 1] {
        case "code": step = .code; code = "1234"
        case "code-empty": step = .code; focusedField = .code
        case "code-error":
            step = .code
            selected = DiscoveredHost(name: "A long Windows computer name for accessibility layout validation", domain: "local.")
            designError = "Pairing did not finish. Open a new pairing code on your PC and try again."
        case "approval": step = .approval
        case "complete": step = .complete
        default: break
        }
        #endif
    }
    private func pair() {
        guard !designPreview, !model.pairing.busy, (try? PairingV2Wire.code(code)) != nil,
              manual ? validAddress : selected != nil else { return }
        let secret = code
        code = ""
        focusedField = nil
        if manual {
            let host = manualAddress
            model.pairing.begin(endpoint: .hostPort(host: .init(host), port: 47990), address: host,
                serviceName: nil, domain: nil, hostName: host, code: secret, store: model.devices)
        } else if let selected {
            model.pairing.begin(endpoint: selected.endpoint, address: "", serviceName: selected.name,
                domain: selected.domain, hostName: selected.name, code: secret, store: model.devices)
        }
    }
}
