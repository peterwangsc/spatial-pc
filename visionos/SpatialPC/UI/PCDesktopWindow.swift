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
        DesktopMetalSurface(model:model,aspect:aspect,keyboardRequest:model.keyboardRequest)
            .frame(minWidth:480,minHeight:480/aspect)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .overlay(alignment:.topLeading) { DesktopNavigationButton(model:model,action:.back).padding(12) }
            .overlay(alignment:.topTrailing) {
                HStack(spacing:8) {
                    #if DEBUG
                    if model.stream.textAvailable { DesktopKeyboardButton(model:model) }
                    #endif
                    DesktopNavigationButton(model:model,action:.focus)
                }.padding(12)
            }
            .task {
                // A restored desktop has no surviving network session after a cold launch.
                if !model.startupHandled { openWindow(id:"controls") }
                await model.renderer.ensureStarted()
            }
            .onDisappear {
                // Closing the desktop must not leave an empty immersive environment.
                #if DEBUG
                model.stream.stopControl()
                #endif
                guard model.destination == .focus else { return }
                Task { @MainActor in
                    if model.isImmersed { await closeSpace() }
                }
            }
            .onChange(of:scenePhase,initial:true) { _, phase in
                #if DEBUG
                if phase != .active { model.stream.stopControl() }
                #endif
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
    let model: AppModel
    let aspect: CGFloat
    let keyboardRequest: Int
    func makeUIView(context:Context) -> DesktopMetalView { DesktopMetalView(model:model,aspect:aspect) }
    func updateUIView(_ view:DesktopMetalView,context:Context) {
        view.setAspect(aspect)
        #if DEBUG
        view.updateKeyboardRequest(keyboardRequest)
        #endif
    }
    static func dismantleUIView(_ view:DesktopMetalView,coordinator:()) { view.isPaused = true; view.delegate = nil }
}

@MainActor private final class DesktopMetalView: MTKView, MTKViewDelegate, UIPointerInteractionDelegate {
    private let renderer: SyntheticRenderer
    private var pipeline: MTLRenderPipelineState?
    private var aspect: CGFloat
    private var appliedAspect: CGFloat?
    private var submittedFrame: UInt64?
    private var submittedSize = CGSize.zero
    private var inFlight = false
    #if DEBUG
    private var input: DesktopInputController?
    private var keyboardRequest = 0
    private var showsSystemKeyboard = false
    private let suppressedKeyboard = UIView(frame:.zero)
    #endif

    init(model:AppModel,aspect:CGFloat) {
        self.renderer = model.renderer; self.aspect = aspect
        super.init(frame:.zero,device:MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0,0,0,1)
        isOpaque = true; preferredFramesPerSecond = 60
        autoResizeDrawable = true; delegate = self
        isUserInteractionEnabled = true
        addInteraction(UIPointerInteraction(delegate:self))
        #if DEBUG
        input = DesktopInputController(view:self,stream:model.stream)
        #endif
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
        if window != nil { isPaused = false; applyGeometry() } else {
            isPaused = true
            #if DEBUG
            input?.stop()
            #endif
        }
    }
    #if DEBUG
    override var canBecomeFirstResponder: Bool { input?.available == true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        input?.keyboardFocusChanged(isFirstResponder); return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { input?.stop() }
        input?.keyboardFocusChanged(isFirstResponder); return accepted
    }
    override var inputView: UIView? { showsSystemKeyboard ? nil : suppressedKeyboard }
    func updateKeyboardRequest(_ request:Int) {
        guard input?.available == true else {
            keyboardRequest = request
            if showsSystemKeyboard || isFirstResponder {
                showsSystemKeyboard = false
                input?.keyboardPresentationChanged(false)
                _ = resignFirstResponder()
            }
            return
        }
        guard keyboardRequest != request else { return }
        keyboardRequest = request
        guard input?.textAvailable == true else { return }
        showsSystemKeyboard.toggle()
        input?.keyboardPresentationChanged(showsSystemKeyboard)
        guard input?.activateKeyboard() == true else { return }
        reloadInputViews()
    }
    override func canPerformAction(_ action:Selector,withSender sender:Any?) -> Bool { false }
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent?) { input?.touches(touches,event:event,phase:.began) }
    override func touchesMoved(_ touches:Set<UITouch>,with event:UIEvent?) { input?.touches(touches,event:event,phase:.moved) }
    override func touchesEnded(_ touches:Set<UITouch>,with event:UIEvent?) { input?.touches(touches,event:event,phase:.ended) }
    override func touchesCancelled(_ touches:Set<UITouch>,with event:UIEvent?) { input?.stop() }
    override func pressesBegan(_ presses:Set<UIPress>,with event:UIPressesEvent?) {
        if input?.presses(presses,down:true) != true { super.pressesBegan(presses,with:event) }
    }
    override func pressesEnded(_ presses:Set<UIPress>,with event:UIPressesEvent?) {
        if input?.presses(presses,down:false) != true { super.pressesEnded(presses,with:event) }
    }
    override func pressesCancelled(_ presses:Set<UIPress>,with event:UIPressesEvent?) { input?.stop() }
    #endif
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
    func pointerInteraction(_ interaction:UIPointerInteraction, regionFor request:UIPointerRegionRequest,
                            defaultRegion:UIPointerRegion) -> UIPointerRegion? {
        // The decoded image is a pointer surface, not just its overlaid buttons.
        UIPointerRegion(rect:bounds,identifier:"desktop" as NSString)
    }
    func pointerInteraction(_ interaction:UIPointerInteraction, styleFor region:UIPointerRegion) -> UIPointerStyle? {
        .system()
    }
    func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize) { submittedFrame = nil }
    func draw(in view:MTKView) {
        guard !inFlight, let pipeline,
              submittedFrame != renderer.windowRevision || submittedSize != drawableSize,
              let frame = renderer.makeWindowFrame(),
              let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let encoder = frame.command.makeRenderCommandEncoder(descriptor:pass) else { return }
        let begin = CACurrentMediaTime()
        let revision = renderer.windowRevision
        inFlight = true; submittedFrame = revision; submittedSize = drawableSize
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(frame.texture,index:0)
        encoder.setFragmentTexture(frame.chroma ?? frame.texture,index:1)
        var conversion = frame.conversion
        encoder.setFragmentBytes(&conversion,length:MemoryLayout<VideoColorConversion>.stride,index:0)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3)
        encoder.endEncoding()
        frame.command.present(drawable)
        let cpuMS = (CACurrentMediaTime()-begin)*1000
        frame.command.addCompletedHandler { [weak self] command in
            let failed = command.status == .error
            let gpuMS = max(0,command.gpuEndTime-command.gpuStartTime)*1000
            Task { @MainActor in
                self?.inFlight = false
                self?.renderer.windowPresentationCompleted(revision:revision,gpuMS:gpuMS,cpuMS:cpuMS,failed:failed)
                if failed { self?.submittedFrame = nil; self?.renderer.reportWindowError("Desktop presentation failed.") }
            }
        }
        frame.command.commit()
    }
}

#if DEBUG
extension DesktopMetalView: UIKeyInput {
    var hasText: Bool { true } // Remote selection is unknown; always permit Delete.
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
    func insertText(_ text:String) { input?.insertText(text) }
    func deleteBackward() { input?.deleteBackward() }
}
#endif
