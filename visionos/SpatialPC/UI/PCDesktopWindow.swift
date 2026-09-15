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
            .opacity(model.stream.hasFrames ? 1 : 0)
            .background(.black)
            .overlay {
                if !model.stream.hasFrames || focusOpening {
                    VStack(spacing:16) {
                        #if SPATIALPC_XR && canImport(FoveatedStreaming)
                        if model.xrFocus.gate.busy {
                            ProgressView()
                            Text(model.xrFocus.stage)
                            Button("Cancel") { model.xrFocus.stop() }
                        } else {
                            desktopRecovery
                        }
                        #else
                        desktopRecovery
                        #endif
                    }.padding(28).background(.regularMaterial,in:RoundedRectangle(cornerRadius:24))
                }
            }
            .overlay(alignment:.topLeading) { DesktopNavigationButton(model:model,action:.back).padding(12) }
            .overlay(alignment:.topTrailing) {
                HStack(spacing:8) {
                    if model.stream.textAvailable { DesktopKeyboardButton(model:model) }
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
                model.stream.stopControl()
                #if SPATIALPC_XR && canImport(FoveatedStreaming)
                if model.xrFocus.gate.busy && model.destination != .focus {
                    model.xrFocus.returnToDesktop = false
                    model.cancelDesktopRestoration()
                    model.xrFocus.gate.stop()
                }
                #endif
                guard model.destination == .focus else { return }
                Task { @MainActor in
                    if model.isImmersed { await closeSpace() }
                }
            }
            .onChange(of:scenePhase,initial:true) { _, phase in
                if phase != .active { model.stream.stopControl() }
                guard phase == .active, model.destination == .desktop else { return }
                Task { @MainActor in
                    if model.isImmersed { await closeSpace() }
                    dismissWindow(id:"controls")
                    model.transitionPending = false
                }
            }
    }
    private var focusOpening: Bool {
        #if SPATIALPC_XR && canImport(FoveatedStreaming)
        return model.xrFocus.gate.phase == .connecting || model.xrFocus.gate.phase == .stopping
        #else
        return false
        #endif
    }
    @ViewBuilder private var desktopRecovery: some View {
        if model.stream.active { ProgressView(); Text("Reconnecting to your PC…") }
        else {
            Text(model.error ?? model.stream.userMessage ?? "Desktop disconnected")
            Button("Reconnect",systemImage:"arrow.clockwise") { model.connectDesktop() }
                .disabled(!model.desktopConnectionAllowed)
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
        view.updateKeyboardRequest(keyboardRequest)
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
    private var input: DesktopInputController?
    private var keyboardRequest = 0
    private var showsSystemKeyboard = false
    private let suppressedKeyboard = UIView(frame:.zero)

    init(model:AppModel,aspect:CGFloat) {
        self.renderer = model.renderer; self.aspect = aspect
        super.init(frame:.zero,device:MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0,0,0,1)
        isOpaque = true; preferredFramesPerSecond = 60
        autoResizeDrawable = true; delegate = self
        isUserInteractionEnabled = true
        addInteraction(UIPointerInteraction(delegate:self))
        input = DesktopInputController(view:self,stream:model.stream)
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
            input?.stop()
        }
    }
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
    // UIKit reserves Tab/Space for local focus navigation ahead of raw presses.
    // Claim only those commands, and only while this remote surface owns input.
    private lazy var desktopKeyCommands: [UIKeyCommand] = {
        [" ", "\t"].flatMap { character in
            [UIKeyModifierFlags(), .shift].map { modifiers in
                let command = UIKeyCommand(input:character,modifierFlags:modifiers,
                                           action:#selector(forwardNavigationKey(_:)))
                command.wantsPriorityOverSystemBehavior = true
                command.allowsAutomaticLocalization = false
                return command
            }
        }
    }()
    override var keyCommands: [UIKeyCommand]? {
        input?.available == true && isFirstResponder ? desktopKeyCommands : nil
    }
    @objc private func forwardNavigationKey(_ command:UIKeyCommand) {
        input?.navigationKeyCommand(command)
    }
    override func canPerformAction(_ action:Selector,withSender sender:Any?) -> Bool {
        action == #selector(forwardNavigationKey(_:)) && input?.available == true && isFirstResponder
    }
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent?) { input?.touches(touches,event:event,phase:.began) }
    override func touchesMoved(_ touches:Set<UITouch>,with event:UIEvent?) { input?.touches(touches,event:event,phase:.moved) }
    override func touchesEnded(_ touches:Set<UITouch>,with event:UIEvent?) { input?.touches(touches,event:event,phase:.ended) }
    override func touchesCancelled(_ touches:Set<UITouch>,with event:UIEvent?) { input?.stop() }
    private func commandPresses(in presses:Set<UIPress>) -> Set<UIPress> {
        Set(presses.filter { press in
            guard let key = press.key, key.keyCode == .keyboardSpacebar || key.keyCode == .keyboardTab else { return false }
            return key.modifierFlags.intersection([.control,.alternate,.command]).isEmpty
        })
    }
    override func pressesBegan(_ presses:Set<UIPress>,with event:UIPressesEvent?) {
        let commands = commandPresses(in:presses), physical = presses.subtracting(commands)
        if !physical.isEmpty, input?.presses(physical,down:true) != true { super.pressesBegan(physical,with:event) }
        // Allow UIKit to dispatch the priority commands instead of consuming
        // their raw presses and potentially forwarding the same key twice.
        if !commands.isEmpty { super.pressesBegan(commands,with:event) }
    }
    override func pressesEnded(_ presses:Set<UIPress>,with event:UIPressesEvent?) {
        let commands = commandPresses(in:presses), physical = presses.subtracting(commands)
        if !physical.isEmpty, input?.presses(physical,down:false) != true { super.pressesEnded(physical,with:event) }
        if !commands.isEmpty { super.pressesEnded(commands,with:event) }
    }
    override func pressesCancelled(_ presses:Set<UIPress>,with event:UIPressesEvent?) { input?.stop() }
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
