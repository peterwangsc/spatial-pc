import RealityKit
import UIKit

/// A quiet, static backdrop. One small texture and two unlit meshes keep the
/// environment inexpensive while the desktop is decoding and presenting.
@MainActor enum FocusEnvironment {
    static func make() async throws -> Entity {
        let root = Entity()
        root.name = "Focus Environment"
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size:CGSize(width:1024,height:512),format:format).image { context in
            let colors = [
                UIColor(red:0.065,green:0.080,blue:0.115,alpha:1).cgColor,
                UIColor(red:0.16,green:0.19,blue:0.23,alpha:1).cgColor,
                UIColor(red:0.095,green:0.11,blue:0.14,alpha:1).cgColor
            ]
            if let gradient = CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB),
                                         colors:colors as CFArray,locations:[0,0.53,1]) {
                context.cgContext.drawLinearGradient(gradient,start:.zero,end:CGPoint(x:0,y:512),options:[])
            }
        }
        guard let cgImage = image.cgImage else { throw CocoaError(.coderInvalidValue) }
        let texture = try await TextureResource(image:cgImage,options:.init(semantic:.color))
        var skyMaterial = UnlitMaterial(applyPostProcessToneMap:false)
        skyMaterial.color = .init(texture:.init(texture))
        let sky = ModelEntity(mesh:.generateSphere(radius:60),materials:[skyMaterial])
        sky.scale = [-1,1,1] // See the inside of the dome.
        root.addChild(sky)
        var floorMaterial = UnlitMaterial(applyPostProcessToneMap:false)
        floorMaterial.color = .init(tint:UIColor(red:0.10,green:0.12,blue:0.15,alpha:1))
        let floor = ModelEntity(mesh:.generatePlane(width:100,depth:100),materials:[floorMaterial])
        floor.position.y = -0.02
        root.addChild(floor)
        return root
    }
}
