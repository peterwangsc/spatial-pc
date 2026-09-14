import Foundation
import Network
import Observation

struct DiscoveredHost:Identifiable,Hashable {
    let name:String
    let domain:String
    var id:String { name + "." + domain }
    var endpoint:NWEndpoint { .service(name:name,type:"_spatialpc-pair._tcp",domain:domain,interface:nil) }
}

@MainActor @Observable final class HostDiscovery {
    private(set) var hosts:[DiscoveredHost] = []
    private(set) var status = "Open Pair Device in the Windows host."
    @ObservationIgnored private var browser:NWBrowser?
    @ObservationIgnored private var searchStatus:Task<Void,Never>?
    @ObservationIgnored private var generation = UUID()
    func start() {
        stop(); let session = generation
        let browser = NWBrowser(for:.bonjour(type:"_spatialpc-pair._tcp",domain:"local."),using:.tcp)
        browser.browseResultsChangedHandler = { [weak self] results,_ in
            let hosts = results.compactMap { result -> DiscoveredHost? in
                guard case .service(let name,_,let domain,_) = result.endpoint,
                      !name.isEmpty,name.utf8.count <= 255,domain.utf8.count <= 255 else { return nil }
                return DiscoveredHost(name:name,domain:domain)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor in
                guard let self,self.generation == session else { return }
                self.hosts = hosts; self.status = hosts.isEmpty ? "No PCs ready to pair. Open Pair Device on your PC." : "Choose your PC."
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            let unavailable:Bool
            switch state { case .failed,.waiting: unavailable = true; default: unavailable = false }
            if unavailable {
                Task { @MainActor in
                    guard let self,self.generation == session else { return }
                    self.status = "Allow Local Network access in Settings, then search again."
                }
            }
        }
        self.browser = browser; status = "Searching…"; browser.start(queue:.main)
        searchStatus = Task { [weak self] in
            do { try await Task.sleep(for:.seconds(3)) } catch { return }
            guard let self,self.generation == session,self.hosts.isEmpty,self.status == "Searching…" else { return }
            self.status = "No PCs ready to pair. Open Pair Device on your PC."
        }
    }
    func stop() { searchStatus?.cancel(); searchStatus = nil; generation = UUID(); browser?.cancel(); browser = nil; hosts = [] }
}
