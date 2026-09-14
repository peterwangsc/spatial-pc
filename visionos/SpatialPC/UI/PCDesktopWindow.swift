import SwiftUI
import MetalKit

/// A native 2D drawable fills the window exactly; no inset 3D plane or app chrome.
struct PCDesktopWindow: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismissImmersiveSpace) private var closeSpace
    private var aspect: CGFloat { CGFloat(model.renderer.dimensions.x) / CGFloat(model.renderer.dimensions.y) }

    var body: some View {
        DesktopMetalSurface(renderer:model.renderer,aspect:aspect)
            .frame(minWidth:480,minHeight:480/aspect)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .overlay(alignment:.topLeading) { DesktopNavigationButton(model:model,action:.back).padding(12) }
            .overlay(alignment:.topTrailing) { DesktopNavigationButton(model:model,action:.focus).padding(12) }
            .task {
                // A restored desktop has no surviving network session after a cold launch.
                if !model.startupHandled { openWindow(id:"controls") }
                await model.renderer.ensureStarted()
            }
            .onChange(of:scenePhase,initial:true) { _, phase in
                guard phase == .active, model.destination == .desktop else { return }
                Task { @MainActor in
                    if model.isImmersed { await closeSpace() }
                    dismissWindow(id:"controls")
                    model.transitionPending = false
                }
            }
    }
}

private struct DesktopMetalSurface: UIViewRepresentable {
    let renderer: SyntheticRenderer
    let aspect: CGFloat
    func makeUIView(context:Context) -> DesktopMetalView { DesktopMetalView(renderer:renderer,aspect:aspect) }
    func updateUIView(_ view:DesktopMetalView,context:Context) { view.setAspect(aspect) }
    static func dismantleUIView(_ view:DesktopMetalView,coordinator:()) { view.isPaused = true; view.delegate = nil }
}

@MainActor private final class DesktopMetalView: MTKView, MTKViewDelegate {
    private let renderer: SyntheticRenderer
    private var pipeline: MTLRenderPipelineState?
    private var aspect: CGFloat
    private var appliedAspect: CGFloat?
    private var submittedFrame = -1
    private var submittedSize = CGSize.zero
    private var inFlight = false

    init(renderer:SyntheticRenderer,aspect:CGFloat) {
        self.renderer = renderer; self.aspect = aspect
        super.init(frame:.zero,device:MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0,0,0,1)
        isOpaque = true; preferredFramesPerSecond = 60
        autoResizeDrawable = true; delegate = self
        do {
            guard let device, let library = device.makeDefaultLibrary() else { return }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name:"desktopVertex")
            descriptor.fragmentFunction = library.makeFunction(name:"desktopFragment")
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor:descriptor)
        } catch { renderer.reportWindowError("Could not create the desktop surface: \(error)") }
    }
    required init(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        appliedAspect = nil
        if window != nil { isPaused = false; applyGeometry() } else { isPaused = true }
    }
    func setAspect(_ value:CGFloat) {
        guard value.isFinite, value > 0 else { return }
        aspect = value; applyGeometry()
    }
    private func applyGeometry() {
        guard let scene = window?.windowScene, appliedAspect != aspect else { return }
        appliedAspect = aspect
        let width = max(480,scene.coordinateSpace.bounds.width)
        scene.requestGeometryUpdate(.Vision(size:CGSize(width:width,height:width/aspect),
            minimumSize:CGSize(width:480,height:480/aspect),resizingRestrictions:.uniform)) { [weak self] error in
                Task { @MainActor in self?.renderer.reportWindowError("Could not match the desktop window size: \(error)") }
            }
    }
    func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize) { submittedFrame = -1 }
    func draw(in view:MTKView) {
        guard !inFlight, let pipeline,
              submittedFrame != renderer.completedFrames || submittedSize != drawableSize,
              let frame = renderer.makeWindowFrame(),
              let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let encoder = frame.command.makeRenderCommandEncoder(descriptor:pass) else { return }
        inFlight = true; submittedFrame = renderer.completedFrames; submittedSize = drawableSize
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(frame.texture,index:0)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3)
        encoder.endEncoding()
        frame.command.present(drawable)
        frame.command.addCompletedHandler { [weak self] command in
            let failed = command.status == .error
            Task { @MainActor in
                self?.inFlight = false
                if failed { self?.submittedFrame = -1; self?.renderer.reportWindowError("Desktop presentation failed.") }
            }
        }
        frame.command.commit()
    }
}
