import SwiftUI

@main
struct SpatialPCApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup(id:"controls") {
            ControlCenter(model: model)
        }
        .defaultSize(width: 900, height: 680)
        .onChange(of:scenePhase) { _, phase in model.handleScenePhase(phase) }
        WindowGroup("PC Desktop",id:"pc-desktop",for:String.self) { _ in
            PCDesktopWindow(model:model)
        } defaultValue: { "primary" }
        .defaultSize(width:1100,height:619)
        .windowStyle(.plain)
        .windowResizability(.contentMinSize)
        ImmersiveSpace(id: "workspace") {
            SpatialSurface(model: model)
        }
        .immersionStyle(selection: .constant(.progressive(0...1, initialAmount:0.5)), in: .progressive)
    }
}
