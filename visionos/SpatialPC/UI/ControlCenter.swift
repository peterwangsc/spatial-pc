import SwiftUI

struct ControlCenter: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismissImmersiveSpace) private var closeSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("pc.nickname") private var pcName = "Windows PC"
    @State private var settingsOpen = false
    @State private var devicesOpen = false

    private var paired:Bool { model.stream.available }
    private var streaming:Bool { model.stream.active && model.stream.hasFrames }
    private var connectedLabel:String { model.stream.inputAvailable ? "Connected securely" : "Connected securely · View only" }
    private var connecting:Bool { model.stream.active && !streaming }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                HStack {
                    Label("Spatial PC",systemImage:"display.2").font(.title2.bold())
                    Spacer()
                    Button("Settings",systemImage:"gearshape") { settingsOpen = true }
                        .labelStyle(.iconOnly)
                }
                home
            }.padding(32)
        }
        .frame(minWidth:700,minHeight:480)
        .sheet(isPresented:$settingsOpen) { settings }
        .sheet(isPresented:$devicesOpen) {
            DeviceSetup(model:model) { devicesOpen = false; model.connectDesktop() }
        }
        .task {
            guard !model.startupHandled else { return }
            model.startupHandled = true
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--device-setup-preview") {
                devicesOpen = true
            } else if ProcessInfo.processInfo.arguments.contains("--desktop-preview") {
                model.destination = .desktop
                openWindow(id:"pc-desktop",value:"primary")
            } else if ProcessInfo.processInfo.arguments.contains("--lab-connect") {
                model.connectDesktop()
            }
            #endif
        }
        .onChange(of:scenePhase,initial:true) { _, phase in
            guard phase == .active, model.destination == .devices else { return }
            Task { @MainActor in
                if model.isImmersed { await closeSpace() }
                dismissWindow(id:"pc-desktop",value:"primary")
                model.transitionPending = false
            }
        }
        .onChange(of:streaming) { _, ready in
            if ready && !model.isImmersed { showDesktop() }
        }
    }

    private var home: some View {
        VStack(alignment:.leading,spacing:22) {
            VStack(alignment:.leading,spacing:6) {
                HStack {
                    Text("My Devices").font(.largeTitle.bold())
                    Spacer()
                    Button("Add Device",systemImage:"plus") { devicesOpen = true }
                        .disabled(model.devices.error != nil)
                }
            }
            if model.devices.hosts.count > 1 {
                Picker("Selected PC",selection:Binding(get:{ model.devices.selectedID ?? "" },set:{ id in
                    guard let host = model.devices.hosts.first(where:{ $0.id == id }) else { return }
                    model.stream.disconnect()
                    do { try model.devices.select(host); model.stream.refreshPairing() } catch { model.error = "Could not select this PC." }
                })) { ForEach(model.devices.hosts) { Text($0.name).tag($0.id) } }
            }
            if paired {
                HStack(spacing:20) {
                    Image(systemName:"desktopcomputer").font(.system(size:42))
                        .foregroundStyle(.mint).frame(width:74,height:84)
                    VStack(alignment:.leading,spacing:7) {
                        Text(model.devices.selected?.name ?? (pcName.isEmpty ? "Windows PC" : pcName)).font(.title2.bold())
                        HStack(spacing:7) {
                            Circle().fill(streaming ? Color.green : Color.secondary).frame(width:7,height:7)
                            Text(streaming ? connectedLabel : connecting ? "Connecting…" : "Selected · Windows")
                                .foregroundStyle(.secondary)
                        }
                        if connecting { ProgressView().controlSize(.small) }
                    }
                    Spacer()
                    if streaming {
                        Button("Connect",systemImage:"link") { showDesktop() }
                            .buttonStyle(.borderedProminent).tint(.mint).controlSize(.large)
                    } else {
                        Button(connecting ? "Cancel" : "Connect",systemImage:connecting ? "xmark" : "link") {
                            if connecting { model.stream.disconnect() } else { model.connectDesktop() }
                        }.buttonStyle(.borderedProminent).tint(.mint).controlSize(.large)
                            .disabled(!model.desktopConnectionAllowed)
                    }
                }.padding(20).background(.thinMaterial,in:RoundedRectangle(cornerRadius:24))
            } else {
                Text("No devices added").foregroundStyle(.secondary).padding(.vertical,24)
            }
            if let error = model.devices.error ?? model.error { Text(error).foregroundStyle(.orange) }
            if model.devices.error != nil {
                Button("Try Again") { model.devices.reload(); model.stream.refreshPairing() }
            }
            if let failure = model.stream.userMessage {
                Label(failure,systemImage:"exclamationmark.circle").foregroundStyle(.orange).font(.callout)
            }
        }
    }
    private var settings: some View {
        NavigationStack {
            Form {
                #if SPATIALPC_XR && canImport(FoveatedStreaming)
                if ProcessInfo.processInfo.arguments.contains("--manual-focus") { XRFocusSetup(model: model) }
                #endif
                Section("Windows host") {
                    Link("peterwang.tech/spatial-pc",destination:URL(string:"https://peterwang.tech/spatial-pc")!)
                    HStack {
                        Link("Support",destination:URL(string:"https://peterwang.tech/spatial-pc/support")!)
                        Spacer()
                        Link("Privacy",destination:URL(string:"https://peterwang.tech/spatial-pc/privacy")!)
                    }
                    Text("On your PC, download and install Spatial PC Host. Open it, enable access on a private network, and choose Pair Device. Keep both devices on that network.")
                }
                Section("Saved PCs") {
                    ForEach(model.devices.hosts) { host in
                        HStack {
                            Text(host.name); Spacer()
                            Button("Forget",role:.destructive) {
                                if model.devices.selectedID == host.id { model.stream.disconnect() }
                                do { try model.devices.forget(host); model.stream.refreshPairing() } catch { model.error = "Could not remove this PC." }
                            }
                        }
                    }
                    Text("To revoke access on the PC, remove this Vision Pro in the Windows host.").foregroundStyle(.secondary)
                }
                Section("Keyboard") {
                    Text("If Space and Tab navigate app controls, turn off Full Keyboard Access in visionOS Settings → Accessibility → Keyboards while using the remote desktop.")
                }
            }.navigationTitle("Settings")
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) {
                        Button("Close",systemImage:"xmark") { settingsOpen = false }
                            .labelStyle(.iconOnly).keyboardShortcut(.cancelAction)
                    }
                }
        }.frame(width:640,height:640)
    }
    private func showDesktop() {
        guard !model.transitionPending else { return }
        model.transitionPending = true
        model.destination = .desktop
        settingsOpen = false; devicesOpen = false
        openWindow(id:"pc-desktop",value:"primary")
    }

}
