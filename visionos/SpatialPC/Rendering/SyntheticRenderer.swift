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
    private(set) var fps = 0.0
    private(set) var gpuMilliseconds = 0.0
    private(set) var submitMilliseconds = 0.0
    private(set) var completedFrames = 0
    private(set) var droppedTicks = 0
    private(set) var error: String?
    private(set) var dimensions = SIMD2(1920, 1080)
    private(set) var running = false
    private(set) var videoMode = false
    @ObservationIgnored private var videoCache: CVMetalTextureCache?
    @ObservationIgnored private var texture: LowLevelTexture?
    @ObservationIgnored private var queue: MTLCommandQueue?
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
            self.queue = queue
            pipeline = try await device.makeComputePipelineState(function: kernel)
            dimensions = SIMD2(width,height)
            let texture = try LowLevelTexture(descriptor: .init(pixelFormat: .bgra8Unorm,
                width: width, height: height, textureUsage: [.shaderRead,.shaderWrite]))
            self.texture = texture
            let resource = try await TextureResource(from: texture)
            var material = UnlitMaterial()
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
    func makeWindowFrame() -> (command: MTLCommandBuffer, texture: MTLTexture)? {
        guard let texture, let command = queue?.makeCommandBuffer() else { return nil }
        return (command,texture.read())
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
        if let device = queue?.device { CVMetalTextureCacheCreate(nil,nil,device,nil,&videoCache) }
    }

    func endVideo() {
        if videoMode { saveMeasurements(); measurements = [] }
        videoMode = false; resume()
    }

    private struct RetainedFrame: @unchecked Sendable {
        let mapped: CVMetalTexture
        let pixel: CVPixelBuffer
    }
    func presentVideo(_ pixel: CVPixelBuffer) {
        guard videoMode, CVPixelBufferGetWidth(pixel) == dimensions.x,
              CVPixelBufferGetHeight(pixel) == dimensions.y else { return }
        guard !inFlight else { droppedTicks += 1; return }
        guard let videoCache, let texture, let command = queue?.makeCommandBuffer() else { return }
        let begin = CACurrentMediaTime()
        var mapped: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(nil,videoCache,pixel,nil,.bgra8Unorm,
            dimensions.x,dimensions.y,0,&mapped)
        guard result == kCVReturnSuccess, let mapped, let source = CVMetalTextureGetTexture(mapped),
              let blit = command.makeBlitCommandEncoder() else { error = "Could not map decoded frame to Metal"; return }
        inFlight = true
        blit.copy(from:source,to:texture.replace(using:command)); blit.endEncoding()
        let cpuMS = (CACurrentMediaTime()-begin)*1000
        let retained = RetainedFrame(mapped:mapped,pixel:pixel)
        command.addCompletedHandler { [weak self, retained] command in
            // Core Video objects must remain alive until the GPU finishes reading.
            withExtendedLifetime(retained) {}
            let gpuMS = max(0,command.gpuEndTime-command.gpuStartTime)*1000
            let failed = command.status == .error
            Task { @MainActor in self?.complete(cpuMS:cpuMS,gpuMS:gpuMS,failed:failed) }
        }
        command.commit()
    }

    @objc private func tick() {
        guard !inFlight else { droppedTicks += 1; return }
        guard let texture, let pipeline, let command = queue?.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return }
        inFlight = true
        let begin = CACurrentMediaTime()
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
            Task { @MainActor in self?.complete(cpuMS: cpuMS, gpuMS: gpuMS, failed: failed) }
        }
        command.commit()
    }

    private func complete(cpuMS: Double, gpuMS: Double, failed: Bool) {
        inFlight = false
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
                environment:environment,source:videoMode ? "remote h264" : "synthetic")
            measurements.append(sample)
            if measurements.count > 300 { measurements.removeFirst() }
            logger.info("render fps=\(self.fps) gpu_ms=\(gpuMS) frames=\(self.completedFrames)")
            sampleFrames = 0; sampleStart = now; saveMeasurements()
        }
    }

    private func saveMeasurements() {
        guard let root = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first,
              let data = try? JSONEncoder().encode(measurements) else { return }
        try? data.write(to:root.appendingPathComponent(videoMode ? "stream-metrics.json" : "synthetic-metrics.json"),options:.atomic)
    }
    enum RenderError: Error { case unavailable }
}
