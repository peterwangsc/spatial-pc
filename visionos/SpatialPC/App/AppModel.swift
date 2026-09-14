import SwiftUI
import Observation
import RealityKit

@MainActor @Observable
final class AppModel {
    let renderer = SyntheticRenderer()
    let discovery = HostDiscovery()
    var isImmersed = false
    var transitionPending = false
    var startupHandled = false
    enum Destination { case devices, desktop, focus }
    var destination = Destination.devices
    var error: String?
    var workspace = WorkspaceSettings.load()
    @ObservationIgnored var spatialDisplay: ModelEntity?
    func scaleSpatialDisplay(_ factor: Float) {
        guard factor.isFinite, factor > 0, let spatialDisplay else { return }
        let scale = spatialDisplay.scale * factor
        guard scale.x.isFinite, scale.y.isFinite, scale.z.isFinite, scale.x > 0 else { return }
        spatialDisplay.scale = scale
    }
    func moveSpatialDisplay(_ offset: SIMD3<Float>) { spatialDisplay?.position += offset }
    func resetSpatialDisplay() {
        spatialDisplay?.transform = Transform(scale:.one,rotation:simd_quatf(angle:0,axis:[0,1,0]),translation:[0,1.45,-workspace.distance])
    }
    func handleScenePhase(_ phase: ScenePhase) {
        if phase == .background && !transitionPending {
            #if DEBUG
            stream.disconnect()
            #endif
            renderer.stop()
        } else if phase == .active {
            renderer.resume()
            #if DEBUG
            if !stream.active { stream.refreshPairing() }
            #endif
        }
    }
    #if DEBUG
    let stream: LabStreamClient
    init() { stream = LabStreamClient(renderer:renderer) }
    #endif
}
