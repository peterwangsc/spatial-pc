import SwiftUI
import Observation

@MainActor @Observable
final class AppModel {
    let renderer = SyntheticRenderer()
    let discovery = HostDiscovery()
    let devices = PairedHostStore()
    let pairing = PairingClient()
    #if canImport(FoveatedStreaming)
    let xrFocus = XRFocusSession()
    private var applicationActive = true
    func restoreDesktopAfterXR() {
        if applicationActive { connectDesktop() }
        else { reconnectOnForeground = true }
    }
    #endif
    private var reconnectOnForeground = false
    var isImmersed = false
    var transitionPending = false
    var startupHandled = false
    enum Destination { case devices, desktop, focus }
    var destination = Destination.devices
    var error: String?
    var keyboardRequest = 0
    var desktopConnectionAllowed: Bool {
        #if canImport(FoveatedStreaming)
        return !xrFocus.gate.busy
        #else
        return true
        #endif
    }
    func connectDesktop() {
        guard desktopConnectionAllowed else { return }
        error = nil
        stream.connect()
    }
    func cancelDesktopRestoration() { reconnectOnForeground = false }
    func handleScenePhase(_ phase: ScenePhase) {
        #if canImport(FoveatedStreaming)
        applicationActive = phase == .active
        if phase == .background {
            let focusWasActive = xrFocus.gate.busy
            xrFocus.stop()
            // Permission may still be pending before the ordinary stream was
            // paused. Do not keep that desktop/input session alive while away.
            if focusWasActive {
                reconnectOnForeground = false
                stream.stopControl(); stream.disconnect(); renderer.stop()
            }
        }
        #endif
        if phase != .active { stream.stopControl() }
        if phase == .background && !transitionPending {
            reconnectOnForeground = reconnectOnForeground || stream.active
            stream.disconnect()
            renderer.stop()
        } else if phase == .active {
            if devices.error != nil { devices.reload() }
            if reconnectOnForeground && desktopConnectionAllowed { reconnectOnForeground = false; connectDesktop() }
            if !stream.active { stream.refreshPairing() }
        }
    }
    let stream: DesktopStreamClient
    init() { stream = DesktopStreamClient(renderer:renderer,devices:devices) }
}
