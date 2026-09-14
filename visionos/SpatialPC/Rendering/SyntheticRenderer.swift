import Foundation
import Metal
import RealityKit
import QuartzCore
import Observation
import OSLog
import CoreVideo

@MainActor @Observable
final class SyntheticRenderer: NSObject {
    private(set) var material: UnlitMaterial?
    @ObservationIgnored private(set) var fps = 0.0
    @ObservationIgnored private(set) var gpuMilliseconds = 0.0
    @ObservationIgnored private(set) var submitMilliseconds = 0.0
    @ObservationIgnored private(set) var completedFrames = 0
    @ObservationIgnored private(set) var droppedTicks = 0
    private(set) var error: String?
    private(set) var dimensions = SIMD2(1920, 1080)
    private(set) var running = false
    private(set) var videoMode = false
    // Monotonic across reconnects: an old drawable must never suppress a new session's first frame.
    @ObservationIgnored private(set) var windowRevision: UInt64 = 0
    @ObservationIgnored private var firstVideoRevision: UInt64 = 0
    @ObservationIgnored private var latestVideo: RetainedFrame?
    @ObservationIgnored private var spatialVideoActive = false
    @ObservationIgnored private var renderGeneration = UUID()
    @ObservationIgnored private let metricsQueue = DispatchQueue(label:"SpatialPC.renderer-metrics",qos:.utility)
    @ObservationIgnored private var videoCache: CVMetalTextureCache?
    @ObservationIgnored private var texture: LowLevelTexture?
    @ObservationIgnored private var queue: MTLCommandQueue?
    @ObservationIgnored private var videoPipeline: MTLComputePipelineState?
    @ObservationIgnored private var pipeline: MTLComputePipelineState?
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var initializing = false
    @ObservationIgnored private var startTime = CACurrentMediaTime()
    @ObservationIgnored private var sampleStart = CACurrentMediaTime()
    @ObservationIgnored private var sampleFrames = 0
    @ObservationIgnored private var measurements: [Measurement] = []
    @ObservationIgnored private let logger = Logger(subsystem: "SpatialPC", category: "Renderer")

    struct Measurement: Codable {
        let elapsed: Double
        let submittedFPS: Double
        let gpuMS: Double
        let cpuSubmitMS: Double
        let completedFrames: Int
        let droppedTicks: Int
        let width: Int
        let height: Int
        let environment: String
        let source: String
        let presentationPath: String
    }

    func start(width: Int = 1920, height: Int = 1080) async {
        guard !running, !initializing else { return }
        initializing = true
        defer { initializing = false }
        do {
            guard width > 0, height > 0, let device = MTLCreateSystemDefaultDevice(),
                  let queue = device.makeCommandQueue(),
                  let kernel = device.makeDefaultLibrary()?.makeFunction(name: "syntheticPattern") else {
                throw RenderError.unavailable
            }
            renderGeneration = UUID(); inFlight = false; latestVideo = nil
            self.queue = queue
            pipeline = try await device.makeComputePipelineState(function: kernel)
            guard let videoKernel = device.makeDefaultLibrary()?.makeFunction(name:"videoToBGRA") else { throw RenderError.unavailable }
            videoPipeline = try await device.makeComputePipelineState(function:videoKernel)
            dimensions = SIMD2(width,height)
            let texture = try LowLevelTexture(descriptor: .init(pixelFormat: .bgra8Unorm,
                width: width, height: height, textureUsage: [.shaderRead,.shaderWrite]))
            self.texture = texture
            let resource = try await TextureResource(from: texture)
            var material = UnlitMaterial(applyPostProcessToneMap:false)
            material.color = .init(texture: .init(resource))
            self.material = material
            startTime = CACurrentMediaTime(); sampleStart = startTime
            completedFrames = 0; droppedTicks = 0; sampleFrames = 0; measurements = []
            error = nil; running = true
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 90, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        } catch { self.error = String(describing: error) }
    }

    // Use the producer queue so presentation reads follow texture writes on the GPU.
    func makeWindowFrame() -> (command: MTLCommandBuffer, texture: MTLTexture, chroma: MTLTexture?, conversion: VideoColorConversion)? {
        guard let command = queue?.makeCommandBuffer() else { return nil }
        if videoMode {
            guard let frame = latestVideo else { return nil }
            // Reading the decoder's IOSurface directly removes a full-frame intermediate blit.
            // Keep BOTH Core Video objects alive until the GPU finishes, even after reconnect.
            command.addCompletedHandler { [frame] _ in withExtendedLifetime(frame) {} }
            return (command,frame.texture,frame.chroma,frame.conversion)
        }
        guard let texture else { return nil }
        return (command,texture.read(),nil,VideoColorConversion())
    }
    func reportWindowError(_ message:String) { error = message }

