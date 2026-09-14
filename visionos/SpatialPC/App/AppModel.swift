import SwiftUI
import Observation

@MainActor @Observable
final class AppModel {
    let renderer = SyntheticRenderer()
    let discovery = HostDiscovery()
    let devices = PairedHostStore()
    let pairing = PairingClient()
    private var reconnectOnForeground = false
    var isImmersed = false
    var transitionPending = false
    var startupHandled = false
    enum Destination { case devices, desktop, focus }
    var destination = Destination.devices
    var error: String?
    var keyboardRequest = 0
    func handleScenePhase(_ phase: ScenePhase) {
        if phase != .active { stream.stopControl() }
        if phase == .background && !transitionPending {
            reconnectOnForeground = stream.active
            stream.disconnect()
            renderer.stop()
        } else if phase == .active {
            if devices.error != nil { devices.reload() }
            if reconnectOnForeground { reconnectOnForeground = false; stream.connect() }
            if !stream.active { stream.refreshPairing() }
        }
    }
    let stream: DesktopStreamClient
    init() { stream = DesktopStreamClient(renderer:renderer,devices:devices) }
}
