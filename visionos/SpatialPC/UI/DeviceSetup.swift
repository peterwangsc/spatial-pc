import SwiftUI
import Network

struct DeviceSetup:View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected:DiscoveredHost?
    @State private var manual = false
    @State private var address = ""
    @State private var code = ""
    private var manualAddress:String { address.trimmingCharacters(in:.whitespacesAndNewlines) }
    private var validAddress:Bool {
        !manualAddress.isEmpty && manualAddress.utf8.count <= 253 && !manualAddress.contains("/") && !manualAddress.contains(where:\.isWhitespace)
    }
    private var status:String {
        switch model.pairing.phase {
        case .connecting: "Connecting to your PC…"
        case .verifying: "Verifying pairing code…"
        case .approval: "Approve this Vision Pro in the Windows host."
        case .paired: "PC added"
        default: model.pairing.error ?? ""
        }
    }
    var body:some View {
        NavigationStack {
            Form {
                if let error = model.pairing.error { Section { Text(error).foregroundStyle(.orange) } }
                if !model.pairing.busy {
                    Section {
                        ForEach(model.discovery.hosts) { host in
                            Button {
                                selected = host; manual = false
                            } label: {
                                HStack { Label(host.name,systemImage:"desktopcomputer"); Spacer(); if selected == host && !manual { Image(systemName:"checkmark") } }
                            }
                        }
                        if model.discovery.hosts.isEmpty { Text(model.discovery.status).foregroundStyle(.secondary) }
                        Button("Search Again",systemImage:"arrow.clockwise") { model.discovery.start() }
                        Toggle("Enter PC address manually",isOn:$manual)
                        if manual {
                            TextField("PC address",text:$address).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    } header: { Text("Your PC") } footer: {
                        Text("Open Spatial PC Host on your PC and choose Pair Device.")
                    }
                    Section("Pairing code") {
                        TextField("4-digit code",text:$code).keyboardType(.numberPad).textContentType(.oneTimeCode).autocorrectionDisabled()
                            .onChange(of:code) { _,value in code = String(value.unicodeScalars.filter { (48...57).contains($0.value) }.prefix(4)) }
                        Button("Pair",systemImage:"link") { pair() }
                            .disabled((try? PairingV2Wire.code(code)) == nil || (manual ? !validAddress : selected == nil))
                    }
                }
                if model.pairing.busy { Section { ProgressView(); Text(status) } }
            }
            .navigationTitle("Add PC")
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Cancel") { model.pairing.cancel(); dismiss() } } }
            .task { model.discovery.start() }
            .onDisappear { model.discovery.stop(); model.pairing.cancel(); code = "" }
            .onChange(of:model.pairing.phase) { _,phase in
                if phase == .paired { model.stream.refreshPairing(); dismiss() }
            }
        }.frame(width:640,height:620)
    }
    private func pair() {
        let secret = code; code = ""
        if manual {
            let host = manualAddress
            guard validAddress else { return }
            model.pairing.begin(endpoint:.hostPort(host:.init(host),port:47990),address:host,serviceName:nil,domain:nil,hostName:host,code:secret,store:model.devices)
        } else if let selected {
            model.pairing.begin(endpoint:selected.endpoint,address:"",serviceName:selected.name,domain:selected.domain,hostName:selected.name,code:secret,store:model.devices)
        }
    }
}
