import SwiftUI
import RealityKit

/// Only the environment belongs to the Crown-controlled portal. The desktop
/// remains in its native window, so it stays visible even at zero immersion.
struct SpatialSurface: View {
    @Bindable var model: AppModel
    var body: some View {
        RealityView { content in
            if let environment = try? await FocusEnvironment.make() { content.add(environment) }
        }
        .onAppear { model.isImmersed = true }
        .onDisappear {
            model.isImmersed = false
            if model.destination == .focus { model.destination = .desktop }
            model.transitionPending = false
        }
    }
}
