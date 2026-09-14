import SwiftUI
import RealityKit

struct SpatialSurface: View {
    @Bindable var model: AppModel
    private var displayHeight: Float { model.workspace.width * Float(model.renderer.dimensions.y) / Float(model.renderer.dimensions.x) }
    var body: some View {
        RealityView { content, attachments in
            await model.renderer.ensureStarted()
            if let material = model.renderer.material {
                let plane = ModelEntity(mesh:.generatePlane(width:model.workspace.width,height:displayHeight),materials:[material])
                plane.position = [0,1.45,-model.workspace.distance]
                if #available(visionOS 26.0, *) {
                    ManipulationComponent.configureEntity(plane,collisionShapes:[.generateBox(
                        width:model.workspace.width,height:displayHeight,depth:0.015)])
                    if var manipulation = plane.components[ManipulationComponent.self] {
                        manipulation.releaseBehavior = .stay
                        manipulation.dynamics.translationBehavior = .unconstrained
                        manipulation.dynamics.scalingBehavior = .unconstrained
                        manipulation.dynamics.primaryRotationBehavior = .none
                        manipulation.dynamics.secondaryRotationBehavior = .none
                        manipulation.dynamics.inertia = .zero
                        plane.components.set(manipulation)
                    }
                }
                // Keep controls in front of the display collision box so manipulation cannot steal taps.
                if let back = attachments.entity(for:"back") {
                    back.position = [-model.workspace.width/2+0.05,displayHeight/2-0.05,0.025]
                    plane.addChild(back)
                }
                if let focus = attachments.entity(for:"focus") {
                    focus.position = [model.workspace.width/2-0.05,displayHeight/2-0.05,0.025]
                    plane.addChild(focus)
                }
                model.spatialDisplay = plane
                content.add(plane)
            }
        } update: { content, _ in
            if let plane = content.entities.first as? ModelEntity, let material = model.renderer.material {
                plane.model?.materials = [material]
            }
        } attachments: {
            Attachment(id:"back") { DesktopNavigationButton(model:model,action:.back) }
            Attachment(id:"focus") { DesktopNavigationButton(model:model,action:.focus) }
        }
        .onAppear { model.isImmersed = true; model.renderer.setSpatialVideoActive(true) }
        .onDisappear { model.renderer.setSpatialVideoActive(false); model.isImmersed = false; model.spatialDisplay = nil }
    }
}

struct SpatialDisplayControls: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            if #available(visionOS 26.0, *) {
                Text("Look at the display and pinch-drag to move it. Pinch with both hands and move them apart or together to resize.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Smaller",systemImage:"minus.magnifyingglass") { model.scaleSpatialDisplay(1/1.15) }
                Button("Larger",systemImage:"plus.magnifyingglass") { model.scaleSpatialDisplay(1.15) }
                Button("Closer") { model.moveSpatialDisplay([0,0,0.15]) }
                Button("Farther") { model.moveSpatialDisplay([0,0,-0.15]) }
                Button("Reset Position",systemImage:"arrow.counterclockwise") { model.resetSpatialDisplay() }
            }.controlSize(.small)
            HStack {
                Button("Left",systemImage:"arrow.left") { model.moveSpatialDisplay([-0.1,0,0]) }
                Button("Right",systemImage:"arrow.right") { model.moveSpatialDisplay([0.1,0,0]) }
                Button("Up",systemImage:"arrow.up") { model.moveSpatialDisplay([0,0.1,0]) }
                Button("Down",systemImage:"arrow.down") { model.moveSpatialDisplay([0,-0.1,0]) }
            }.controlSize(.small)
        }
    }
}