    func ensureStarted() async {
        while initializing { await Task.yield() }
        if material == nil { await start() }
    }

    func resume() {
        guard !running, !videoMode, texture != nil else { return }
        sampleStart = CACurrentMediaTime(); sampleFrames = 0; running = true
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 90, preferred: 60)
        link.add(to: .main, forMode: .common); displayLink = link
    }

    func stop() { displayLink?.invalidate(); displayLink = nil; running = false; saveMeasurements() }

    func prepareVideo(width: Int, height: Int) async {
        stop()
        await start(width:width,height:height)
        stop(); videoMode = true; measurements = []
        firstVideoRevision = windowRevision &+ 1
        if let device = queue?.device { CVMetalTextureCacheCreate(nil,nil,device,nil,&videoCache) }
    }

    func endVideo() {
        if videoMode { saveMeasurements(); measurements = [] }
        renderGeneration = UUID(); inFlight = false; latestVideo = nil
        videoMode = false; stop()
    }

    private struct RetainedFrame: @unchecked Sendable {
        let mapped: [CVMetalTexture]
        let pixel: CVPixelBuffer
        let texture: MTLTexture
        let chroma: MTLTexture?
        let conversion: VideoColorConversion
        let revision: UInt64
    }

    func setSpatialVideoActive(_ active: Bool) {
        spatialVideoActive = active
        if active, let frame = latestVideo { copyToSpatialTexture(frame) }
    }

    func presentVideo(_ pixel: CVPixelBuffer) {
        guard videoMode, CVPixelBufferGetWidth(pixel) == dimensions.x,
              CVPixelBufferGetHeight(pixel) == dimensions.y, let videoCache else { return }
        var mapped: [CVMetalTexture] = []
        func map(_ plane: Int, _ format: MTLPixelFormat, _ width: Int, _ height: Int) -> MTLTexture? {
            var reference: CVMetalTexture?
            let result = CVMetalTextureCacheCreateTextureFromImage(nil,videoCache,pixel,nil,format,width,height,plane,&reference)
            guard result == kCVReturnSuccess, let reference, let texture = CVMetalTextureGetTexture(reference) else { return nil }
            mapped.append(reference); return texture
        }
        let conversion = VideoColorConversion(pixel:pixel)
        let source: MTLTexture?, chroma: MTLTexture?
        if conversion.options.x != 0 {
            guard CVPixelBufferGetPlaneCount(pixel) == 2 else { error = "Invalid video planes"; return }
            source = map(0,.r8Unorm,CVPixelBufferGetWidthOfPlane(pixel,0),CVPixelBufferGetHeightOfPlane(pixel,0))
            chroma = map(1,.rg8Unorm,CVPixelBufferGetWidthOfPlane(pixel,1),CVPixelBufferGetHeightOfPlane(pixel,1))
            guard chroma != nil else { error = "Could not map video chroma"; return }
        } else {
            source = map(0,.bgra8Unorm,dimensions.x,dimensions.y); chroma = nil
        }
        guard let source else { error = "Could not map decoded frame to Metal"; return }
        windowRevision &+= 1
        let frame = RetainedFrame(mapped:mapped,pixel:pixel,texture:source,chroma:chroma,conversion:conversion,revision:windowRevision)
        // A single replaceable decoded frame, not an unbounded presentation queue.
        latestVideo = frame
        if spatialVideoActive { copyToSpatialTexture(frame) }
    }

    private func copyToSpatialTexture(_ frame: RetainedFrame) {
        guard !inFlight else { droppedTicks += 1; return }
        guard let texture, let command = queue?.makeCommandBuffer() else { return }
        let begin = CACurrentMediaTime(), generation = renderGeneration
        if let chroma = frame.chroma {
            guard let videoPipeline, let encoder = command.makeComputeCommandEncoder() else { return }
            var conversion = frame.conversion
            encoder.setComputePipelineState(videoPipeline)
            encoder.setTexture(frame.texture,index:0); encoder.setTexture(chroma,index:1)
            encoder.setTexture(texture.replace(using:command),index:2)
            encoder.setBytes(&conversion,length:MemoryLayout<VideoColorConversion>.stride,index:0)
            let w = videoPipeline.threadExecutionWidth, h = max(1,videoPipeline.maxTotalThreadsPerThreadgroup/w)
            encoder.dispatchThreads(MTLSize(width:dimensions.x,height:dimensions.y,depth:1),threadsPerThreadgroup:MTLSize(width:w,height:h,depth:1))
            encoder.endEncoding()
        } else {
            guard let blit = command.makeBlitCommandEncoder() else { return }
            blit.copy(from:frame.texture,to:texture.replace(using:command)); blit.endEncoding()
        }
        inFlight = true
        let cpuMS = (CACurrentMediaTime()-begin)*1000
        command.addCompletedHandler { [weak self, frame] command in
            withExtendedLifetime(frame) {}
            let gpuMS = max(0,command.gpuEndTime-command.gpuStartTime)*1000
            let failed = command.status == .error
            Task { @MainActor in
                guard let self, self.renderGeneration == generation else { return }
                self.complete(cpuMS:cpuMS,gpuMS:gpuMS,failed:failed)
                // If decoding overtook the copy, submit the newest image instead of showing an old one.
                if !failed, self.videoMode, self.spatialVideoActive,
                   let latest = self.latestVideo, latest.revision != frame.revision {
                    self.copyToSpatialTexture(latest)
                }
            }
        }
        command.commit()
    }

    func windowPresentationCompleted(revision: UInt64, gpuMS: Double, cpuMS: Double, failed: Bool) {
        guard videoMode, !spatialVideoActive, let latestVideo,
              revision >= firstVideoRevision, revision <= latestVideo.revision else { return }
        // Window draw completion measures submitted GPU work, not headset scanout latency.
        recordCompletion(cpuMS:cpuMS,gpuMS:gpuMS,failed:failed)
    }

    @objc private func tick() {
        guard !inFlight else { droppedTicks += 1; return }
        guard let texture, let pipeline, let command = queue?.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return }
        inFlight = true
        let begin = CACurrentMediaTime(), generation = renderGeneration
        var time = Float(begin-startTime)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture.replace(using: command), index: 0)
        encoder.setBytes(&time, length: MemoryLayout<Float>.size, index: 0)
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup/w)
        encoder.dispatchThreads(MTLSize(width: dimensions.x,height: dimensions.y,depth: 1),
            threadsPerThreadgroup: MTLSize(width:w,height:h,depth:1))
        encoder.endEncoding()
        let cpuMS = (CACurrentMediaTime()-begin)*1000
        command.addCompletedHandler { [weak self] command in
            let gpuMS = max(0,command.gpuEndTime-command.gpuStartTime)*1000
            let failed = command.status == .error
            Task { @MainActor in
                guard let self, self.renderGeneration == generation else { return }
                self.windowRevision &+= 1
                self.complete(cpuMS:cpuMS,gpuMS:gpuMS,failed:failed)
            }
        }
        command.commit()
    }

    private func complete(cpuMS: Double, gpuMS: Double, failed: Bool) {
        inFlight = false
        recordCompletion(cpuMS:cpuMS,gpuMS:gpuMS,failed:failed)
    }

    private func recordCompletion(cpuMS: Double, gpuMS: Double, failed: Bool) {
        guard !failed else { error = "Metal command failed"; stop(); return }
        completedFrames += 1; sampleFrames += 1
        gpuMilliseconds = gpuMS; submitMilliseconds = cpuMS
        let now = CACurrentMediaTime()
        if now-sampleStart >= 1 {
            fps = Double(sampleFrames)/(now-sampleStart)
            #if targetEnvironment(simulator)
            let environment = "visionOS Simulator; not headset performance"
            #else
            let environment = "physical visionOS device"
            #endif
            let sample = Measurement(elapsed:now-startTime,submittedFPS:fps,gpuMS:gpuMS,cpuSubmitMS:cpuMS,
                completedFrames:completedFrames,droppedTicks:droppedTicks,width:dimensions.x,height:dimensions.y,
                environment:environment,source:videoMode ? "remote h264" : "synthetic",
                presentationPath:videoMode ? (spatialVideoActive ? "RealityKit texture copy" : "direct decoded texture window") : "synthetic texture")
            measurements.append(sample)
            if measurements.count > 300 { measurements.removeFirst() }
            logger.info("render fps=\(self.fps) gpu_ms=\(gpuMS) frames=\(self.completedFrames)")
            sampleFrames = 0; sampleStart = now; saveMeasurements()
        }
    }

    private func saveMeasurements() {
        guard let root = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else { return }
        let snapshot = measurements
        let url = root.appendingPathComponent(videoMode ? "stream-metrics.json" : "synthetic-metrics.json")
        metricsQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to:url,options:.atomic)
        }
    }
    enum RenderError: Error { case unavailable }
}
