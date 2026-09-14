import SwiftUI
import Observation

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
    var keyboardRequest = 0
    func handleScenePhase(_ phase: ScenePhase) {
        #if DEBUG
        if phase != .active { stream.stopControl() }
        #endif
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
