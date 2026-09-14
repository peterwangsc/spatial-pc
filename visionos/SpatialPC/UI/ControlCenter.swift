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

    private var paired: Bool {
        #if DEBUG
        model.stream.available
        #else
        false
        #endif
    }
    private var streaming: Bool {
        #if DEBUG
        model.stream.active && model.stream.receivedFrames > 0
        #else
        false
        #endif
    }
    private var connecting: Bool {
        #if DEBUG
        model.stream.active && !streaming
        #else
        false
        #endif
    }
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
        .sheet(isPresented:$devicesOpen) { deviceSetup }
        .task {
            guard !model.startupHandled else { return }
            model.startupHandled = true
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--desktop-preview") {
                model.destination = .desktop
                openWindow(id:"pc-desktop",value:"primary")
            } else if ProcessInfo.processInfo.arguments.contains("--lab-connect") {
                model.stream.connect()
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
                }
            }
            if paired {
                HStack(spacing:20) {
                    Image(systemName:"desktopcomputer").font(.system(size:42))
                        .foregroundStyle(.mint).frame(width:74,height:84)
                    VStack(alignment:.leading,spacing:7) {
                        Text(pcName.isEmpty ? "Windows PC" : pcName).font(.title2.bold())
                        HStack(spacing:7) {
                            Circle().fill(streaming ? Color.green : Color.secondary).frame(width:7,height:7)
                            Text(streaming ? "Connected securely · View only" : connecting ? "Connecting…" : "Selected · Windows")
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
                            #if DEBUG
                            if connecting { model.stream.disconnect() } else { model.stream.connect() }
                            #endif
                        }.buttonStyle(.borderedProminent).tint(.mint).controlSize(.large)
                    }
                }.padding(20).background(.thinMaterial,in:RoundedRectangle(cornerRadius:24))
            } else {
                Text("No devices added").foregroundStyle(.secondary).padding(.vertical,24)
            }
            #if DEBUG
            if let failure = model.stream.userMessage {
                Label(failure,systemImage:"exclamationmark.circle").foregroundStyle(.orange).font(.callout)
            }
            #endif
        }
    }
    private var setup: some View {
        VStack(alignment:.leading,spacing:20) {
            Text("Windows PCs").font(.title2.bold())
            Text("Pairing is not available in this preview.").foregroundStyle(.secondary)
            Button("Find PCs",systemImage:"network") { model.discovery.start() }
                .buttonStyle(.borderedProminent).tint(.mint)
            Text(model.discovery.status).font(.callout).foregroundStyle(.secondary)
            ForEach(model.discovery.hosts,id:\.self) { Label($0,systemImage:"desktopcomputer") }
        }
    }
    private var deviceSetup: some View {
        NavigationStack {
            ScrollView { setup.padding(28) }
                .navigationTitle("Add Device")
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { devicesOpen = false } } }
        }.frame(width:640,height:620)
    }
    private var settings: some View {
        NavigationStack {
            Form {
                Section("Windows host") {
                    Text("1. Open the download page on your Windows PC.")
                    Link("peterwang.tech/spatial-pc",destination:URL(string:"https://peterwang.tech/spatial-pc")!)
                    Text("2. Download and install Spatial PC Host when it becomes available.")
                    Text("3. Open the host and follow its pairing steps.")
                    Text("The Windows installer is not available yet.").foregroundStyle(.secondary)
                }
            }.navigationTitle("Settings")
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { settingsOpen = false } } }
        }.frame(width:580,height:520)
    }
    private func showDesktop() {
        guard !model.transitionPending else { return }
        model.transitionPending = true
        model.destination = .desktop
        settingsOpen = false; devicesOpen = false
        openWindow(id:"pc-desktop",value:"primary")
    }

}
