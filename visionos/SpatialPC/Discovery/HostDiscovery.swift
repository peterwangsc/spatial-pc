import Foundation
import Network
import Observation

@MainActor @Observable
final class HostDiscovery {
    private(set) var hosts: [String] = []
    private(set) var status = "Search for a PC running Spatial PC Host."
    @ObservationIgnored private var browser: NWBrowser?
    func start() {
        stop()
        let browser = NWBrowser(for: .bonjour(type: "_spatialpc._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                if case .service(let name, _, _, _) = result.endpoint { return name }; return nil
            }.sorted()
            Task { @MainActor in self?.hosts = names; self?.status = names.isEmpty ? "No hosts found yet." : "Hosts found. Pairing is the next milestone." }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { Task { @MainActor in self?.status = "Discovery failed: \(error)" } }
        }
        self.browser = browser; status = "Searching local network…"; browser.start(queue:.main)
    }
    func stop() { browser?.cancel(); browser = nil }
}
