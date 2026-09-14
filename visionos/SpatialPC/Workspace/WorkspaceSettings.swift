import Foundation

struct WorkspaceSettings: Codable {
    var distance: Float = 1.6
    var width: Float = 1.6
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "workspace.v1"),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.distance.isFinite, value.width.isFinite,
              value.distance > 0, value.width > 0 else { return .init() }
        return value
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "workspace.v1") }
    }
}
